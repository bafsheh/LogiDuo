#!/usr/bin/env bash
# Installs exact, checksum-verified versions of the lint and project
# generation tools into build/tools/bin so CI results are reproducible.
set -euo pipefail

SWIFTLINT_VERSION="0.65.1"
SWIFTLINT_SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

root="$(git rev-parse --show-toplevel)"
tools="$root/build/tools"
mkdir -p "$tools/bin" "$tools/downloads"

fetch() {
    local url="$1" sha="$2" dest="$3"
    curl --fail --silent --show-error --location --retry 3 --output "$dest" "$url"
    echo "$sha  $dest" | shasum -a 256 --check --quiet
}

fetch "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" \
    "$SWIFTLINT_SHA256" "$tools/downloads/swiftlint.zip"
unzip -o -q "$tools/downloads/swiftlint.zip" swiftlint -d "$tools/bin"

fetch "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" \
    "$XCODEGEN_SHA256" "$tools/downloads/xcodegen.zip"
unzip -o -q "$tools/downloads/xcodegen.zip" -d "$tools"
ln -sf "$tools/xcodegen/bin/xcodegen" "$tools/bin/xcodegen"

echo "$tools/bin"
