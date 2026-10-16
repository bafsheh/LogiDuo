#!/usr/bin/env bash
# Guided physical validation of LogiDuo with a real Logitech mouse (person at the Mac).
#
# Evidence comes from two listen-only event taps (they can never change or suppress input):
#   pressed   — at the HID level, before LogiDuo's tap: what the person actually pressed;
#   delivered — after every session tap: what reached applications.
# A press counts as physical only without any marker and without a posting process, so
# injected or synthetic events can never pass as physical. Every automated (AUTO) check
# needs a positive control: if the button was not seen pressed, the check is INVALID, not
# PASS. Effects only a person can see are recorded as HUMAN answers.
#
# What this script changes: it builds into build/, and (after you agree) installs the
# build as /Applications/LogiDuo.app, moving any earlier LogiDuo copy into the session
# folder. It never touches privacy permissions (you grant and revoke them yourself in
# System Settings), device settings, or other applications.
#
# Results: build/validation/<timestamp>/ (results.txt, raw step logs, LogiDuo's log).
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUNDLE_ID="io.github.bafsheh.LogiDuo"
APP_SOURCE="build/DerivedData/Build/Products/Debug/LogiDuo.app"
APP="/Applications/LogiDuo.app"
SESSION="build/validation/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION"
RESULTS="$SESSION/results.txt"
STARTED=$(date "+%Y-%m-%d %H:%M:%S")
FAILURES=0

record() { echo "$*" | tee -a "$RESULTS"; }
pause() { read -r -p "$1 [Enter] " _; }
yes_no() {
    local answer=""
    while [[ $answer != y && $answer != n ]]; do read -r -p "$1 [y/n] " answer; done
    [[ $answer == y ]]
}
human() {
    if yes_no "$1"; then record "HUMAN PASS $2"; else record "HUMAN FAIL $2"; FAILURES=$((FAILURES + 1)); fi
}

save_app_log() {
    /usr/bin/log show --start "$STARTED" --predicate "subsystem == \"$BUNDLE_ID\"" --style compact \
        >"$SESSION/logiduo.log" 2>&1
}
finish() {
    save_app_log
    record "END $(date) failures=$FAILURES; raw logs in $SESSION"
}
trap finish EXIT

# Runs the observer for $1 seconds as step $2; the raw output is kept in $SESSION/$2.log.
observe() {
    local seconds=$1 step=$2
    LOGIDUO_PHYSICAL=1 LOGIDUO_PHYSICAL_REPORT_ONLY=1 LOGIDUO_PHYSICAL_SECONDS="$seconds" \
        swift test --skip-build --package-path Packages/LogiDuoKit --filter PhysicalObservation 2>&1 \
        | sed -l 's/\x1b\[[0-9;]*m//g' | tee "$SESSION/$step.log" | grep --line-buffered "\[physical\] GO"
    if ! grep -q "\[physical\] observation complete" "$SESSION/$step.log"; then
        record "AUTO INVALID $step: the observer did not run (see $step.log; does the terminal have Input Monitoring?)"
        FAILURES=$((FAILURES + 1))
    fi
}

# Presses seen in step $1 at stage $2 (pressed|delivered) from origin $3 for button $4.
n() {
    awk -v s="stage=$2" -v o="origin=$3" -v b="button=$4" \
        '$2 == s && $3 == o && $4 == b { split($5, c, "="); total += c[2] } END { print total + 0 }' \
        "$SESSION/$1.log" 2>/dev/null
}

name() { case $1 in 0) echo left ;; 1) echo right ;; 2) echo middle ;; 3) echo back ;; 4) echo forward ;; esac; }

# AUTO: button $2 in step $1 reached applications natively (every physical press delivered).
expect_native() {
    local pressed delivered
    pressed=$(n "$1" pressed physical "$2")
    delivered=$(n "$1" delivered physical "$2")
    if ((pressed == 0)); then
        record "AUTO INVALID $1 $(name "$2"): not seen pressed (pressed=0)"; FAILURES=$((FAILURES + 1))
    elif ((delivered == pressed)); then
        record "AUTO PASS $1 $(name "$2") native: pressed=$pressed delivered=$delivered"
    else
        record "AUTO FAIL $1 $(name "$2") native: pressed=$pressed delivered=$delivered"; FAILURES=$((FAILURES + 1))
    fi
}

# AUTO: button $2 in step $1 was pressed but never reached applications.
expect_suppressed() {
    local pressed delivered
    pressed=$(n "$1" pressed physical "$2")
    delivered=$(n "$1" delivered physical "$2")
    if ((pressed == 0)); then
        record "AUTO INVALID $1 $(name "$2"): not seen pressed (pressed=0)"; FAILURES=$((FAILURES + 1))
    elif ((delivered == 0)); then
        record "AUTO PASS $1 $(name "$2") suppressed: pressed=$pressed delivered=0"
    else
        record "AUTO FAIL $1 $(name "$2") suppressed: pressed=$pressed delivered=$delivered"; FAILURES=$((FAILURES + 1))
    fi
}

record "LogiDuo physical validation $(date) at $(git rev-parse --short HEAD) (worktree $(git status --porcelain | wc -l | tr -d ' ') changes)"

