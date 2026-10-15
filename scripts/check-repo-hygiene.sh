#!/usr/bin/env bash
# Verifies the tracked-file policy for the public repository:
#   * README.md at the root is the only tracked Markdown file.
#   * Only allow-listed dot-files/dot-directories are tracked, so local tool
#     working directories can never be published by accident.
#   * No signing material, secrets or build output is tracked.
#   * No absolute home-directory paths leak into tracked text files.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0

fail() {
    echo "error: $*" >&2
    status=1
}

tracked_files() {
    # Include staged additions so the check also works as a pre-commit hook.
    { git ls-files; git diff --cached --name-only --diff-filter=ACR; } | sort -u
}

is_allowed_dot_path() {
    case "$1" in
        .gitignore | .gitattributes | .swiftlint.yml | .swift-format | .github/*) return 0 ;;
        */.swiftpm/xcode/package.xcworkspace/*) return 0 ;;
        *) return 1 ;;
    esac
}

while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
        README.md) ;;
        *.md | *.MD | *.markdown) fail "Markdown file is not allowed: $path" ;;
    esac
    if [[ "$path" == .* || "$path" == */.* ]] && ! is_allowed_dot_path "$path"; then
        fail "dot-path is not allow-listed: $path"
    fi
    case "$path" in
        *.p12 | *.cer | *.p8 | *.pem | *.key | *.mobileprovision | *.provisionprofile | .env | .env.*)
            fail "signing material or secrets must not be tracked: $path" ;;
        .build/* | */.build/* | DerivedData/* | build/* | *.xcresult/* | */xcuserdata/*)
            fail "build output must not be tracked: $path" ;;
    esac
done < <(tracked_files)

# Absolute user paths reveal local machine details.
home_path_pattern='/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/'
if git grep -n -I -E "$home_path_pattern" -- ':!scripts/check-repo-hygiene.sh' >&2; then
    fail "tracked files contain absolute home-directory paths"
fi

if [[ $status -eq 0 ]]; then
    echo "Repository hygiene check passed."
fi
exit $status
