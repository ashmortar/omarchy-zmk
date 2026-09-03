# Architecture

How `omarchy-zmk` decides what to show, where each fact comes from, and
why I built it the way I did. Read this before changing the script or the
widget.

## What the host can see

A ZMK keyboard exposes different things over each link. This table is
the whole design space. If something isn't in it, the host can't observe
it, and the widget doesn't pretend otherwise.

| Fact | Source | Notes |
|---|---|---|
| Bluetooth link up | BlueZ `Device1.Connected` | Also drives last-seen |
| Battery per piece | GATT Battery Service `0x2A19`, one instance per piece | Only while the BLE link is up. ZMK proxies each peripheral's level through the central, and a peripheral instance carries a `0x2901` User Description of `Peripheral N`. A single-piece board has one instance, a split has two, and ZMK allows more |
| Keyboard name | BlueZ `Device1.Alias` (GAP Device Name) | The DIS Model Number is the same string |
| Vendor, product, firmware version | DIS PnP ID `0x2A50` over BLE; `idVendor`, `idProduct`, `bcdDevice` over USB | ZMK ships no Firmware Revision characteristic |
| USB cable present | `/sys/bus/usb/devices/*/idVendor:idProduct` | Power only. A cabled peripheral enumerates without HID |
| USB input path bound | `/sys/bus/hid/devices/0003:VID:PID.*` | Only a cabled central binds HID |
| Which link carries keystrokes | evdev key events on the USB node (bus 0003) versus the Bluetooth node (bus 0005) | The only sign the host gets of ZMK's selected output |
| Wake, trusted, paired, bonded | BlueZ `Device1` properties | `WakeAllowed` and `Trusted` are writable |
| USB serial | sysfs `serial` | Wired only |

