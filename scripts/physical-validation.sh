#!/usr/bin/env bash
# Guided physical validation of LogiDuo with a real Logitech mouse (person at the Mac).
#
# Evidence is collected with a listen-only event tap at the end of the session's event
# chain: it shows which mouse events actually reach applications (physical ones, and
# LogiDuo's own synthetic ones). Effects only a person can see (Mission Control opening)
# are recorded as answers. Nothing here changes privacy settings or device settings.
#
# Results: build/validation/results-<timestamp>.txt
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_SOURCE="build/DerivedData/Build/Products/Debug/LogiDuo.app"
APP="/Applications/LogiDuo.app"
RESULTS_DIR="build/validation"
mkdir -p "$RESULTS_DIR"
RESULTS="$RESULTS_DIR/results-$(date +%Y%m%d-%H%M%S).txt"

record() { echo "$*" | tee -a "$RESULTS"; }
pause() { read -r -p "$1 [Enter] " _; }
ask() {
    local answer
    read -r -p "$1 [y/n] " answer
    record "ANSWER $2: $answer"
}

# Runs the listen-only observer for $1 seconds and records the counts under label $2.
observe() {
    local seconds=$1 label=$2 output
    output=$(LOGIDUO_PHYSICAL=1 LOGIDUO_PHYSICAL_REPORT_ONLY=1 LOGIDUO_PHYSICAL_SECONDS="$seconds" \
        swift test --package-path Packages/LogiDuoKit --filter PhysicalObservation 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    local physical synthetic leftright
    physical=$(grep "other-button presses by number" <<<"$output" | sed 's/.*number: //')
    synthetic=$(grep "LogiDuo synthetic presses" <<<"$output" | sed 's/.*number: //')
    leftright=$(grep "left/right presses observed" <<<"$output" | sed 's/.*observed: //')
    record "OBSERVED $label: physical=$physical synthetic=$synthetic leftRight=$leftright"
}

# Count of presses of button number $2 in an "OBSERVED" line's dictionary text $1.
count() { grep -o "key: $2, value: [0-9]*" <<<"$1" | grep -o '[0-9]*$' || echo 0; }

record "LogiDuo physical validation $(date) at $(git rev-parse --short HEAD)"

if pgrep -x Mouser >/dev/null || pgrep -fi "mouser.app" >/dev/null || pgrep -fi "logioptionsplus" >/dev/null; then
    record "ABORT: quit Mouser and Logi Options+ first (they intercept the same buttons)."
    exit 1
fi

echo "Building once; the copy in /Applications must not be rebuilt during validation (ad-hoc"
echo "signatures change on every build, which invalidates permission grants)."
make build >/dev/null || { record "ABORT: build failed"; exit 1; }
if [[ -d "$APP" ]]; then pause "Replace $APP with this build?"; fi
osascript -e 'tell application "LogiDuo" to quit' >/dev/null 2>&1
rm -rf "$APP" && ditto "$APP_SOURCE" "$APP"
record "APP $(codesign -dv "$APP" 2>&1 | grep CDHash)"

echo
echo "== A. Permissions for $APP =="
echo "Open System Settings › Privacy & Security and enable LogiDuo under BOTH Accessibility and Input Monitoring."
open "$APP"
pause "When both are enabled, quit LogiDuo (menu bar › Quit), then press"
open "$APP"; sleep 6
record "PERMISSIONS $(/usr/bin/log show --last 30s --predicate 'subsystem == "io.github.bafsheh.LogiDuo" AND category == "Lifecycle"' --style compact 2>/dev/null | grep -o 'launch permissions:.*' | tail -1)"

echo
echo "== B. Native input (remapping OFF in the menu bar) =="
pause "Make sure Remapping is OFF. Within 20 s press middle 2×, back 2×, forward 2×, left 2×, right 2×. Ready?"
observe 20 "native"

echo
echo "== C. Validation presets (menu bar › Remapping ON, then choose the preset) =="
pause "Preset 'Observe Only', Remapping ON. Within 15 s press middle, back, forward, left, right once each. Ready?"
observe 15 "observeOnly"
pause "Preset 'Back to Mission Control'. Within 15 s press BACK twice (Mission Control should open/close). Ready?"
observe 15 "backToMissionControl"
ask "Did Mission Control open when you pressed Back?" "missionControlOpened"
pause "Preset 'Forward to Middle Click'. Open a link-rich page in Safari, then within 15 s press FORWARD on a link twice. Ready?"
observe 15 "forwardToMiddleClick"
ask "Did Forward open the link in a new tab (middle click)?" "middleClickOpenedTab"
ask "Did left and right clicks work normally throughout?" "leftRightNormal"

echo
echo "== D. Accessibility revocation while remapping is active =="
pause "Preset 'Back to Mission Control', Remapping ON. Now turn LogiDuo OFF in System Settings › Accessibility, then press"
pause "Within 15 s press BACK twice (it should navigate back natively, no Mission Control). Ready?"
observe 15 "revoked"
ask "Did the menu bar show that Accessibility is needed?" "revocationNotice"
pause "Turn LogiDuo back ON in Accessibility (do not relaunch LogiDuo), wait 5 s, then press"
pause "Within 15 s press BACK twice (Mission Control should open again). Ready?"
observe 15 "regranted"
ask "Did Mission Control open again without relaunching LogiDuo?" "recoveredWithoutRelaunch"

echo
echo "== Summary =="
summary() { grep "OBSERVED $1:" "$RESULTS" | sed 's/.*physical=//; s/ synthetic=.*//'; }
synthetic() { grep "OBSERVED $1:" "$RESULTS" | sed 's/.*synthetic=//; s/ leftRight=.*//'; }
native=$(summary native)
record "CHECK native buttons reach apps: middle=$(count "$native" 2) back=$(count "$native" 3) forward=$(count "$native" 4)"
record "CHECK Back suppressed under Mission Control preset: back reached apps $(count "$(summary backToMissionControl)" 3) times (expect 0)"
record "CHECK Forward replaced by middle click: forward=$(count "$(summary forwardToMiddleClick)" 4) (expect 0), synthetic middle=$(count "$(synthetic forwardToMiddleClick)" 2) (expect ≥1)"
record "CHECK revoked: back reached apps $(count "$(summary revoked)" 3) times (expect ≥1)"
record "CHECK re-granted: back reached apps $(count "$(summary regranted)" 3) times (expect 0)"
echo
echo "Results written to $RESULTS"
