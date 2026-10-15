# Developer entry points. Every target is also what CI runs.
# Select the Xcode to use with `sudo xcode-select -s` or by exporting DEVELOPER_DIR.

PACKAGE_DIR   := Packages/LogiDuoKit
PROJECT       := LogiDuo.xcodeproj
SCHEME        := LogiDuo
DERIVED_DATA  := build/DerivedData
SWIFT_FORMAT  := xcrun swift-format
SOURCES       := App UITests $(PACKAGE_DIR)/Sources $(PACKAGE_DIR)/Tests $(PACKAGE_DIR)/Package.swift

.PHONY: help bootstrap secrets project build build-for-testing test package-test app-test ui-test lint analyze format format-check hygiene architecture check clean

help: ## List available targets.
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-14s %s\n", $$1, $$2}'

bootstrap: ## Install developer tools (Homebrew) and generate the Xcode project.
	brew bundle --file=Brewfile
	$(MAKE) project

secrets: ## Scan the full Git history for secrets (pinned gitleaks).
	./scripts/run-secret-scan.sh

project: ## Regenerate LogiDuo.xcodeproj from project.yml.
	xcodegen generate --quiet

build: ## Build the macOS app (Debug).
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' -quiet build

build-for-testing: ## Compile the app and every test target, including UI tests.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) \
		-destination 'platform=macOS' -quiet build-for-testing

package-test: ## Run Swift package tests (domain, protocol, infrastructure, features).
	swift test --package-path $(PACKAGE_DIR) -Xswiftc -warnings-as-errors

app-test: ## Run app-level unit tests through Xcode.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) \
		-destination 'platform=macOS' -only-testing:LogiDuoAppTests test

ui-test: ## Run UI tests (requires a logged-in GUI session).
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) \
		-destination 'platform=macOS' -only-testing:LogiDuoUITests test

test: package-test app-test ## Run package and app unit tests.

lint: ## Run SwiftLint in strict mode.
	swiftlint lint --strict --quiet

format: ## Format all Swift sources in place.
	$(SWIFT_FORMAT) format --in-place --recursive --parallel $(SOURCES)

format-check: ## Fail if any Swift source is not formatted.
	$(SWIFT_FORMAT) lint --strict --recursive --parallel $(SOURCES)

hygiene: ## Enforce the public repository file policy.
	./scripts/check-repo-hygiene.sh

architecture: ## Enforce module import boundaries.
	./scripts/check-architecture.sh

check: hygiene architecture secrets format-check lint package-test ## Fast local gate (no Xcode project build).

clean: ## Remove build output.
	rm -rf build $(PACKAGE_DIR)/.build
