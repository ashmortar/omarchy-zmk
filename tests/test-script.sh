#!/usr/bin/env bash
# Unit tests for the script's functions plus end-to-end runs against the
# BlueZ fixture and a busctl stub. Sourcing the script defines its
# functions without running main; everything that touches the system is
# redirected into a temp dir via the variables set below.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
assert_eq() {
	if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi
}

export XDG_RUNTIME_DIR="$tmp"
export INPUT_DEVICES_FILE="$tmp/devices"
# shellcheck source=../script/zmk-status
source "$here/../script/zmk-status" "" "1d50:615e" 15 10
STATE_DIR="$tmp/omarchy-zmk/E2_D9"
mkdir -p "$STATE_DIR"

# A real stub file, not a shell function: low_notify now runs NOTIFY_CMD
# under timeout, which execs a named program and never sees shell functions.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/omarchy-notification-send" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$tmp/notify.log"
STUB
chmod +x "$tmp/bin/omarchy-notification-send"
NOTIFY_CMD="$tmp/bin/omarchy-notification-send"

assert_eq "usb id upper" "$usb_id_upper" "1D50:615E"
assert_eq "usb id lower" "$usb_id_lower" "1d50:615e"

assert_eq "label single" "$(battery_label "" 1)" "|"
assert_eq "label central of two" "$(battery_label "" 2)" "C|Central"
assert_eq "label lone peripheral" "$(battery_label "Peripheral 0" 2)" "P|Peripheral"
assert_eq "label peripheral 1 of three" "$(battery_label "Peripheral 1" 3)" "P1|Peripheral 1"
assert_eq "label peripheral 0 of three" "$(battery_label "Peripheral 0" 3)" "P0|Peripheral 0"

assert_eq "type both links no stamps" "$(decide_type true yes 0 0)" "wired"
assert_eq "type both links ble newer" "$(decide_type true yes 5 9)" "bluetooth"
assert_eq "type both links usb newer" "$(decide_type true yes 9 5)" "wired"
assert_eq "type hid only" "$(decide_type true no 0 0)" "wired"
assert_eq "type ble only" "$(decide_type false yes 0 0)" "bluetooth"
assert_eq "type neither" "$(decide_type false no 0 0)" "none"

cable_present=true; hid_present=true
assert_eq "charging cabled central" "$(charging_role central 1)" "true"
assert_eq "charging peripheral while central cabled" "$(charging_role peripheral 1)" "false"
cable_present=true; hid_present=false
assert_eq "charging lone cabled peripheral" "$(charging_role peripheral 1)" "true"
assert_eq "charging ambiguous peripheral" "$(charging_role peripheral 2)" "false"
assert_eq "charging central cabled but hid unbound" "$(charging_role central 1)" "false"
cable_present=false; hid_present=false
assert_eq "charging no cable" "$(charging_role central 1)" "false"

assert_eq "humanize 47h" "$(humanize_hours 47)" "47h"
assert_eq "humanize 48h" "$(humanize_hours 48)" "2d"
assert_eq "delta 30s" "$(humanize_delta 30)" "30s ago"
assert_eq "delta 1h" "$(humanize_delta 3600)" "1h ago"
assert_eq "delta 2d" "$(humanize_delta 172800)" "2d ago"

now=$(date +%s)
printf '%s 100\n%s 97\n' $((now - 36000)) $((now - 3600)) > "$STATE_DIR/bat1.history"
assert_eq "eta real drop" "$(drain_eta_hours bat1 97)" "291"
printf '%s 100\n%s 98\n' $((now - 172000)) $((now - 3600)) > "$STATE_DIR/bat1.history"
assert_eq "eta beyond cap" "$(drain_eta_hours bat1 97)" ""
printf '%s 100\n%s 99\n' $((now - 36000)) $((now - 3600)) > "$STATE_DIR/bat1.history"
assert_eq "eta one point drop" "$(drain_eta_hours bat1 97)" ""
printf '%s 100\n%s 100\n' $((now - 36000)) $((now - 3600)) > "$STATE_DIR/bat1.history"
assert_eq "eta flat" "$(drain_eta_hours bat1 97)" ""

