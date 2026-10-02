# ups-agent

Graceful power-outage handling for a headless Ubuntu workstation with a
CyberPower UPS on USB, built on [Network UPS Tools (NUT)](https://networkupstools.org/).

When utility power fails the machine rides on battery, shuts itself down
cleanly before the battery is drained, tells the UPS to cut its outlets while
it still has charge, and comes back on its own when utility power returns.
Everything that happens is logged so you can review an outage after the fact.

This repo is the installer: clone it on the target machine and run
`sudo ./install.sh`. Re-run it any time to apply changes.

## Requirements

- Ubuntu (tested on 26.04 LTS, NUT 2.8.4); Debian should also work.
- CyberPower UPS connected by USB (`lsusb` shows vendor `0764`). Tested
  with a CP1000AVRLCDa; any model handled by NUT's `usbhid-ups` should work.
- BIOS set to power on when AC returns (Gigabyte: *AC BACK = Always On*).
  Without this the UPS will restore power but the machine will stay off.
- The machine is plugged into a **battery-backed** outlet of the UPS.

## Install

```sh
git clone https://github.com/kristophM/ups-agent.git
cd ups-agent
sudo ./install.sh      # installs NUT, writes config, starts services
./verify.sh            # read-only health check, no sudo needed
```

`install.sh` copies `install.env.example` to `/etc/ups-agent/install.env` on
first run. Edit that file to change thresholds, then re-run `sudo ./install.sh`.

| Setting | Default | Meaning |
|---|---|---|
| `UPS_NAME` | `cyberpower` | NUT name of the UPS (`upsc cyberpower@localhost`) |
| `CHARGE_LOW` | `40` | Shut down when battery charge is at or below this percent while on battery |
| `RUNTIME_LOW` | `180` | ...or when estimated runtime is at or below this many seconds |
| `ONBATT_SHUTDOWN_SECS` | `300` | Backstop: shut down after this many consecutive seconds on battery |
| `OFFDELAY` | `60` | Seconds after the halt command until the UPS cuts its outlets (CyberPower rounds down to multiples of 60, so use 60, 120, ...) |
| `ONDELAY` | `600` | Seconds from the shutdown command until the UPS re-powers its outlets, power or no power. Acts as the retry interval during a long outage (see below). Multiple of 60, must exceed `OFFDELAY` |
| `BOOT_GRACE_SECS` | `180` | If the machine boots and the UPS is still on battery within this many seconds, shut down again immediately (a retry into an ongoing outage) |
| `HEARTBEAT_MIN` | `15` | Minutes between status.log heartbeat lines while everything is normal |

Pick `CHARGE_LOW`/`RUNTIME_LOW` so that the OS has time to halt with margin
left on the battery. Check `battery.runtime` in `upsc` under your normal load
first: if full-charge runtime is close to `RUNTIME_LOW`, the machine will shut
down almost immediately on any outage, so lower `RUNTIME_LOW`.

## How it works

Three NUT processes run on the machine (`MODE=standalone`):

- **`usbhid-ups` driver** (`nut-driver@cyberpower.service`) talks to the UPS
  over USB and publishes its state.
- **`upsd`** (`nut-server.service`) serves that state on `localhost:3493`.
- **`upsmon`** (`nut-monitor.service`) watches it and decides when to shut down.

### Timeline of an outage

1. **Utility power fails.** The UPS reports `OB` (on battery). upsmon logs it,
   broadcasts a `wall` message, and `upssched` starts the
   `ONBATT_SHUTDOWN_SECS` timer. Nothing else happens; a short blip that ends
   before the timer fires just logs `ONLINE` and cancels the timer. This is
   what distinguishes a sustained outage from a brownout.
2. **Threshold reached.** NUT raises `LB` (low battery) when charge drops to
   `CHARGE_LOW` or runtime to `RUNTIME_LOW`. The UPS's own low-battery flag is
   ignored (`ignorelb`) because CyberPower firmware fires it at about 10%,
   which is too late. If neither threshold trips but the timer expires, the
   event handler runs `upsmon -c fsd` (forced shutdown), which has the same
   effect as `LB`.
3. **OS shutdown.** upsmon writes the `POWERDOWNFLAG` (`/etc/killpower`),
   waits `FINALDELAY` (5 s) and runs `shutdown -h +0`. systemd stops services
   and unmounts filesystems normally.
4. **UPS outlets off.** In the last step of the halt, systemd runs
   `/usr/lib/systemd/system-shutdown/nutshutdown` (shipped by `nut-client`).
   It sees the flag and runs `upsdrvctl shutdown`, which sends
   `shutdown.return` to the UPS with `OFFDELAY`. The UPS display counts down
   and cuts its outlets, with charge still in the battery.
5. **Outlets back on.** `ONDELAY` seconds after the shutdown command the UPS
   re-powers its outlets, whether or not utility power is back. The BIOS
   sees AC and boots the machine.
   - If utility power is back: NUT starts, the `POWERDOWNFLAG` is cleared,
     normal monitoring resumes. Done.
   - If the outage is still going: upsmon sees ON BATTERY within seconds of
     boot. Because the machine has been up for less than `BOOT_GRACE_SECS`,
     the handler forces a shutdown immediately instead of waiting
     `ONBATT_SHUTDOWN_SECS`. Steps 3 to 5 repeat every `ONDELAY` seconds,
     each retry costing roughly two minutes on battery, until power returns
     or the battery is exhausted.

### Why the retry design (CyberPower behaviour)

Tested on a CP1000AVRLCDa, firmware "CyberPower HID 0.84", NUT 2.8.4:

| `ONDELAY` | What the UPS does after cutting the outlets |
|---|---|
| positive | Re-powers the outlets when the timer expires, **even with utility power still out** (the load boots on battery) |
| `-1` | Never re-powers them, **not even when utility power returns**; someone must press the UPS button |

CyberPower support, quoted in `man usbhid-ups`, says their units "are unable
to set up power on delay", and the unit exposes no auto-restart setting over
USB (`upsrw -l` lists only the two delay timers). So a plain "off until power
returns" is not available, and the periodic retry above is the closest thing:
the machine is back at most `ONDELAY` seconds after power returns, and a long
outage costs a short boot (about two minutes of outlets-on time) every
`ONDELAY` seconds. With the default 10 minutes that drains the battery at
roughly a fifth of the rate of simply staying on; if a very long outage does
exhaust it, the UPS shuts itself off and restarts on its own when power
returns (standard CyberPower behaviour), so the machine still comes back.

`ONBATT_SHUTDOWN_SECS` and `ONDELAY` interact: an outage shorter than
`ONBATT_SHUTDOWN_SECS` costs nothing, while a longer one costs a shutdown plus
up to `ONDELAY` of downtime after power returns. With about an hour of runtime
at light load, waiting 5 minutes on battery is cheap insurance against that.

If your UPS honours "return only when power is back" properly, you can set a
short `ONDELAY` (120) and `BOOT_GRACE_SECS=0`.

### Why the sudoers rule

upsmon runs its notify commands as the unprivileged `nut` user, but only root
may call `upsmon -c fsd`. `/etc/sudoers.d/ups-agent` allows exactly that one
command for `nut`, nothing else.

## Logs

| Where | What |
|---|---|
| `/var/log/ups-agent/events.log` | One line per event (on battery, online, low battery, timer expired, FSD, comm lost/ok, replace battery) with a snapshot of status, charge, runtime, load and input voltage |
| `/var/log/ups-agent/status.log` | Snapshot every minute whenever the UPS is not plain `OL` (on battery, charging after an outage, unreachable), plus a heartbeat every `HEARTBEAT_MIN` minutes |
| `journalctl -t ups-agent` | Same events, in the systemd journal |
| `journalctl -u nut-monitor -u nut-server -u nut-driver@cyberpower` | NUT's own messages (upsmon's `SYSLOG` notifications land under `nut-monitor`) |

