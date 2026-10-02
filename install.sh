#!/bin/bash
# ups-agent installer for a headless Ubuntu machine with a CyberPower UPS on USB.
# Idempotent: safe to re-run to apply changes to install.env or this repo.
#
#   sudo ./install.sh
#
# What it does:
#   1. apt-installs NUT (nut-server + nut-client) if missing
#   2. renders config/* into /etc/nut using /etc/ups-agent/install.env
#   3. installs the event handler, status logger, sudoers rule, logrotate,
#      and the systemd timer
#   4. (re)starts the NUT driver, upsd and upsmon, and prints a status summary
#
# It never reboots, shuts down, or sends any command to the UPS.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh must run as root:  sudo $0" >&2
    exit 1
fi

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_DIR=/etc/ups-agent
ENV_FILE=$CONF_DIR/install.env
LIB_DIR=/usr/local/lib/ups-agent
LOG_DIR=/var/log/ups-agent
NUT_DIR=/etc/nut

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [ok] %s\n' "$*"; }
warn() { printf '    [!!] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 1. tunables
log "Loading tunables"
install -d -m 0755 "$CONF_DIR"
if [ ! -f "$ENV_FILE" ]; then
    install -m 0644 "$REPO_DIR/install.env.example" "$ENV_FILE"
    ok "created $ENV_FILE from install.env.example (edit and re-run to tune)"
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${UPS_NAME:=cyberpower}" "${UPS_DESC:=CyberPower UPS}"
: "${CHARGE_LOW:=40}" "${RUNTIME_LOW:=180}" "${ONBATT_SHUTDOWN_SECS:=300}"
: "${OFFDELAY:=60}" "${ONDELAY:=600}" "${HEARTBEAT_MIN:=15}" "${BOOT_GRACE_SECS:=180}"
: "${UPS_POWEROFF:=no}" "${WOL_IFACE:=}" "${WOL_MODES:=pg}"

[[ $UPS_NAME =~ ^[A-Za-z0-9_-]+$ ]] || { warn "UPS_NAME '$UPS_NAME' has invalid characters"; exit 1; }
for v in CHARGE_LOW RUNTIME_LOW ONBATT_SHUTDOWN_SECS OFFDELAY HEARTBEAT_MIN BOOT_GRACE_SECS; do
    [[ ${!v} =~ ^[0-9]+$ ]] || { warn "$v must be a non-negative integer (got '${!v}')"; exit 1; }
done
[[ $ONDELAY =~ ^(-1|[0-9]+)$ ]] || { warn "ONDELAY must be -1 (disabled) or a non-negative integer (got '$ONDELAY')"; exit 1; }
[[ $UPS_POWEROFF =~ ^(yes|no)$ ]] || { warn "UPS_POWEROFF must be yes or no (got '$UPS_POWEROFF')"; exit 1; }
[[ $WOL_MODES =~ ^[pumbgsd]+$ ]] || { warn "WOL_MODES must be ethtool wol letters, e.g. pg (got '$WOL_MODES')"; exit 1; }
if [ "$UPS_POWEROFF" = yes ] && [ "$ONDELAY" -ge 0 ]; then
    if [ "$ONDELAY" -le "$OFFDELAY" ]; then
        warn "ONDELAY ($ONDELAY) must be greater than OFFDELAY ($OFFDELAY)"; exit 1
    fi
    [ $((ONDELAY % 60)) -ne 0 ] && warn "CyberPower rounds ONDELAY down to a multiple of 60 s"
    [ "$ONDELAY" -lt 600 ] && warn "ONDELAY=$ONDELAY is short: during a long outage the machine will boot on battery every $ONDELAY s"
elif [ "$UPS_POWEROFF" = yes ]; then
    warn "ONDELAY=-1: on CyberPower units the UPS will NOT restart by itself when power returns (manual button press needed)"
fi
if [ "$UPS_POWEROFF" = yes ] && { [ $((OFFDELAY % 60)) -ne 0 ] || [ "$OFFDELAY" -lt 60 ]; }; then
    warn "CyberPower rounds OFFDELAY DOWN to a multiple of 60 s; OFFDELAY=$OFFDELAY may become 0 (outlets cut immediately)"
fi
if [ "$UPS_POWEROFF" = yes ]; then
    POWERDOWNFLAG_LINE="POWERDOWNFLAG /etc/killpower"
else
    POWERDOWNFLAG_LINE="# POWERDOWNFLAG not set: UPS_POWEROFF=no, the UPS is left running after the halt"
fi
ok "UPS_NAME=$UPS_NAME CHARGE_LOW=${CHARGE_LOW}% RUNTIME_LOW=${RUNTIME_LOW}s ONBATT_SHUTDOWN_SECS=$ONBATT_SHUTDOWN_SECS UPS_POWEROFF=$UPS_POWEROFF WOL_MODES=$WOL_MODES"
[ "$UPS_POWEROFF" = yes ] && ok "OFFDELAY=$OFFDELAY ONDELAY=$ONDELAY BOOT_GRACE_SECS=$BOOT_GRACE_SECS"

# ---------------------------------------------------------------- 2. packages
log "Installing NUT packages"
if dpkg -s nut-server nut-client >/dev/null 2>&1; then
    ok "nut-server and nut-client already installed ($(dpkg-query -W -f='${Version}' nut-client))"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q nut
    ok "installed $(dpkg-query -W -f='${Version}' nut-client)"
fi
getent group nut >/dev/null || { warn "group 'nut' missing after install"; exit 1; }

# nut-server ships udev rules that hand USB UPS devices to group "nut", but
# they only apply to devices plugged in after the rules exist. Re-apply them
# to the already-connected UPS so the driver can open it without a replug.
log "Applying NUT udev rules to the connected UPS"
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor=0764 --action=add 2>/dev/null || udevadm trigger --subsystem-match=usb
udevadm settle --timeout=10 || true
ups_dev=""
for d in /dev/bus/usb/*/*; do
    if udevadm info -q property "$d" 2>/dev/null | grep -q '^ID_VENDOR_ID=0764$'; then ups_dev=$d; break; fi
done
if [ -z "$ups_dev" ]; then
    warn "no CyberPower (vendor 0764) USB device found — is the UPS USB cable connected?"
elif [ "$(stat -c %G "$ups_dev")" = "nut" ]; then
    ok "$ups_dev owned by group nut ($(stat -c '%U:%G %a' "$ups_dev"))"
else
    warn "$ups_dev is $(stat -c '%U:%G %a' "$ups_dev"), not group nut — driver will fail to open it"
fi

# ---------------------------------------------------------------- 3. password
# Keep an existing upsmon password across re-runs so nothing needs restarting
# for auth reasons; generate one on first install.
UPSMON_PASSWORD=""
if [ -f "$NUT_DIR/upsd.users" ]; then
    UPSMON_PASSWORD=$(awk '/^\[upsmon\]/{f=1;next} /^\[/{f=0} f && $1=="password"{print $3; exit}' "$NUT_DIR/upsd.users" || true)
fi
if [ -z "$UPSMON_PASSWORD" ]; then
    UPSMON_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
    ok "generated new upsmon password"
else
    ok "reusing existing upsmon password"
fi

ADMIN_PASSWORD=""
[ -f "$NUT_DIR/upsd.users" ] && ADMIN_PASSWORD=$(awk '/^\[admin\]/{f=1;next} /^\[/{f=0} f && $1=="password"{print $3; exit}' "$NUT_DIR/upsd.users" || true)
if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
    ok "generated new admin password"
fi

# ---------------------------------------------------------------- 4. NUT config
log "Rendering NUT configuration into $NUT_DIR"
render() {
    sed -e "s|@UPS_NAME@|$UPS_NAME|g" \
        -e "s|@UPS_DESC@|$UPS_DESC|g" \
        -e "s|@CHARGE_LOW@|$CHARGE_LOW|g" \
        -e "s|@RUNTIME_LOW@|$RUNTIME_LOW|g" \
        -e "s|@ONBATT_SHUTDOWN_SECS@|$ONBATT_SHUTDOWN_SECS|g" \
        -e "s|@OFFDELAY@|$OFFDELAY|g" \
        -e "s|@ONDELAY@|$ONDELAY|g" \
        -e "s|@UPSMON_PASSWORD@|$UPSMON_PASSWORD|g" \
        -e "s|@ADMIN_PASSWORD@|$ADMIN_PASSWORD|g" \
        -e "s|@POWERDOWNFLAG_LINE@|$POWERDOWNFLAG_LINE|g" \
        "$REPO_DIR/config/$1"
}
install -d -m 0755 "$NUT_DIR"
changed=0
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf upssched.conf; do
    tmp=$(mktemp)
    render "$f" > "$tmp"
    if [ -f "$NUT_DIR/$f" ] && cmp -s "$tmp" "$NUT_DIR/$f"; then
        rm -f "$tmp"
    else
        [ -f "$NUT_DIR/$f" ] && cp -a "$NUT_DIR/$f" "$NUT_DIR/$f.bak"
        install -m 0640 -o root -g nut "$tmp" "$NUT_DIR/$f"
        rm -f "$tmp"
        changed=1
        ok "wrote $f"
    fi
done
[ $changed -eq 0 ] && ok "all NUT config files already up to date"

# ---------------------------------------------------------------- 5. agent files
log "Installing ups-agent scripts, sudoers rule, logrotate, systemd timer"
install -d -m 0755 "$LIB_DIR"
install -m 0755 "$REPO_DIR/scripts/upssched-cmd" "$LIB_DIR/upssched-cmd"
install -m 0755 "$REPO_DIR/scripts/ups-agent-log" "$LIB_DIR/ups-agent-log"
install -m 0755 "$REPO_DIR/scripts/ups-selftest" "$LIB_DIR/ups-selftest"
install -m 0755 "$REPO_DIR/scripts/ups-agent-wol" "$LIB_DIR/ups-agent-wol"
install -m 0755 "$REPO_DIR/scripts/wake" "$LIB_DIR/wake"
ln -sf "$LIB_DIR/ups-selftest" /usr/local/sbin/ups-selftest
printf '%s\n' "$ADMIN_PASSWORD" > "$CONF_DIR/admin.pass.tmp"
install -m 0600 -o root -g root "$CONF_DIR/admin.pass.tmp" "$CONF_DIR/admin.pass"; rm -f "$CONF_DIR/admin.pass.tmp"

cat > "$CONF_DIR/ups-agent.conf" <<CONF
# ups-agent: generated by install.sh from $ENV_FILE
UPS=$UPS_NAME@localhost
LOG_DIR=$LOG_DIR
HEARTBEAT_MIN=$HEARTBEAT_MIN
BOOT_GRACE_SECS=$BOOT_GRACE_SECS
UPS_POWEROFF=$UPS_POWEROFF
WOL_IFACE=$WOL_IFACE
WOL_MODES=$WOL_MODES
CONF
chmod 0644 "$CONF_DIR/ups-agent.conf"

install -d -m 0775 -o nut -g nut "$LOG_DIR"
for f in events.log status.log; do
    [ -f "$LOG_DIR/$f" ] || install -m 0664 -o nut -g nut /dev/null "$LOG_DIR/$f"
done

install -m 0440 -o root -g root "$REPO_DIR/etc/sudoers.d/ups-agent" "$CONF_DIR/sudoers.tmp"
if visudo -cf "$CONF_DIR/sudoers.tmp" >/dev/null; then
    mv "$CONF_DIR/sudoers.tmp" /etc/sudoers.d/ups-agent
    ok "sudoers rule installed (nut may run: upsmon -c fsd)"
else
    rm -f "$CONF_DIR/sudoers.tmp"; warn "sudoers file failed validation; not installed"; exit 1
fi

install -m 0644 "$REPO_DIR/etc/logrotate.d/ups-agent" /etc/logrotate.d/ups-agent
install -m 0644 "$REPO_DIR/systemd/ups-agent-log.service" /etc/systemd/system/ups-agent-log.service
install -m 0644 "$REPO_DIR/systemd/ups-agent-log.timer" /etc/systemd/system/ups-agent-log.timer
install -m 0644 "$REPO_DIR/systemd/ups-agent-wol.service" /etc/systemd/system/ups-agent-wol.service
install -m 0644 "$REPO_DIR/etc/udev/rules.d/80-ups-agent-wol.rules" /etc/udev/rules.d/80-ups-agent-wol.rules
if [ -d /etc/NetworkManager/dispatcher.d ]; then
    install -m 0755 "$REPO_DIR/etc/NetworkManager/dispatcher.d/90-ups-agent-wol" /etc/NetworkManager/dispatcher.d/90-ups-agent-wol
fi
udevadm control --reload-rules
# A stale flag from an earlier UPS_POWEROFF=yes install would make the next
# clean reboot cut the UPS outlets.
[ "$UPS_POWEROFF" = no ] && rm -f /etc/killpower

# upssched's pipe/lock live in /run/nut/upssched, created by NUT's own
# tmpfiles rule (nut-common-tmpfiles.conf) and by the unit's ExecStartPre.
rm -f /usr/lib/tmpfiles.d/ups-agent.conf
ok "scripts in $LIB_DIR, logs in $LOG_DIR"

# ---------------------------------------------------------------- 6. services
log "Enabling and (re)starting services"
systemctl daemon-reload
# Fresh installs leave nut-server "failed" (it ran before ups.conf existed)
# and often start-rate-limited; clear that or restarts are refused.
systemctl reset-failed "nut-driver@$UPS_NAME.service" nut-server.service nut-monitor.service 2>/dev/null || true

svc_fail=0
restart_unit() {
    if systemctl restart "$1"; then ok "$1 restarted"; else warn "$1 failed to start — see: journalctl -u $1"; svc_fail=1; fi
}

# Debian/Ubuntu NUT 2.8 generates one nut-driver@<ups>.service per ups.conf
# section via nut-driver-enumerator. Fall back to the classic upsdrvctl path
# if this box's packaging lacks it.
if systemctl cat nut-driver-enumerator.service >/dev/null 2>&1; then
    systemctl enable nut-driver-enumerator.service nut-driver-enumerator.path >/dev/null 2>&1 || true
    systemctl restart nut-driver-enumerator.service || warn "nut-driver-enumerator restart failed"
    systemctl enable "nut-driver@$UPS_NAME.service" >/dev/null 2>&1 || true
    restart_unit "nut-driver@$UPS_NAME.service"
else
    upsdrvctl stop >/dev/null 2>&1 || true
    upsdrvctl start && ok "driver started via upsdrvctl" || { warn "upsdrvctl start failed"; svc_fail=1; }
fi

systemctl enable nut-server.service nut-monitor.service >/dev/null 2>&1 || true
sleep 2
restart_unit nut-server.service
sleep 2
restart_unit nut-monitor.service
systemctl enable --now ups-agent-log.timer >/dev/null && ok "ups-agent-log.timer enabled"
systemctl enable ups-agent-wol.service >/dev/null 2>&1
if systemctl restart ups-agent-wol.service; then
    ok "Wake-on-LAN: $(journalctl -u ups-agent-wol -n 1 -o cat --no-pager 2>/dev/null)"
else
    warn "ups-agent-wol failed — see: journalctl -u ups-agent-wol"
fi

# ---------------------------------------------------------------- 7. summary
log "Status"
sleep 3
for u in "nut-driver@$UPS_NAME.service" nut-server.service nut-monitor.service ups-agent-log.timer; do
    if systemctl is-active --quiet "$u"; then ok "$u active"; else warn "$u NOT active — see: journalctl -u $u"; fi
done
if upsc "$UPS_NAME@localhost" >/dev/null 2>&1; then
    ok "upsc reachable:"
    upsc "$UPS_NAME@localhost" 2>/dev/null \
      | grep -E '^(ups\.status|battery\.charge|battery\.charge\.low|battery\.runtime|battery\.runtime\.low|ups\.delay\.shutdown|ups\.delay\.start|ups\.load|input\.voltage):' \
      | sed 's/^/         /'
    got=$(upsc "$UPS_NAME@localhost" ups.delay.start 2>/dev/null)
    if [ "$ONDELAY" -ge 0 ] && [ "$got" != "$ONDELAY" ]; then
        warn "UPS reports ups.delay.start=$got, not $ONDELAY: it may have capped or rounded the restart timer"
    fi
else
    warn "upsc $UPS_NAME@localhost failed — check: journalctl -u nut-driver@$UPS_NAME -u nut-server"
fi

if [ "$UPS_POWEROFF" = yes ]; then
    if [ -x /usr/lib/systemd/system-shutdown/nutshutdown ] || [ -x /lib/systemd/system-shutdown/nutshutdown ]; then
        ok "nutshutdown hook present (UPS outlets will be cut at halt)"
    else
        warn "no systemd-shutdown nutshutdown hook found — the UPS will NOT cut power after halt. See README."
    fi
else
    ok "UPS_POWEROFF=no: the UPS is left running after a halt; wake-up relies on Wake-on-LAN or UPS exhaustion restart"
fi

echo
if [ $svc_fail -ne 0 ]; then
    echo "Done WITH ERRORS: one or more services failed to start (see [!!] above)."
    exit 1
fi
echo "Done. Run ./verify.sh (no sudo needed) for a fuller read-only check."
echo "Logs: $LOG_DIR/events.log, $LOG_DIR/status.log, journalctl -t ups-agent -u nut-monitor"
echo "Battery self-test (drops the load if the battery is bad!): sudo ups-selftest"