cable_present=false
rm -f "$STATE_DIR/bat2.history"
record_history bat2 90; record_history bat2 89
assert_eq "history dedupes within 3s" "$(wc -l < "$STATE_DIR/bat2.history")" "1"

now=$(date +%s)
rm -f "$STATE_DIR/bat10.history"
printf '%s 80\n%s 79\n' $((now - 200000)) $((now - 100)) > "$STATE_DIR/bat10.history"
record_history bat10 70
assert_eq "record_history prunes rows past the 48h window" "$(wc -l < "$STATE_DIR/bat10.history")" "2"
assert_eq "record_history prune drops the oldest row" "$(head -n 1 "$STATE_DIR/bat10.history" | cut -d ' ' -f1)" "$((now - 100))"

rm -f "$STATE_DIR/bat11.history"
printf '%s 60\n%s 58\n' $((now - 7200)) $((now - 3600)) > "$STATE_DIR/bat11.history"
record_history bat11 90
assert_eq "record_history resets history on a rise" "$(wc -l < "$STATE_DIR/bat11.history")" "1"
assert_eq "record_history rise keeps only the new value" "$(tail -n 1 "$STATE_DIR/bat11.history" | cut -d ' ' -f2)" "90"

cat > "$INPUT_DEVICES_FILE" <<'DEV'
I: Bus=0003 Vendor=1d50 Product=615e Version=0111
N: Name="ZMK Project liminal Keyboard"
H: Handlers=sysrq kbd leds event28

I: Bus=0003 Vendor=1d50 Product=615e Version=0111
N: Name="ZMK Project liminal Mouse"
H: Handlers=event29 mouse4

I: Bus=0005 Vendor=1d50 Product=615e Version=0001
N: Name="liminal Keyboard"
H: Handlers=sysrq kbd leds event3
DEV
assert_eq "usb keyboard node" "$(input_node_for_bus 0003)" "/dev/input/event28"
assert_eq "ble keyboard node" "$(input_node_for_bus 0005)" "/dev/input/event3"
assert_eq "missing bus" "$(input_node_for_bus 0007)" ""

assert_eq "sample window from interval" "$(sample_window_sec 10)" "9"
assert_eq "sample window floor" "$(sample_window_sec 1)" "2"
assert_eq "sample window cap" "$(sample_window_sec 600)" "60"

assert_eq "tooltip found bluetooth with batteries" "$(tooltip_text "" true liminal bluetooth "" "Central 93% · Peripheral 95%")" $'liminal · Bluetooth\nCentral 93% · Peripheral 95%'
assert_eq "tooltip found none with lastseen" "$(tooltip_text "" true liminal none "3m ago" "")" "liminal · Not connected · last seen 3m ago"
assert_eq "tooltip not found" "$(tooltip_text "" false "" none "" "")" "No ZMK keyboard found · pair it over Bluetooth"
assert_eq "tooltip leaves quote in name unescaped" "$(tooltip_text "" true 'lim"inal' wired "" "")" 'lim"inal · Wired'
assert_eq "tooltip error takes priority" "$(tooltip_text "BlueZ unreachable" true liminal bluetooth "" "")" "ZMK: BlueZ unreachable"
assert_eq "tooltip warning replaces not-found text" "$(tooltip_text "" false "" none "" "" "no paired board at AA:BB:CC:DD:EE:FF")" "no paired board at AA:BB:CC:DD:EE:FF"

assert_eq "label fallthrough" "$(battery_label "Whatever" 2)" "C|Central"

now=$(date +%s)
printf '%s 100\n%s 95\n' $((now - 1800)) "$now" > "$STATE_DIR/bat5.history"
assert_eq "eta span under hour" "$(drain_eta_hours bat5 95)" ""