if pgrep -x Mouser >/dev/null || pgrep -fi "Mouser.app/" >/dev/null || pgrep -fi "logioptionsplus" >/dev/null; then
    record "ABORT: quit Mouser and Logi Options+ first (they intercept the same buttons)."
    exit 1
fi
if launchctl list 2>/dev/null | grep -q "io.github.tombadash.mouser"; then
    record "NOTE: Mouser's LaunchAgent is loaded; keep Mouser quit for the whole session."
fi

echo "Building once. The copy in /Applications must not be rebuilt during validation: ad-hoc"
echo "signatures change on every build, which invalidates permission grants."
make build >"$SESSION/build.log" 2>&1 || { record "ABORT: app build failed (see build.log)"; exit 1; }
swift build --build-tests --package-path Packages/LogiDuoKit >>"$SESSION/build.log" 2>&1 \
    || { record "ABORT: test build failed (see build.log)"; exit 1; }

if [[ -e "$APP" ]]; then
    existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
    if [[ $existing != "$BUNDLE_ID" ]]; then
        record "ABORT: $APP is not LogiDuo (bundle '${existing:-unknown}'); it was left untouched."
        exit 1
    fi
    yes_no "Replace $APP with this build? (the current copy is moved to $SESSION)" \
        || { record "ABORT: operator kept the installed copy"; exit 1; }
fi
osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" \
    >/dev/null 2>&1
sleep 2
if [[ -e "$APP" ]]; then mv "$APP" "$SESSION/previous-LogiDuo.app" || { record "ABORT: could not move $APP"; exit 1; }; fi
ditto "$APP_SOURCE" "$APP" || { record "ABORT: install failed"; exit 1; }
record "APP $(codesign -dv "$APP" 2>&1 | grep CDHash)"

echo
echo "== A. Permissions for $APP (you change them; this script only reads LogiDuo's log) =="
echo "System Settings › Privacy & Security: enable LogiDuo under BOTH Accessibility and Input Monitoring."
echo "If an older LogiDuo entry is listed, remove it with − and add $APP with +."
open "$APP"
pause "When both are enabled, quit LogiDuo (menu bar › Quit), then press"
open "$APP"
sleep 6
permissions=$(/usr/bin/log show --last 30s --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"Lifecycle\"" \
    --style compact 2>/dev/null | grep -o 'launch permissions:.*' | tail -1)
if [[ $permissions == *"accessibility=granted inputMonitoring=granted"* ]]; then
    record "AUTO PASS permissions: $permissions"
else
    record "AUTO FAIL permissions: ${permissions:-no launch log line}"
    FAILURES=$((FAILURES + 1))
    exit 1
fi

echo
echo "== B. Native input (menu bar › Remapping OFF) =="
pause "Remapping OFF. After GO, press middle, back, forward, left and right twice each (20 s). Ready?"
observe 20 native
for button in 0 1 2 3 4; do expect_native native "$button"; done

echo
echo "== C. Validation presets (menu bar › Remapping ON, then the preset) =="
pause "Preset 'Observe Only', Remapping ON. After GO, press middle, back, forward, left, right once each (15 s). Ready?"
observe 15 observeOnly
for button in 0 1 2 3 4; do expect_native observeOnly "$button"; done

pause "Preset 'Back to Mission Control'. After GO, press BACK twice and left-click once (15 s). Ready?"
observe 15 backToMissionControl
expect_suppressed backToMissionControl 3
expect_native backToMissionControl 0
human "Did Mission Control open when you pressed Back?" "backToMissionControl opened Mission Control"

pause "Preset 'Forward to Middle Click'. Point at a link in Safari; after GO press FORWARD twice (15 s). Ready?"
observe 15 forwardToMiddleClick
expect_suppressed forwardToMiddleClick 4
forward=$(n forwardToMiddleClick pressed physical 4)
middle=$(n forwardToMiddleClick delivered logiDuo 2)
if ((forward > 0 && middle == forward)); then
    record "AUTO PASS forwardToMiddleClick: $forward forward presses → $middle LogiDuo middle clicks delivered"
else
    record "AUTO FAIL forwardToMiddleClick: $forward forward presses → $middle LogiDuo middle clicks delivered"
    FAILURES=$((FAILURES + 1))
fi
human "Did Forward open the link in a new tab (middle click)?" "forwardToMiddleClick opened a tab"
human "Did left and right clicks behave normally throughout C?" "presets left/right normal"

echo
echo "== D. Accessibility revocation while remapping is active =="
pause "Preset 'Back to Mission Control', Remapping ON. Turn LogiDuo OFF in Accessibility, wait 5 s, then press"
pause "After GO, press BACK twice (15 s). Ready?"
observe 15 revoked
expect_native revoked 3
human "Did Back behave natively (no Mission Control)?" "revoked back native"
human "Does LogiDuo's menu show that Accessibility is needed?" "revoked notice shown"
pause "Turn LogiDuo back ON in Accessibility (do not relaunch it), wait 5 s, then press"
pause "After GO, press BACK twice (15 s). Ready?"
observe 15 regranted
expect_suppressed regranted 3
human "Did Mission Control open again without relaunching LogiDuo?" "regranted recovered without relaunch"

echo
if ((FAILURES == 0)); then record "RESULT: all checks passed"; else record "RESULT: $FAILURES check(s) failed or invalid"; fi
((FAILURES == 0))