The journal is persistent on the target (`/var/log/journal`), so entries from
before a shutdown survive. `logrotate` rotates the two files weekly and keeps
12 generations.

After an outage:

```sh
tail -50 /var/log/ups-agent/events.log
grep -v 'status="OL"' /var/log/ups-agent/status.log | tail -50
journalctl -b -1 -t ups-agent -u nut-monitor     # previous boot
last -x shutdown reboot | head
```

## Verifying without shutting down

`./verify.sh` checks that all services are up, the UPS is readable, it
accepted the off/on delays (`ups.delay.shutdown`, `ups.delay.start`), it
supports `shutdown.return`, the halt hook is present, and there is no stale
`/etc/killpower` flag.

To exercise the event pipeline without any risk of a shutdown, put the agent
in dry-run mode, then simulate an event as the `nut` user:

```sh
sudo touch /etc/ups-agent/dry-run
sudo -u nut /usr/local/lib/ups-agent/upssched-cmd onbatt
sudo -u nut /usr/local/lib/ups-agent/upssched-cmd onbatt-shutdown   # logs, does not shut down
tail -3 /var/log/ups-agent/events.log
sudo rm /etc/ups-agent/dry-run          # re-arm!
```

With the dry-run flag present, the on-battery timer only logs. The
charge/runtime `LB` path is handled by upsmon itself and is **not** affected
by the flag, so do not pull the plug expecting nothing to happen.

