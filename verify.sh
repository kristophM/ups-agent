#!/bin/bash
# Read-only health check for ups-agent. Needs no root (journal access needs
# membership in group adm or systemd-journal). Never touches the UPS.
set -u
CONF=/etc/ups-agent/ups-agent.conf
[ -r "$CONF" ] && . "$CONF"
UPS=${UPS:-cyberpower@localhost}
LOG_DIR=${LOG_DIR:-/var/log/ups-agent}
NAME=${UPS%%@*}
fail=0
ok()   { printf '  [ok] %s\n' "$*"; }
bad()  { printf '  [!!] %s\n' "$*"; fail=1; }

echo "== services"
for u in "nut-driver@$NAME.service" nut-server.service nut-monitor.service ups-agent-log.timer; do
    if systemctl is-active --quiet "$u"; then ok "$u active"; else bad "$u not active"; fi
done
systemctl is-enabled --quiet nut-monitor.service && ok "nut-monitor enabled at boot" || bad "nut-monitor not enabled"

echo "== UPS ($UPS)"
if data=$(upsc "$UPS" 2>&1); then
    echo "$data" | grep -E '^(device\.model|ups\.status|battery\.charge|battery\.charge\.low|battery\.runtime|battery\.runtime\.low|ups\.delay\.shutdown|ups\.delay\.start|ups\.load|input\.voltage|ups\.realpower\.nominal|battery\.mfr\.date|ups\.test\.result):' | sed 's/^/     /'
    status=$(echo "$data" | sed -n 's/^ups\.status: //p')
    case " $status " in *" OL "*) ok "on utility power";; *" OB "*) bad "currently ON BATTERY";; *) bad "unexpected status '$status'";; esac
    [ "$(echo "$data" | sed -n 's/^ups\.delay\.shutdown: //p')" != "" ] && ok "UPS accepted offdelay (ups.delay.shutdown)" || bad "ups.delay.shutdown not reported"
else
    bad "upsc failed: $data"
fi

echo "== shutdown path"
if upscmd -l "$UPS" 2>/dev/null | grep -q 'shutdown.return'; then ok "UPS supports shutdown.return (outlets off, back on when AC returns)"; else bad "UPS does not list shutdown.return"; fi
if [ -x /usr/lib/systemd/system-shutdown/nutshutdown ] || [ -x /lib/systemd/system-shutdown/nutshutdown ]; then ok "nutshutdown halt hook present"; else bad "nutshutdown halt hook missing"; fi
[ -f /etc/killpower ] && bad "/etc/killpower exists (stale POWERDOWNFLAG — remove it: sudo rm /etc/killpower)" || ok "no stale POWERDOWNFLAG"
[ -e /etc/ups-agent/dry-run ] && bad "dry-run flag present: on-battery timer will NOT shut down" || ok "dry-run flag absent (timer shutdown armed)"
[ -f /etc/sudoers.d/ups-agent ] && ok "sudoers rule for nut present" || bad "sudoers rule missing"
if systemctl show nut-monitor.service -p ExecMainPID --value | grep -q '^[1-9]'; then ok "upsmon running"; fi

echo "== logs"
for f in events.log status.log; do
    if [ -r "$LOG_DIR/$f" ]; then ok "$LOG_DIR/$f ($(wc -l < "$LOG_DIR/$f") lines); last: $(tail -1 "$LOG_DIR/$f" 2>/dev/null | cut -c1-110)"; else bad "$LOG_DIR/$f missing/unreadable"; fi
done
if journalctl -t ups-agent -u nut-monitor --since "-1h" -q 2>/dev/null | tail -3 | sed 's/^/     /'; then :; fi

echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED (see [!!] above)"
exit $fail
