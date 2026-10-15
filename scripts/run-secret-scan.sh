#!/usr/bin/env bash
# Scans the full Git history for secrets with a pinned, checksum-verified
# gitleaks release.
set -euo pipefail

GITLEAKS_VERSION="8.30.1"
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        asset="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
        sha256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
    Darwin-arm64)
        asset="gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz"
        sha256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
    *)
        echo "error: unsupported platform $(uname -s)-$(uname -m)" >&2
        exit 1 ;;
esac

root="$(git rev-parse --show-toplevel)"
dir="$root/build/tools/gitleaks-${GITLEAKS_VERSION}"
if [[ ! -x "$dir/gitleaks" ]]; then
    mkdir -p "$dir"
    curl --fail --silent --show-error --location --retry 3 --output "$dir/$asset" \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${asset}"
    echo "$sha256  $dir/$asset" | shasum -a 256 --check --quiet
    tar -xzf "$dir/$asset" -C "$dir" gitleaks
fi

"$dir/gitleaks" git --no-banner --redact --exit-code 1 "$root"