rm -f "$STATE_DIR/bat3.notified" "$tmp/notify.log"
low_notify bat3 Central 15
assert_eq "low_notify creates flag" "$([ -e "$STATE_DIR/bat3.notified" ] && echo yes || echo no)" "yes"
assert_eq "low_notify logs once" "$(wc -l < "$tmp/notify.log")" "1"
low_notify bat3 Central 14
assert_eq "low_notify no duplicate log" "$(wc -l < "$tmp/notify.log")" "1"
low_notify bat3 Central 19
assert_eq "low_notify keeps flag inside hysteresis" "$([ -e "$STATE_DIR/bat3.notified" ] && echo yes || echo no)" "yes"
low_notify bat3 Central 20
assert_eq "low_notify clears flag above hysteresis" "$([ -e "$STATE_DIR/bat3.notified" ] && echo yes || echo no)" "no"

cable_present=false
rm -f "$STATE_DIR/bat4.history"
printf '%s 90\n' $((now - 60)) > "$STATE_DIR/bat4.history"
record_history bat4 90
assert_eq "record_history skips unchanged value" "$(wc -l < "$STATE_DIR/bat4.history")" "1"
record_history bat4 89
assert_eq "record_history appends changed value" "$(wc -l < "$STATE_DIR/bat4.history")" "2"

cable_present=true
# Value matches the last row (no rise), so this exercises the staleness
# check alone rather than the history-reset path.
printf '%s 90\n%s 80\n' $((now - 7200)) $((now - 3600)) > "$STATE_DIR/bat6.history"
record_history bat6 80
assert_eq "record_history cable 1h old kept" "$(wc -l < "$STATE_DIR/bat6.history")" "2"
printf '%s 90\n%s 80\n' $((now - 36000)) $((now - 25200)) > "$STATE_DIR/bat7.history"
record_history bat7 80
assert_eq "record_history cable 7h old truncated" "$(wc -l < "$STATE_DIR/bat7.history")" "0"
cable_present=false

fixture="$here/fixtures/bluez-objects.json"
objects=$(cat "$fixture")

assert_eq "select_device connected path" "$(select_device "$objects" "" | cut -d $'\x1f' -f1)" "/org/bluez/hci0/dev_E2_D9_27_00_00_AA"
assert_eq "select_device connected alias" "$(select_device "$objects" "" | cut -d $'\x1f' -f3)" 'lim"inal'
assert_eq "select_device connected flag" "$(select_device "$objects" "" | cut -d $'\x1f' -f4)" "true"
assert_eq "select_device pinned mac wins" "$(select_device "$objects" "aa:bb:cc:dd:ee:01" | cut -d $'\x1f' -f1)" "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01"
assert_eq "select_device unknown mac empty" "$(select_device "$objects" "00:00:00:00:00:00")" ""

# A connected device that isn't a ZMK board must not shadow the real one,
# and dropping connected state on both ZMK devices should still fall back
# to a paired one rather than reporting nothing.
jq '.data[0]["/org/bluez/hci0/dev_nonzmk"] = {"org.bluez.Device1":{"Address":{"type":"s","data":"00:4C:00:00:00:01"},"Alias":{"type":"s","data":"Other"},"Connected":{"type":"b","data":true},"Paired":{"type":"b","data":true},"Bonded":{"type":"b","data":true},"Trusted":{"type":"b","data":true},"WakeAllowed":{"type":"b","data":false},"Modalias":{"type":"s","data":"bluetooth:v004Cp0001"}}}' "$fixture" > "$tmp/nonzmk.json"
nonzmk_objects=$(cat "$tmp/nonzmk.json")
assert_eq "select_device ignores a connected non-ZMK device" "$(select_device "$nonzmk_objects" "" | cut -d $'\x1f' -f1)" "/org/bluez/hci0/dev_E2_D9_27_00_00_AA"

jq '.data[0]["/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01"]["org.bluez.Device1"].Connected.data = false | .data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Connected.data = false' "$fixture" > "$tmp/allpaired.json"
allpaired_objects=$(cat "$tmp/allpaired.json")
allpaired_path=$(select_device "$allpaired_objects" "" | cut -d $'\x1f' -f1)
assert_eq "select_device falls back to a paired board" "$(case "$allpaired_path" in /org/bluez/hci0/dev_AA_BB_CC_DD_EE_01|/org/bluez/hci0/dev_E2_D9_27_00_00_AA) echo yes;; *) echo no;; esac)" "yes"

