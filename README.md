# LogiDuo

**A native macOS app for configuring Logitech mice — and, later, keyboards.**

LogiDuo is an independent, open-source macOS application written entirely in Swift. It aims to
bring the macOS functionality of [Mouser](https://github.com/TomBadash/Mouser) — button remapping,
gestures, per-app profiles, DPI and scroll settings — to a fully native app with no Python, Qt or
other bundled runtime.

> [!IMPORTANT]
> LogiDuo is in early development. The application shell, architecture and quality gates are in
> place; device features are being ported one at a time. Nothing below marked *planned* works yet.

<!-- Screenshot placeholder: replaced once the device UI lands. -->

## Feature status

| Area | Status |
| --- | --- |
| Native macOS app shell (main window, menu bar extra, Settings) | Available |
| Device discovery over Bluetooth, Logi Bolt and Unifying receivers | Planned |
| Button remapping, keyboard shortcuts, media and macOS system actions | Planned |
| Gesture button with directional gestures | Planned |
| Per-application profiles | Planned |
| DPI presets, SmartShift, ratchet/free-spin, scroll inversion | Planned |
| Start at login | Planned |
| Import of existing Mouser settings | Planned |
| Logitech keyboard support | Researching |

Features are only exposed for devices that actually report the corresponding capability.

## Hardware support

No device has been validated with LogiDuo yet. The initial target list follows the devices Mouser
supports (for example the MX Master and MX Anywhere families). This section will list each device
only after it has been tested on physical hardware.

## Requirements

- macOS 14 Sonoma or later, Apple silicon or Intel
- To build: Xcode 27 or later, [Homebrew](https://brew.sh) for developer tools

## Installation

Pre-built releases are not available yet. Build from source as described below.

## Building from source

```sh
git clone https://github.com/bafsheh/LogiDuo.git
cd LogiDuo
make bootstrap        # installs SwiftLint and XcodeGen, generates LogiDuo.xcodeproj
open LogiDuo.xcodeproj
```

Or build from the command line with `make build`. Run `make help` to list every target.

`LogiDuo.xcodeproj` is generated from `project.yml`. After adding, moving or removing files, run
`make project` and commit the regenerated project; CI rejects a stale project.

## Development

| Command | What it does |
| --- | --- |
| `make check` | Fast local gate: hygiene, architecture, formatting, lint, package tests |
| `make package-test` | Swift Testing suites for domain, protocol, infrastructure and features |
| `make app-test` | App-level unit tests through Xcode |
| `make ui-test` | UI tests (needs a logged-in desktop session) |
| `make lint` / `make format` | SwiftLint (strict) / apply swift-format |

Pull requests must pass the same checks in CI. Every warning is treated as an error.

## Permissions

LogiDuo will ask only for the permissions a feature needs, and will show what each one is for and
what still works without it.

| Permission | Needed for | Status |
| --- | --- | --- |
| Accessibility | Intercepting mouse buttons and sending shortcuts | Required once remapping lands |

You will be able to grant it in **System Settings → Privacy & Security → Accessibility**. LogiDuo is
not sandboxed because event taps and HID++ device control are not available to sandboxed apps; it
uses the hardened runtime without exceptions.

## Configuration

Settings will be stored locally in `~/Library/Application Support/LogiDuo/`. Nothing leaves your Mac.

## Architecture

LogiDuo follows MVVM with a router (MVVM-R) on top of Clean Architecture:

```text
App/                      Composition root, scenes and app lifecycle
Packages/LogiDuoKit/
  Sources/
    LogiDuoDomain/        Entities, value objects, use cases and ports (Foundation only)
    LogiDuoFeatures/      SwiftUI views, view models and the AppRouter (depends on Domain only)
  Tests/                  Swift Testing suites and shared test doubles
AppTests/, UITests/       App-level unit tests and XCUITest smoke tests
```

Infrastructure modules (HID++ transport, system input, persistence) will be added as separate
targets that depend only on the domain. The composition root in `App/` is the only place they meet
the presentation layer. `scripts/check-architecture.sh` enforces which frameworks each module may
import. The code is compiled in Swift 6 language mode with complete strict-concurrency checking.

## Privacy and security

- No telemetry, analytics, accounts or network services.
- Device serial numbers are never written to logs.
- No privileged helpers or kernel extensions.

## Troubleshooting

- **Build fails with an Xcode version error.** Select Xcode 27 or later with
  `sudo xcode-select -s /Applications/Xcode.app`.

## Contributing

Contributions are welcome. Please keep changes small and focused, add tests for new behaviour, and
run `make check` before opening a pull request. Do not add Markdown files other than this README;
CI enforces it.

## Acknowledgements and license

LogiDuo is a native reimplementation inspired by and partly adapted from
[Mouser](https://github.com/TomBadash/Mouser) by Tom Badash and contributors, used under the MIT
License. Mouser's copyright notice is preserved in [LICENSE](LICENSE).

LogiDuo is released under the MIT License. See [LICENSE](LICENSE).

LogiDuo is not affiliated with, endorsed by, or sponsored by Logitech. Logitech, Logi, MX Master,
Logi Bolt and other product names are trademarks of their respective owners and are used only to
describe hardware compatibility.