## Full end-to-end test (when you are physically present)

1. Make sure nothing important is running and `./verify.sh` passes.
2. Temporarily set `ONBATT_SHUTDOWN_SECS=60` in `/etc/ups-agent/install.env`
   and `sudo ./install.sh`.
3. Pull the UPS's utility plug. Within a minute the machine should log
   `ON BATTERY`, then `ON-BATTERY TIMER EXPIRED`, then shut down. About
   `OFFDELAY` seconds after the halt, the UPS should click its outlets off.
4. Plug the UPS back in. Its outlets should come back on and the machine
   should boot by itself.
5. Restore `ONBATT_SHUTDOWN_SECS`, re-run `sudo ./install.sh`, and review the
   logs listed above.

## Before relying on it: prove the UPS actually holds the load

NUT can only act on what the UPS reports. If the battery is dead, disconnected
or worn out, the UPS drops the load the instant utility power fails, no
on-battery event is ever generated, and nothing in this repo can help. Check
this first, and again every year or so:

1. Plug a lamp (not the computer) into a **battery-backed** outlet.
2. Pull the UPS's utility plug. The lamp must stay lit and the UPS must show
   "on battery" on its display.
3. If the lamp goes out or the UPS itself turns off: check that the internal
   battery connector is attached (CyberPower ships some models with it
   unplugged), then replace the battery if the problem persists.

A UPS with a bad battery often still reports `battery.charge: 100` and a
plausible `battery.runtime`, because those are estimates derived from the
charger's float voltage, not measurements under load.

The UPS can also load-test itself. `install.sh` sets up a NUT admin user and
a wrapper for it:

```sh
sudo ups-selftest          # quick test, ~10 s on battery
sudo ups-selftest --deep   # longer test
```

It prints `ups.test.result` as the UPS updates it and ends with PASSED or
FAILED (which also raises the `RB` status flag). **The test puts the load on
battery**, so a bad battery drops the outlets just like a real outage. Run it
with only a lamp on the UPS, or accept that the machine may lose power.

## Troubleshooting

- **Driver logs "insufficient permissions" / "No matching HID UPS found"**:
  the UPS device node is not owned by group `nut`. `install.sh` re-triggers
  udev for the UPS, but a replug also fixes it. Check with
  `ls -l /dev/bus/usb/*/*` against `lsusb | grep 0764`.
- **`upsc` says "Data stale" or the driver won't start**: check
  `journalctl -u nut-driver@cyberpower`. Unplug and replug the UPS USB cable.
  CyberPower units occasionally drop off USB; `pollfreq`/`pollinterval` are
  already relaxed in `ups.conf`.
- **Machine halted but UPS outlets stayed on**: the `nutshutdown` hook did not
  run or `upsdrvctl shutdown` failed. Check that `/etc/killpower` was created
  (it is removed on the next boot, so look in the previous boot's journal:
  `journalctl -b -1 -u nut-monitor`), and that `upscmd -l cyberpower` lists
  `shutdown.return`.
- **Rig died instantly when the plug was pulled, UPS turned off too**: the
  battery did not take the load. See "Before relying on it" above. Nothing in
  the logs is expected in this case.
- **Machine rebooted on battery after the shutdown, then shut down again**:
  that is the retry design working (see "Why the retry design"). The log line
  reads `BOOTED INTO ONGOING OUTAGE`. Raise `ONDELAY` to retry less often.
- **Machine stays off after power returns, UPS dark**: `ONDELAY` is -1 or the
  UPS did not accept the timer (the installer warns if `ups.delay.start`
  reads back differently). Press the UPS button, fix `ONDELAY`, re-run the
  installer.
- **Machine did not power on when utility returned**: confirm BIOS
  *AC BACK = Always On*, and that the machine is on a battery-backed outlet.
- **Stale `/etc/killpower` after a normal boot**: `sudo rm /etc/killpower`.
- **Changing the upsmon or admin password**: delete `/etc/nut/upsd.users` and
  re-run `sudo ./install.sh`; new ones are generated and applied everywhere
  (`upsmon.conf`, `/etc/ups-agent/admin.pass`).

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
install.env.example   tunables; copied to /etc/ups-agent/install.env
config/               NUT config templates -> /etc/nut/
scripts/upssched-cmd  event handler -> /usr/local/lib/ups-agent/
scripts/ups-agent-log minute status logger -> /usr/local/lib/ups-agent/
scripts/ups-selftest  battery self-test wrapper -> /usr/local/sbin/ups-selftest
systemd/              ups-agent-log.service + .timer
etc/sudoers.d/        lets user nut run `upsmon -c fsd`
etc/logrotate.d/      rotation for /var/log/ups-agent
```
