# ups-agent

Graceful power-outage handling for a headless Ubuntu workstation with a
CyberPower UPS on USB, built on [Network UPS Tools (NUT)](https://networkupstools.org/).

When the grid fails the machine rides on battery, shuts itself down cleanly
before the battery is drained, and comes back on its own when the grid
returns. Everything that happens is logged so you can review an outage after
the fact.

This repo is the installer: clone it on the target machine and run
`sudo ./install.sh`. Re-run it any time to apply changes.

## Requirements

- Ubuntu (tested on 26.04 LTS, NUT 2.8.4); Debian should also work.
- CyberPower UPS connected by USB (`lsusb` shows vendor `0764`). Tested
  with a CP1000AVRLCDa; any model handled by NUT's `usbhid-ups` should work.
- The machine is plugged into a **battery-backed** outlet of the UPS.
- BIOS set to power on when AC returns (Gigabyte: *AC BACK = Always On*).
- For the default wake-up design (see below):
  - an Ethernet cable from the machine's wired port to a switch that is
    plugged into the **wall, not the UPS**;
  - Wake-on-LAN enabled in the BIOS (on Gigabyte boards also disable *ErP*,
    which otherwise cuts standby power to the network port).

## Install

```sh
git clone https://github.com/kristophM/ups-agent.git
cd ups-agent
sudo ./install.sh      # installs NUT, writes config, starts services
./verify.sh            # read-only health check, no sudo needed
```

`install.sh` copies `install.env.example` to `/etc/ups-agent/install.env` on
first run. Edit that file to change settings, then re-run `sudo ./install.sh`.

| Setting | Default | Meaning |
|---|---|---|
| `UPS_NAME` | `cyberpower` | NUT name of the UPS (`upsc cyberpower@localhost`) |
| `CHARGE_LOW` | `25` | Shut down when battery charge is at or below this percent while on battery |
| `RUNTIME_LOW` | `180` | ...or when estimated runtime is at or below this many seconds |
| `ONBATT_SHUTDOWN_SECS` | `300` | Shut down after this many consecutive seconds on battery (what separates an outage from a brownout) |
| `UPS_POWEROFF` | `no` | Whether the halting OS tells the UPS to cut its outlets. See "How it works" |
| `WOL_IFACE` | auto | Wired interface to arm for Wake-on-LAN |
| `WOL_MODES` | `pg` | `p` = wake on link activity, `g` = magic packet |
| `OFFDELAY` | `60` | Only with `UPS_POWEROFF=yes`: seconds until the UPS cuts its outlets (multiple of 60 on CyberPower) |
| `ONDELAY` | `600` | Only with `UPS_POWEROFF=yes`: seconds until the UPS re-powers them (see "Alternative: retry") |
| `BOOT_GRACE_SECS` | `180` | If the machine boots and the UPS is already on battery within this many seconds, shut down again at once |
| `HEARTBEAT_MIN` | `15` | Minutes between status.log heartbeat lines while everything is normal |

## How it works

Three NUT processes run on the machine (`MODE=standalone`): the `usbhid-ups`
driver talks to the UPS, `upsd` serves its state on `localhost:3493`, and
`upsmon` watches it and decides when to shut down. An `upssched` handler adds
the on-battery timer and writes the event log.

### Timeline of an outage

1. **Grid fails.** The UPS reports on battery. upsmon logs it, broadcasts a
   `wall` message, and the `ONBATT_SHUTDOWN_SECS` timer starts. A blip that
   ends before the timer fires just logs `ONLINE` and cancels it.
2. **Shutdown trigger.** Either the timer expires (the handler runs
   `upsmon -c fsd`) or NUT raises low-battery from `CHARGE_LOW` /
   `RUNTIME_LOW`. The UPS's own low-battery flag is ignored (`ignorelb`)
   because CyberPower fires it at about 10%, too late to halt safely.
3. **OS shutdown.** upsmon runs `shutdown -h +0`; systemd stops services and
   unmounts filesystems normally. The UPS is **not** told to turn off: the
   machine sits in soft-off on a live outlet, drawing a watt or two, and its
   wired network port stays powered and armed for Wake-on-LAN.
4. **Grid returns, two cases.**
   - *Battery not yet exhausted* (most outages): the UPS switches back to
     grid; the outlets never went off, so the BIOS sees nothing. The switch,
     being on wall power, reboots and brings the machine's link up, and the
     network port wakes the machine (`p` mode). A magic packet (`g` mode)
     from any device on the LAN also works, see `scripts/wake`.
   - *Battery exhausted* (day-long outages): the UPS turned itself off hours
     earlier. When the grid returns it restarts on its own, the outlets come
     back, and the BIOS boots the machine. The wake packet arrives too,
     harmlessly.
5. NUT starts at boot and normal monitoring resumes.

### Why not just tell the UPS to turn off?

That was the first design, and it is what NUT does by default
(`POWERDOWNFLAG` + `upsdrvctl shutdown`). It would be simpler: cut the
outlets after the halt, and the BIOS boots the machine when the UPS restores
them. On this CyberPower it does not work, verified on a CP1000AVRLCDa with
firmware "CyberPower HID 0.84" and NUT 2.8.4:

| Restart timer (`ONDELAY`) | What the UPS does after cutting the outlets |
|---|---|
| positive | Re-powers them when the timer expires, **even with the grid still down**, so the machine boots on battery and loops |
| `-1` (none) | Never re-powers them, **not even when the grid returns** (tested twice, 25 minutes); someone must press the UPS button |

CyberPower support, quoted in `man usbhid-ups`, says their units "are unable
to set up power on delay", and the unit exposes no auto-restart setting over
USB (`upsrw -l` lists only the two delay timers). A commanded shutdown puts
the unit in a "switched off" state it will not leave on its own; running out
of battery puts it in a state it does leave when the grid returns. The
default design above uses the second and covers the gap with Wake-on-LAN.

### Alternative: retry (`UPS_POWEROFF=yes`)

For a UPS that honours "return when power is back", or if Wake-on-LAN is not
possible, set `UPS_POWEROFF=yes`. The halt hook then sends `shutdown.return`
with `OFFDELAY`/`ONDELAY`. On a UPS with the CyberPower behaviour this acts
as a periodic retry: every `ONDELAY` seconds the outlets come back; if the
grid is up the machine stays up, otherwise it sees on-battery right after
boot and, being up for less than `BOOT_GRACE_SECS`, shuts down again at once
(log line `BOOTED INTO ONGOING OUTAGE`). Each retry costs about two minutes
on battery.

### Why the sudoers rule

upsmon runs its notify commands as the unprivileged `nut` user, but only root
may call `upsmon -c fsd`. `/etc/sudoers.d/ups-agent` allows exactly that one
command for `nut`, nothing else.

## Waking the machine by hand

From any machine on the same LAN with python3 (no packages needed):

```sh
./scripts/wake 30:56:0f:47:29:d7          # the rig's wired MAC
```

`./verify.sh` prints the MAC. On the rig itself the script is installed as
`/usr/local/lib/ups-agent/wake`.

## Logs

| Where | What |
|---|---|
| `/var/log/ups-agent/events.log` | One line per event (on battery, online, low battery, timer expired, FSD, comm lost/ok, replace battery) with a snapshot of status, charge, runtime, load and input voltage; flushed to disk immediately |
| `/var/log/ups-agent/status.log` | Snapshot every minute whenever the UPS is not plain `OL` (on battery, charging after an outage, unreachable), plus a heartbeat every `HEARTBEAT_MIN` minutes |
| `journalctl -t ups-agent` | Same events, in the systemd journal |
| `journalctl -u nut-monitor -u nut-server -u nut-driver@cyberpower` | NUT's own messages |
| `journalctl -u ups-agent-wol` | What Wake-on-LAN mode was armed at boot |

The journal is persistent on the target (`/var/log/journal`), so entries from
before a shutdown survive. `logrotate` rotates the two files weekly and keeps
12 generations.

After an outage:

```sh
tail -50 /var/log/ups-agent/events.log
grep -v 'status="OL"' /var/log/ups-agent/status.log | tail -50
journalctl -b -1 -t ups-agent -u nut-monitor     # previous boot
journalctl --list-boots | tail -3
```

## Before relying on it: prove the UPS actually holds the load

NUT can only act on what the UPS reports. If the battery is dead, disconnected
or worn out, the UPS drops the load the instant the grid fails, no on-battery
event is ever generated, and nothing in this repo can help. A UPS with a bad
battery often still reports `battery.charge: 100` and a plausible
`battery.runtime`, because those are estimates derived from the charger's
float voltage, not measurements under load. Check this first, and again every
year or so:

```sh
sudo ups-selftest          # quick test, ~10 s on battery
sudo ups-selftest --deep   # longer test
```

It prints `ups.test.result` as the UPS updates it and ends with PASSED or
FAILED (which also raises the `RB` status flag). **The test puts the load on
battery**, so a bad battery drops the outlets just like a real outage. Run it
with only a lamp on the UPS, or accept that the machine may lose power. The
CP1000AVRLCDa takes a 12 V 9 Ah pack (CyberPower RB1290).

## Verifying without shutting down

`./verify.sh` checks the services, that the UPS is readable, the shutdown
mode, the wired link and Wake-on-LAN state, and that there is no stale
`/etc/killpower` flag.

To exercise the event pipeline with no risk of a shutdown:

```sh
sudo touch /etc/ups-agent/dry-run
sudo -u nut /usr/local/lib/ups-agent/upssched-cmd onbatt
sudo -u nut /usr/local/lib/ups-agent/upssched-cmd onbatt-shutdown   # logs, does not shut down
tail -3 /var/log/ups-agent/events.log
sudo rm /etc/ups-agent/dry-run          # re-arm!
```

The dry-run flag only affects the timer path. The charge/runtime low-battery
path is handled by upsmon itself and is **not** affected.

## Full end-to-end test (when you are physically present)

1. `./verify.sh` passes and nothing important is running.
2. Temporarily set `ONBATT_SHUTDOWN_SECS=60` in `/etc/ups-agent/install.env`
   and `sudo ./install.sh`.
3. Pull the UPS's utility plug. Within about a minute the machine logs
   `ON BATTERY`, then `ON-BATTERY TIMER EXPIRED`, then shuts down. The UPS
   stays on; its display shows on-battery with a tiny load.
4. Plug the UPS back in. The switch is already up (it was never on the UPS),
   so to simulate the grid returning, power-cycle the switch. Note that the
   link-activity wake mode fires on the link going *down* as well as up: if
   the switch is unplugged while the machine is already halted, the machine
   wakes at once. For a faithful rehearsal unplug the switch first, then halt
   the machine, then plug the switch back in; the machine should boot within
   about a minute of the switch's lights returning (verified on the
   CP1000AVRLCDa / X870I AORUS setup with ErP disabled; that board has no
   separate Wake-on-LAN option).