assert_eq "battery_chars count" "$(battery_chars "$objects" /org/bluez/hci0/dev_E2_D9_27_00_00_AA | wc -l)" "2"
assert_eq "battery_chars peripheral label" "$(battery_chars "$objects" /org/bluez/hci0/dev_E2_D9_27_00_00_AA | sed -n 2p | cut -d $'\x1f' -f2)" "Peripheral 0"
assert_eq "battery_chars central label empty" "$(battery_chars "$objects" /org/bluez/hci0/dev_E2_D9_27_00_00_AA | sed -n 1p | cut -d $'\x1f' -f2)" ""
assert_eq "battery_chars descriptor path" "$(battery_chars "$objects" /org/bluez/hci0/dev_E2_D9_27_00_00_AA | sed -n 2p | cut -d $'\x1f' -f3)" "/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service0015/char0016/desc001a"

assert_eq "pnp_char bytes" "$(pnp_char "$objects" /org/bluez/hci0/dev_E2_D9_27_00_00_AA | cut -d $'\x1f' -f2)" "1 80 29 94 97 1 0"

# Regression: tab was IFS whitespace, so consecutive delimiters around an
# empty middle field collapsed and shifted every field after it. The unit
# separator does not collapse, so an empty descriptor value still leaves
# the descriptor path in place.
jq 'del(.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service0015/char0016/desc001a"]["org.bluez.GattDescriptor1"].Value)' "$fixture" > "$tmp/nodesc.json"
nodesc_objects=$(cat "$tmp/nodesc.json")
IFS=$'\x1f' read -r nodesc_char nodesc_raw nodesc_desc_path <<<"$(battery_chars "$nodesc_objects" /org/bluez/hci0/dev_E2_D9_27_00_00_AA | sed -n 2p)"
assert_eq "battery_chars missing descriptor value keeps raw empty" "$nodesc_raw" ""
assert_eq "battery_chars missing descriptor value keeps path" "$nodesc_desc_path" "/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service0015/char0016/desc001a"

# usb_version_suffix: junk bcdDevice must not error inside the hex expansion.
assert_eq "usb_version_suffix valid bcd" "$(usb_version_suffix 0305)" " v3.5"
assert_eq "usb_version_suffix invalid bcd" "$(usb_version_suffix zz)" ""

pidtest_dir="$tmp/pidfile-test"
mkdir -p "$pidtest_dir"
printf -- '-1\n' > "$pidtest_dir/inpath.pid"
STATE_DIR="$pidtest_dir" sample_input_paths "" ""
assert_eq "sample_input_paths no nodes leaves pidfile" "$(cat "$pidtest_dir/inpath.pid")" "-1"
assert_eq "reader_alive rejects -1" "$(reader_alive "$pidtest_dir/inpath.pid" && echo yes || echo no)" "no"
printf '%s' "$$" > "$pidtest_dir/inpath.pid"
assert_eq "reader_alive rejects a live non-reader pid" "$(reader_alive "$pidtest_dir/inpath.pid" && echo yes || echo no)" "no"
rm -f "$pidtest_dir/missing.pid"
assert_eq "reader_alive rejects a missing pidfile" "$(reader_alive "$pidtest_dir/missing.pid" && echo yes || echo no)" "no"

STATE_DIR="$tmp/omarchy-zmk/E2_D9"

# End-to-end runs. Every case shares a busctl stub location and an
# unconditional notification stub, and gets its own runtime dir so state
# from one case never leaks into the next.
: > "$tmp/empty-file"
mkdir -p "$tmp/empty"

