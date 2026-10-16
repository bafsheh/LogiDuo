#!/usr/bin/env bash
# Enforces Clean Architecture boundaries by restricting which modules each
# package target may import. SwiftPM target dependencies already prevent
# first-party cycles; this check additionally keeps platform frameworks
# (AppKit, IOKit, SwiftUI, …) out of the layers that must stay independent.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/Packages/LogiDuoKit"
status=0

allowed_imports() {
    case "$1" in
        LogiDuoDomain) echo "Foundation" ;;
        LogiDuoHIDPP) echo "Foundation os Synchronization LogiDuoDomain" ;;
        LogiDuoHID) echo "Foundation IOKit os Synchronization LogiDuoDomain LogiDuoHIDPP" ;;
        LogiDuoSystem) echo "Foundation AppKit ApplicationServices Carbon CoreGraphics IOKit os ServiceManagement Synchronization LogiDuoDomain" ;;
        LogiDuoPersistence) echo "Foundation os Synchronization LogiDuoDomain" ;;
        LogiDuoFeatures) echo "Foundation Observation SwiftUI os LogiDuoDomain" ;;
        LogiDuoTestSupport) echo "Foundation Synchronization LogiDuoDomain" ;;
        *) echo "__unknown__" ;;
    esac
}

for target_dir in Sources/* Tests/LogiDuoTestSupport; do
    [[ -d "$target_dir" ]] || continue
    target="$(basename "$target_dir")"
    allowed="$(allowed_imports "$target")"
    if [[ "$allowed" == "__unknown__" ]]; then
        echo "error: no import policy defined for target $target" >&2
        status=1
        continue
    fi
    while IFS=: read -r file line text; do
        module="$(sed -E 's/^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+(class |struct |enum |protocol |func |var |let |typealias )?([A-Za-z0-9_]+).*/\5/' <<<"$text")"
        if [[ " $allowed " != *" $module "* ]]; then
            echo "error: $file:$line: $target must not import $module" >&2
            status=1
        fi
    done < <(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]' "$target_dir" --include='*.swift' || true)
done

if [[ $status -eq 0 ]]; then
    echo "Architecture import policy check passed."
fi
exit $status