5. For the exhaustion path, leave the plug out overnight with the machine
   halted. In the morning the UPS should be dark; plug it in and the machine
   should boot by itself.
6. Restore `ONBATT_SHUTDOWN_SECS=300`, re-run `sudo ./install.sh`, review the
   logs.

## Troubleshooting

- **Driver logs "insufficient permissions" / "No matching HID UPS found"**:
  the UPS device node is not owned by group `nut`. `install.sh` re-triggers
  udev for the UPS, but a replug also fixes it.
- **`upsc` says "Data stale" or the driver won't start**: check
  `journalctl -u nut-driver@cyberpower`. Unplug and replug the UPS USB cable.
- **Rig died instantly when the plug was pulled, UPS turned off too**: the
  battery did not take the load. See "Before relying on it".
- **Machine stayed off after a short outage**: the wake did not happen. Check
  `./verify.sh` (link up? `Wake-on: pg`?), that the switch is on wall power,
  and the BIOS Wake-on-LAN / ErP settings. `./scripts/wake <mac>` from
  another machine isolates the BIOS/NIC side from the switch side.
- **Machine rebooted on battery after the shutdown**: `UPS_POWEROFF=yes` with
  a positive `ONDELAY`; that is the retry design. Set `UPS_POWEROFF=no`.