run_e2e() {
	local name="$1" fixture_arg="$2" usbdir="$3" hiddir="$4"
	shift 4
	local rt="$tmp/rt-$name"
	mkdir -p "$rt"
	ZMK_STATUS_PATH="$tmp/bin:/usr/bin:/bin" \
		ZMK_NOTIFY_CMD="$tmp/bin/omarchy-notification-send" \
		XDG_RUNTIME_DIR="$rt" \
		INPUT_DEVICES_FILE="$tmp/empty-file" \
		BLUEZ_OBJECTS_FILE="$fixture_arg" \
		USB_DEVICES_DIR="$usbdir" \
		HID_DEVICES_DIR="$hiddir" \
		bash "$here/../script/zmk-status" "$@" > "$tmp/out.json"
}

# Every end-to-end case asserts against the same output file. -c so an
# array field compares on one line, -r so a string field has no quotes.
assert_json() {
	assert_eq "$1" "$(jq -rc "$2" "$tmp/out.json")" "$3"
}

assert_json_valid() {
	assert_eq "$1" "$(jq -e . "$tmp/out.json" >/dev/null 2>&1 && echo valid)" "valid"
}

# Takes the case body on stdin so a case says only how busctl answers,
# without repeating the shebang and the chmod.
write_busctl_stub() {
	{ printf '#!/usr/bin/env bash\n'; cat; } > "$tmp/bin/busctl"
	chmod +x "$tmp/bin/busctl"
}

stub_busctl_level93() {
	write_busctl_stub <<'STUB'
case "$*" in
	*ReadValue*) echo 'ay 1 93' ;;
	*) exit 1 ;;
esac
STUB
}

stub_busctl_level93
run_e2e "bt-base" "$fixture" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json_valid "e2e json valid"
assert_json "e2e json name" .name 'lim"inal'
assert_json "e2e json found" .found "true"
assert_json "e2e json ble" .ble "true"
assert_json "e2e json type" .type "bluetooth"
assert_json "e2e json cable" .cable "false"
assert_json "e2e json address" .address "E2:D9:27:00:00:AA"
assert_json "e2e json path" .path "/org/bluez/hci0/dev_E2_D9_27_00_00_AA"
assert_json "e2e json devid" .devid "1D50:615E v0.1"
assert_json "e2e json battery count" '.batteries | length' "2"
assert_json "e2e json battery0 name" '.batteries[0].name' "Central"
assert_json "e2e json battery1 name" '.batteries[1].name' "Peripheral"
assert_json "e2e json battery1 value" '.batteries[1].value' "93"
assert_json "e2e json wake" .wake "true"
assert_json "e2e json error empty" .error ""
assert_json "e2e json warning empty" .warning ""

# Regression: an empty Alias used to shift every field after it off the
# end of the row, emitting invalid JSON ("wake": with no value).
jq '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Alias.data = ""' "$fixture" > "$tmp/noalias.json"
run_e2e "noalias" "$tmp/noalias.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json_valid "e2e empty alias json valid"
assert_json "e2e empty alias wake" .wake "true"
assert_json "e2e empty alias name" .name ""

# Regression: a control byte or angle bracket in a rename-able alias used to
# truncate the row at `read` or render as rich text in the shell.
jq '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Alias.data = "bad\nname<b>x</b>"' "$fixture" > "$tmp/badalias.json"
run_e2e "badalias" "$tmp/badalias.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json_valid "e2e bad alias json valid"
assert_json "e2e bad alias name" .name "badnamebx/b"
assert_json "e2e bad alias wake" .wake "true"
assert_json "e2e bad alias paired" .paired "true"

# Regression: a 0x1F byte in a descriptor value used to shift the
# unit-separated battery_chars fields; a quote in the value must still
# flow through safely now that jq escapes it building the JSON line.
# Value is the codepoints of Peri<0x1F>pheral 0".
jq '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service0015/char0016/desc001a"]["org.bluez.GattDescriptor1"].Value.data = [80,101,114,105,31,112,104,101,114,97,108,32,48,34]' "$fixture" > "$tmp/descbad.json"
run_e2e "descbad" "$tmp/descbad.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json_valid "e2e descriptor control byte json valid"
assert_json "e2e descriptor control byte battery1 name" '.batteries[1].name' "Peripheral"

