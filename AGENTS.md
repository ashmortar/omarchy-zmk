# Working on omarchy-zmk

Read `ARCHITECTURE.md` first. It says what the host can observe about a
ZMK keyboard and why the plugin is built the way it is. Most bad changes
to this repo come from guessing at something that table already answers.

## Layout

- `BarWidget.qml` is the whole widget: bar icon, popup, polling. It is
  built on the shell's own `qs.Ui` components, which third-party plugins
  can import. Don't hand-roll popups or buttons.
- `script/zmk-status` gathers every fact and prints one line of JSON. The
  widget and the script meet only at that JSON. Don't move logic across
  that line.
- `tests/test-script.sh` covers the script. It sources the script, so
  `main` must stay behind the `BASH_SOURCE` guard.

## Commands

```bash
tests/test-script.sh          # must end with "all tests passed"
bash -n script/zmk-status
omarchy plugin validate .     # the manifest checks the shell enforces
omarchy restart shell         # then check the journal, see below
omarchy-shell ashmortar.zmk status | jq .
```

## Rules

- Comments explain why, never what. If a comment describes the next
  line, delete it and fix the names instead.
- Tabs in the bash script, two spaces in QML. The python inside the
  script's heredoc is indented with tabs (stripped by `<<-`) followed by
  spaces for python's own indentation. Keep it that way.
- No em-dashes anywhere, code comments included.
- Every external call in the script runs under `timeout`. The widget's
  watchdog is 30 seconds; the script must finish well inside it.
- No daemons, no long-lived watchers. The only background process is
  the evdev reader, which `timeout` kills.
- Never call `bluetoothctl`. It aborts inside libdbus when BlueZ's object
  tree changes under it, and every abort raises a crash notification.
  Everything it offered is available over `busctl`.
- The JSON keys the script prints are a contract with the widget. Add
  keys if you must; don't rename or drop any.
- Binaries resolve from the script's fixed PATH; in QML use absolute
  `/usr/bin/...` paths for `timeout` and `busctl`. New external input
  gets a size cap before it is parsed.

## Working on this machine

This directory is the live plugin. The shell watches it and hot-reloads
on every save, and that reload sometimes wedges silently, keeping the old
widget instance alive. After editing, run `omarchy restart shell`, wait a
few seconds, then:

```bash
journalctl --user --since "-20s" --no-pager -q | grep -i -E 'Plugin widget|ashmortar' | grep -v DEBUG
qs -p /usr/share/omarchy/shell ipc show | grep -A9 'target ashmortar.zmk'
```

A `Plugin widget ashmortar.zmk failed:` line is a QML error to fix. The
IPC listing should show the current function set.

Never use `pkill -f` with a pattern that also appears in your own command
line. Match argv fields instead, and run any kill in its own command.

## Testing without the hardware

The script reads its inputs from environment variables so the tests never
touch the real machine: `BLUEZ_OBJECTS_FILE` replaces the D-Bus document
(`tests/fixtures/bluez-objects.json` is a real capture with a synthetic
address), `INPUT_DEVICES_FILE` replaces `/proc/bus/input/devices`, and
`USB_DEVICES_DIR` and `HID_DEVICES_DIR` replace the sysfs trees. Use them
for any new test rather than reading the host.