- **Machine stays off after power returns, UPS dark**: `UPS_POWEROFF=yes` with
  `ONDELAY=-1`. Press the UPS button, set `UPS_POWEROFF=no`, re-run.
- **upsmon logs "No POWERDOWNFLAG value was configured"** at startup: expected
  with `UPS_POWEROFF=no`; it is the setting that keeps the UPS running.
- **Stale `/etc/killpower` after a normal boot**: `sudo rm /etc/killpower`
  (the installer removes it when `UPS_POWEROFF=no`).
- **Changing the upsmon or admin password**: delete `/etc/nut/upsd.users` and
  re-run `sudo ./install.sh`; new ones are generated and applied everywhere.

## Uninstall

```sh
sudo ./uninstall.sh              # keeps NUT packages and logs
sudo ./uninstall.sh --purge-logs
sudo apt-get remove nut nut-server nut-client
```

## Layout

```
install.sh            idempotent installer (run as root on the target)
verify.sh             read-only health check
uninstall.sh          remove everything this repo installed
install.env.example   settings; copied to /etc/ups-agent/install.env
config/               NUT config templates -> /etc/nut/
scripts/upssched-cmd  event handler -> /usr/local/lib/ups-agent/
scripts/ups-agent-log minute status logger
scripts/ups-agent-wol arms Wake-on-LAN on the wired interface
scripts/ups-selftest  battery self-test wrapper -> /usr/local/sbin/ups-selftest
scripts/wake          send a magic packet (python3, runs anywhere)
systemd/              ups-agent-log.service/.timer, ups-agent-wol.service
etc/udev/rules.d/     arm WoL when the interface appears
etc/NetworkManager/   re-arm WoL after every link-up
etc/sudoers.d/        lets user nut run `upsmon -c fsd`
etc/logrotate.d/      rotation for /var/log/ups-agent
```