# Regression: a tampered label cache file used to be trusted verbatim, so a
# quote and colon in it could inject a sibling JSON key.
write_busctl_stub <<'STUB'
case "$*" in
	*GattDescriptor1*ReadValue*) exit 1 ;;
	*ReadValue*) echo 'ay 1 93' ;;
	*) exit 1 ;;
esac
STUB
jq 'del(.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service0015/char0016/desc001a"]["org.bluez.GattDescriptor1"].Value)' "$fixture" > "$tmp/tamperfix.json"
mkdir -p "$tmp/rt-tamper/omarchy-zmk/E2_D9_27_00_00_AA"
printf '%s' 'Peripheral 0","injected":"yes' > "$tmp/rt-tamper/omarchy-zmk/E2_D9_27_00_00_AA/bat2.label"
run_e2e "tamper" "$tmp/tamperfix.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json_valid "e2e tampered label cache json valid"
assert_json "e2e tampered label cache no injected key" 'has("injected") | not' "true"

# Regression: an unvalidated address became a state directory name, so a
# path-traversal alias could walk the state dir anywhere on disk.
stub_busctl_level93
jq '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Address.data = "../escape"' "$fixture" > "$tmp/badaddr.json"
run_e2e "badaddr" "$tmp/badaddr.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "e2e bad address found false" .found "false"
assert_json "e2e bad address empty" .address ""
assert_eq "e2e bad address no traversal dir" "$([ ! -e "$tmp/rt-badaddr/escape" ] && echo yes || echo no)" "yes"

mkdir -p "$tmp/usb/1-2" "$tmp/hid/0003:1D50:615E.0004"
printf '1d50' > "$tmp/usb/1-2/idVendor"
printf '615e' > "$tmp/usb/1-2/idProduct"
printf '0305' > "$tmp/usb/1-2/bcdDevice"
printf 'ABC\n\x01' > "$tmp/usb/1-2/serial"
jq '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Connected.data = false' "$fixture" > "$tmp/wired-only.json"
run_e2e "wired1" "$tmp/wired-only.json" "$tmp/usb" "$tmp/hid" "" 1d50:615e 15 10
assert_json "wired only type" .type "wired"
assert_json "wired only cable" .cable "true"
assert_json "wired only hid" .hid "true"
assert_json "wired only devid" .devid "1D50:615E v3.5"
assert_json "wired only usbSerial" .usbSerial "ABC"
assert_json "wired only found" .found "true"
assert_json "wired only batteries empty" .batteries "[]"

# No keystroke stamp yet, so ZMK's own USB default wins.
stub_busctl_level93
run_e2e "wiredble" "$fixture" "$tmp/usb" "$tmp/hid" "" 1D50:615E 15 10
assert_json "wired ble type" .type "wired"
assert_json "wired ble battery0 charging" '.batteries[0].charging' "true"
assert_json "wired ble battery1 charging" '.batteries[1].charging' "false"
assert_json "wired ble text" .text '󰌌 C:chg P:93'
assert_eq "wired ble tooltip second line" "$(jq -r .tooltip "$tmp/out.json" | sed -n 2p)" "Central charging · Peripheral 93%"

jq 'del(.data[0]["/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01"]) | del(.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"])' "$fixture" > "$tmp/nodevice.json"
run_e2e "cableonly" "$tmp/nodevice.json" "$tmp/usb" "$tmp/hid" "" 1D50:615E 15 10
assert_json "cable only found" .found "true"
assert_json "cable only address empty" .address ""
assert_json "cable only tooltip" .tooltip "ZMK keyboard · Wired"
assert_eq "cable only no state subdirs" "$(find "$tmp/rt-cableonly/omarchy-zmk" -mindepth 1 | wc -l)" "0"

stub_busctl_level93
rm -f "$tmp/notify.log"
run_e2e "urgent" "$fixture" "$tmp/empty" "$tmp/empty" "" 1D50:615E 95 10
assert_json "urgent class" .class "urgent"
assert_eq "urgent notify log first run" "$(wc -l < "$tmp/notify.log")" "2"
run_e2e "urgent" "$fixture" "$tmp/empty" "$tmp/empty" "" 1D50:615E 95 10
assert_eq "urgent notify log second run unchanged" "$(wc -l < "$tmp/notify.log")" "2"

