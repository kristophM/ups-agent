#!/bin/bash
# Remove ups-agent and its NUT configuration. Leaves the NUT packages installed
# (remove with: sudo apt-get remove nut nut-server nut-client) and keeps
# /var/log/ups-agent unless --purge-logs is given.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

systemctl disable --now ups-agent-log.timer 2>/dev/null || true
systemctl disable --now nut-monitor.service nut-server.service 2>/dev/null || true
for u in $(systemctl list-units --all --plain --no-legend 'nut-driver@*' | awk '{print $1}'); do
    systemctl disable --now "$u" 2>/dev/null || true
done
rm -f /etc/systemd/system/ups-agent-log.service /etc/systemd/system/ups-agent-log.timer
rm -f /etc/sudoers.d/ups-agent /etc/logrotate.d/ups-agent /usr/lib/tmpfiles.d/ups-agent.conf
rm -rf /usr/local/lib/ups-agent /etc/ups-agent
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf upssched.conf; do
    if [ -f /etc/nut/$f ] && grep -q '^# ups-agent: managed' /etc/nut/$f; then
        rm -f /etc/nut/$f /etc/nut/$f.bak
    fi
done
[ -f /etc/nut/nut.conf ] || echo "MODE=none" > /etc/nut/nut.conf
systemctl daemon-reload
if [ "${1:-}" = "--purge-logs" ]; then rm -rf /var/log/ups-agent; fi
echo "ups-agent removed. NUT packages left installed (MODE=none)."
