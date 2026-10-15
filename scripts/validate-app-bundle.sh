#!/usr/bin/env bash
# Validates a built LogiDuo.app: native Swift payload only, expected
# architectures, required metadata and bundled license notices.
#   usage: validate-app-bundle.sh <path/to/LogiDuo.app> [required-arch ...]
set -euo pipefail

app="${1:?usage: $0 <LogiDuo.app> [arch ...]}"
shift
required_archs=("${@:-arm64 x86_64}")
status=0
fail() { echo "error: $*" >&2; status=1; }

[[ -d "$app" ]] || { echo "error: $app does not exist" >&2; exit 1; }
binary="$app/Contents/MacOS/LogiDuo"
plist="$app/Contents/Info.plist"

[[ -x "$binary" ]] || fail "missing executable $binary"
for arch in ${required_archs[*]}; do
    lipo "$binary" -verify_arch "$arch" 2>/dev/null || fail "executable lacks architecture $arch"
done

for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1 || fail "Info.plist lacks $key"
done

[[ -f "$app/Contents/Resources/LICENSE" ]] || fail "LICENSE notice is not bundled"

# The shipped app must not embed another language runtime.
if find "$app" \( -iname '*python*' -o -iname '*.py' -o -iname '*.pyc' -o -iname 'Qt*' \
    -o -iname '*.qml' -o -iname '*electron*' -o -iname 'node' \) -print | grep -q .; then
    find "$app" \( -iname '*python*' -o -iname '*.py' -o -iname '*.pyc' -o -iname 'Qt*' \
        -o -iname '*.qml' -o -iname '*electron*' -o -iname 'node' \) -print >&2
    fail "bundle contains a non-Swift runtime payload"
fi

if find "$app" -iname '*.md' -print | grep -q .; then
    fail "bundle contains Markdown files"
fi

[[ $status -eq 0 ]] && echo "App bundle validation passed: $app"
exit $status