# A torn GATT reply must never render as a bogus percentage.
: > "$tmp/torn-count"
write_busctl_stub <<STUB
case "\$*" in
	*GattCharacteristic1*ReadValue*)
		n=\$(( \$(cat "$tmp/torn-count" 2>/dev/null || echo 0) + 1 ))
		printf '%s' "\$n" > "$tmp/torn-count"
		if [ "\$n" -eq 1 ]; then echo 'ay 1 9x'; else echo 'ay 1 150'; fi
		;;
	*) exit 1 ;;
esac
STUB
run_e2e "torn" "$fixture" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "torn gatt battery0 value null" '.batteries[0].value' "null"
assert_eq "torn gatt text has unknown central" "$(jq -r .text "$tmp/out.json" | grep -c 'C:?')" "1"
assert_json "torn gatt battery count" '.batteries | length' "2"

# Pin the address so the same board is picked both times regardless of
# its connected state.
stub_busctl_level93
run_e2e "reconnect" "$fixture" "$tmp/empty" "$tmp/empty" "E2:D9:27:00:00:AA" 1D50:615E 15 10
jq '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Connected.data = false' "$fixture" > "$tmp/disconnected.json"
run_e2e "reconnect" "$tmp/disconnected.json" "$tmp/empty" "$tmp/empty" "E2:D9:27:00:00:AA" 1D50:615E 15 10
assert_json "disconnected type" .type "none"
assert_json "disconnected connected" .connected "false"
assert_json "disconnected ble" .ble "false"
assert_eq "disconnected lastseen shape" "$(jq -r .lastseen "$tmp/out.json" | grep -Eq '^[0-9]+s ago$' && echo yes || echo no)" "yes"
assert_json "disconnected tooltip" .tooltip 'lim"inal · Not connected · last seen '"$(jq -r .lastseen "$tmp/out.json")"
assert_json "disconnected batteries empty" .batteries "[]"

# Reuses nodesc.json, which has no cached descriptor value, to force the
# live GATT read path.
write_busctl_stub <<'STUB'
case "$*" in
	*GattDescriptor1*ReadValue*) echo 'ay 12 80 101 114 105 112 104 101 114 97 108 32 48' ;;
	*GattCharacteristic1*ReadValue*) echo 'ay 1 93' ;;
	*) exit 1 ;;
esac
STUB
run_e2e "livedesc" "$tmp/nodesc.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "live descriptor read battery1 name" '.batteries[1].name' "Peripheral"
assert_eq "live descriptor read label file" "$(cat "$tmp/rt-livedesc/omarchy-zmk/E2_D9_27_00_00_AA/bat2.label")" "Peripheral 0"

# Infrastructure failure must not be reported as "no keyboard".
run_e2e "err" "$tmp/does-not-exist" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "error key on unreachable bluez" .error "BlueZ unreachable"
assert_json "error key found false" .found "false"
assert_json "error key tooltip" .tooltip "ZMK: BlueZ unreachable"
assert_json_valid "error key valid json"

# Pinning an address nothing matches is reported, not swallowed as a
# generic not-found.
run_e2e "pinned" "$fixture" "$tmp/empty" "$tmp/empty" "00:11:22:33:44:55" 1D50:615E 15 10
assert_json "pinned no match warning" .warning "no paired board at 00:11:22:33:44:55"
assert_json "pinned no match tooltip" .tooltip "no paired board at 00:11:22:33:44:55"

# Dependency checks: a missing jq, busctl, or timeout is reported instead
# of guessed at, since the rest of main can't build normal output without
# them. Each stub PATH holds only symlinks to real system tools, standing
# in for a host where one dependency was never installed.
dep_tools="bash awk grep tr mv find date cat head tail sort mkdir rm timeout sed cut wc id printf env"