Not visible from the host: which of ZMK's five Bluetooth profiles is
active, the firmware's own idea of charging, a forced output mode until
you press a key, and any battery at all over USB. A dongle build (a third
board acting as the split's central, plugged into the host) is USB-only
as far as the host knows, so it reads as wired with no battery.

## What the widget derives from that

**Connection** is the path keystrokes take, not which links exist.

```
hid bound and BLE up  -> whichever node carried the latest keystroke;
                         wired until one has been seen (ZMK's default)
hid bound only        -> wired
BLE up only           -> bluetooth
neither               -> none
```

**Battery rows** are one per Battery Service instance, in the order ZMK
reports them. The unlabeled instance is the central. The others carry
ZMK's own `Peripheral N` descriptor. The popup and tooltip use the full
words: Central, Peripheral, or Peripheral 0 and Peripheral 1 when there
are several. Only the bar's percentage text and the script's `text` field
use the short forms C, P, P0, P1. A single-piece board has one instance
and no label anywhere. The host can't see which physical side is the
central, so I don't guess at left or right.

**Charging** is where the cable is. A cabled central binds HID and a
cabled peripheral never does, so "HID bound" tells you which piece is
charging. ZMK pins the charging piece's reported percentage, so the
widget hides that number behind a bolt. With more than one peripheral the
cabled one can't be told apart from the others, so the popup says "cable
on a peripheral" without naming it.

**Low battery** is any instance at or below `lowThreshold` while not
charging. It turns the bar icon urgent and sends one desktop notification
per threshold crossing. The flag clears five points above the threshold,
so a value that flaps around the line can't spam you.

**Drain estimate** uses up to 48 hours of unplugged readings per
instance. It wants at least an hour of span and a two-point drop, and it
refuses to print anything beyond 30 days. Cabled readings aren't
recorded, and a plugged-in stretch longer than six hours resets the
history. A reading that rises by more than a point also resets it,
wherever it happens: a rise means the piece charged, and the slope from
before that is meaningless.

**Error and warning** separate a script that couldn't do its job from a
script that ran fine but has bad news. `error` is set when BlueZ itself
couldn't be reached or its reply couldn't be read, and it means every
other field in the line is a guess, not an observation; the widget shows
it in the tooltip and the popup meta line ahead of everything else. This
is different from the widget's own Error state, which is the script
process itself failing to run or exiting non-zero. `warning` is set for
a problem the script can still report around, such as a pinned MAC
matching no paired board or the keystroke reader being unavailable; the
widget shows it in the popup detail line, and, when nothing is found at
all, in the tooltip in place of the generic pairing hint.

## Components

```
BarWidget.qml (Panel from qs.Ui)
  BarIconButton   glyph, color by state, tooltip, click routing
  KeyboardPanel   popup: header, battery rows, details, actions
  Process         runs script/zmk-status, one JSON line per run
  Timer           refreshIntervalSec, default 10s
  Timer           30s watchdog that reaps a hung run

script/zmk-status
  busctl: one ObjectManager call for every BlueZ fact, plus one GATT read per battery
  sysfs for USB and HID
  one timeout-bounded evdev reader for both keyboard nodes
  $XDG_RUNTIME_DIR/omarchy-zmk/<MAC>/ for state
```

The widget owns presentation and settings. The script owns every fact and
prints Waybar-style JSON, so it also works as a plain command module or
from a terminal. The two meet only at that JSON line.

### Bounds

Every external call, script and widget alike, runs under a TERM-then-KILL
deadline. The BlueZ document is capped at 2 MB, battery instances at 8,
and the name at 64 characters. The widget rejects an output line over
64 KB. The script resolves every binary it runs from a fixed PATH.

### Polling, not events

My first version watched D-Bus, udev, and GATT notifications from a
long-lived daemon. It leaked processes on every shell reload and wedged
on its own lock file. So this one polls. Each run is a fresh process that
exits, and the only thing that outlives a run is the keystroke reader,
which `timeout` bounds and which never gets re-spawned while one is
alive. You wait one refresh interval for a change to show up, which at
10 seconds is fine for a battery gauge.

### One D-Bus call per poll

Discovering the board and its GATT characteristics one property at a time
cost about 110 processes and 190 ms of CPU per poll. Now one
`GetManagedObjects` call returns every device, characteristic,
descriptor, and BlueZ's cached values as a single JSON document, and `jq`
picks out what the script needs. That leaves two GATT reads per poll for
fresh battery values (BlueZ's cached values can be stale) and brings a
poll to about 40 processes and 60 ms of CPU. Most of the remaining wall
time is the two radio round trips, which cost no CPU.

The same call is how the script picks a board when you haven't pinned
one: a connected ZMK board first, then any paired one. A second board in
a drawer never shadows the one you're typing on.

### Keystroke path sampling

With both links up, each poll starts one reader that watches both
keyboard evdev nodes for the whole window, unless one is already alive.
On every `EV_KEY` event it stamps that path with a millisecond timestamp,
at most twice a second, and keeps listening. So if you toggle output and
type, the newer stamp is on the right path immediately.

The window is one second short of the refresh interval, capped at 60
seconds, so short intervals have no gap and long ones sample the first
minute. Only `EV_KEY` counts: the host echoes LED writes to every
keyboard node, and those would stamp both paths at once. Reading
`/dev/input/event*` needs the `input` group. Without it the reader is
skipped and the both-links-up case reads as wired.

A missing `python3` is reported as a `warning` rather than failing
silently: the both-links-up case still reads as wired, but the popup
says why the keystroke path can't be told apart.

### State directory

Everything the script keeps between runs lives under
`$XDG_RUNTIME_DIR/omarchy-zmk/<MAC>/`: battery labels, drain history,
notification flags, keystroke stamps, the reader's pid, and the cached
device id. Two boards never share a directory.

### Multiple bars

Each bar instance polls on its own timer. The keystroke reader is
deduplicated through its pid file, and a history append is skipped when
the value hasn't changed inside five minutes, so a two-monitor setup
doesn't double the drain samples. Two widget instances for two boards
aren't supported in this release, because the shell keys inline settings
and IPC by plugin id.

## Widget behavior

Bar icon: theme accent while wired, bar foreground on Bluetooth, dimmed
when nothing is connected, urgent when any battery is low. Right click
toggles percentages next to the icon, one number per instance in ZMK's
order, with a bolt for a charging piece. The whole text turns urgent when
any instance is low, because the bar glyph is a single color. Middle
click refreshes. Left click opens the popup. When no keyboard is found
the icon stays visible, dimmed, and the tooltip says to pair the board.

Popup: a `PanelHero` header like the shell's own panels, with the
keyboard glyph, the name, a meta line such as "Bluetooth · Central
charging", and the last-seen or updated time as the detail. Then a
battery row per instance with a drain estimate, or a bolt for a charging
piece, in a readout column sized to the widest readout so every track
ends at the same point. Then details (device id, serial, address, wake
toggle), a Connect Bluetooth button whenever the BLE link is down and
BlueZ knows the board, and a small Open ZMK Studio link that's live only
while cabled, since the web app needs USB serial. The popup takes
keyboard focus like every shell panel: Esc closes, Tab switches panels,
R connects, W toggles wake, P toggles percentages, S opens Studio.

## Settings

Inline on the shell.json layout entry, all optional.

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | 10 | Poll interval, 10 to 600 seconds |
| `lowThreshold` | 15 | Percent at or below which a battery is low |
| `macAddress` | empty | Leave empty to pick the connected ZMK board, or any paired one; set it to pin a specific board |
| `usbId` | `1D50:615E` | ZMK's assigned VID:PID, either case |
| `deviceName` | empty | Name to show until the board has been seen |
| `showPercent` | false | A percentage per battery instance in the bar; right click toggles it |

## Testing

`tests/test-script.sh` covers the script's pure functions and runs it end
to end against a fixture. The script takes its inputs from environment
variables so the tests never touch the real machine:
`BLUEZ_OBJECTS_FILE` replaces the D-Bus document, `INPUT_DEVICES_FILE`
replaces `/proc/bus/input/devices`, and `USB_DEVICES_DIR` and
`HID_DEVICES_DIR` replace the two sysfs trees. `omarchy plugin validate .`
runs the same manifest checks the shell enforces.