mkdir -p "$tmp/bin-nojq"
for t in $dep_tools; do
	[ -x "/usr/bin/$t" ] && ln -s "/usr/bin/$t" "$tmp/bin-nojq/$t"
done
cat > "$tmp/bin-nojq/busctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$tmp/bin-nojq/busctl"
mkdir -p "$tmp/rt-nojq"
ZMK_STATUS_PATH="$tmp/bin-nojq" \
	XDG_RUNTIME_DIR="$tmp/rt-nojq" \
	INPUT_DEVICES_FILE="$tmp/empty-file" \
	BLUEZ_OBJECTS_FILE="$fixture" \
	USB_DEVICES_DIR="$tmp/empty" \
	HID_DEVICES_DIR="$tmp/empty" \
	bash "$here/../script/zmk-status" "" 1D50:615E 15 10 > "$tmp/out-nojq.json"
assert_eq "jq missing error" "$(/usr/bin/jq -r .error "$tmp/out-nojq.json")" "jq missing"
assert_eq "jq missing tooltip" "$(/usr/bin/jq -r .tooltip "$tmp/out-nojq.json")" "ZMK: jq missing"

mkdir -p "$tmp/bin-nobusctl"
for t in $dep_tools; do
	[ -x "/usr/bin/$t" ] && ln -s "/usr/bin/$t" "$tmp/bin-nobusctl/$t"
done
ln -s /usr/bin/jq "$tmp/bin-nobusctl/jq"
mkdir -p "$tmp/rt-nobusctl"
ZMK_STATUS_PATH="$tmp/bin-nobusctl" \
	XDG_RUNTIME_DIR="$tmp/rt-nobusctl" \
	INPUT_DEVICES_FILE="$tmp/empty-file" \
	BLUEZ_OBJECTS_FILE="$fixture" \
	USB_DEVICES_DIR="$tmp/empty" \
	HID_DEVICES_DIR="$tmp/empty" \
	bash "$here/../script/zmk-status" "" 1D50:615E 15 10 > "$tmp/out-nobusctl.json"
assert_eq "busctl missing error" "$(/usr/bin/jq -r .error "$tmp/out-nobusctl.json")" "busctl missing"
assert_eq "busctl missing found" "$(/usr/bin/jq -r .found "$tmp/out-nobusctl.json")" "false"

# Caps: BlueZ is untrusted input, so battery instances, the alias, and the
# whole document are all bounded before jq has to walk them.
manybatt_chars=$(/usr/bin/jq -n '[range(0;12) | { key: ("/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service9000/char" + (. | tostring)), value: { "org.bluez.GattCharacteristic1": { "UUID": {"type":"s","data":"00002a19-0000-1000-8000-00805f9b34fb"}, "Value": {"type":"ay","data":[50]} } } }] | from_entries')
/usr/bin/jq --argjson chars "$manybatt_chars" '
	(.data[0] | with_entries(select(.key | startswith("/org/bluez/hci0/dev_E2_D9_27_00_00_AA/service") | not))) as $base
	| .data[0] = ($base + $chars)' "$fixture" > "$tmp/manybatt.json"
stub_busctl_level93
run_e2e "manybatt" "$tmp/manybatt.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "battery cap holds at 8" '.batteries | length' "8"

long_alias=$(printf 'a%.0s' $(seq 1 200))
/usr/bin/jq --arg alias "$long_alias" '.data[0]["/org/bluez/hci0/dev_E2_D9_27_00_00_AA"]["org.bluez.Device1"].Alias.data = $alias' "$fixture" > "$tmp/longalias.json"
run_e2e "longalias" "$tmp/longalias.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "alias cap holds at 64" '.name | length' "64"

head -c 3000000 /dev/zero | tr '\0' 'x' > "$tmp/huge-objects.json"
run_e2e "hugeobjects" "$tmp/huge-objects.json" "$tmp/empty" "$tmp/empty" "" 1D50:615E 15 10
assert_json "load_objects cap on a huge fixture" .error "BlueZ reply unreadable"

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails failing"; exit 1; fi
