PROJECT = PocketMai.xcodeproj
SCHEME = PocketMai
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
TEST_DESTINATION ?=
TEST_RESULT_BUNDLE ?= build/TestResults.xcresult
DERIVED_DATA ?= build/DerivedData
XCODE_PACKAGE_FLAGS ?= -skipPackagePluginValidation
SUDO ?= sudo
ifeq ($(shell uname),Darwin)
STRIP ?= strip -x
else
STRIP ?= strip -s
endif
DEVICE ?=
BUNDLE_ID = io.github.trufae.mai
APP_BUNDLE ?=
BINDIR ?= $(HOME)/.local/bin

.PHONY: all build test list run uninstall repl repl-install repl-uninstall repl-musl plugin-fixture fmt clean check-shared-tooling aitest-build

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) $(XCODE_PACKAGE_FLAGS) CODE_SIGNING_ALLOWED=NO build

test:
	TEST_DESTINATION='$(TEST_DESTINATION)' TEST_RESULT_BUNDLE='$(TEST_RESULT_BUNDLE)' \
		bash test/run-ios-tests.sh -project '$(PROJECT)' -scheme '$(SCHEME)' \
		-configuration '$(CONFIG)' -derivedDataPath '$(DERIVED_DATA)' \
		$(XCODE_PACKAGE_FLAGS) CODE_SIGNING_ALLOWED=NO

list:
	xcrun devicectl list devices

# Builds, installs, and foreground-launches the app on the first connected iOS
# device. Pass DEVICE=<UDID> to choose a device, or APP_BUNDLE=<path> to skip
# the build and install a specific prebuilt app bundle.
run:
	@set -e; \
	device='$(DEVICE)'; \
	app_bundle='$(APP_BUNDLE)'; \
	if [ -z "$$device" ]; then \
		devices_json="$$(mktemp -t pocketmai-devices.XXXXXX)"; \
		trap 'rm -f "$$devices_json"' EXIT; \
		xcrun devicectl list devices --json-output "$$devices_json" >/dev/null; \
		device="$$(jq -r '.result.devices[] | select(.hardwareProperties.platform == "iOS") | .identifier' "$$devices_json" | head -n 1)"; \
	fi; \
	if [ -z "$$device" ] || [ "$$device" = "null" ]; then \
		echo "No connected iOS device found. Pass DEVICE=<UDID> to select one." >&2; \
		exit 1; \
	fi; \
	if [ -z "$$app_bundle" ]; then \
		xcodebuild -project '$(PROJECT)' -scheme '$(SCHEME)' -configuration '$(CONFIG)' \
			-destination "platform=iOS,id=$$device" -derivedDataPath '$(DERIVED_DATA)' \
			$(XCODE_PACKAGE_FLAGS) -allowProvisioningUpdates build; \
		app_bundle='$(DERIVED_DATA)/Build/Products/$(CONFIG)-iphoneos/$(SCHEME).app'; \
	fi; \
	if [ -z "$$app_bundle" ] || [ ! -d "$$app_bundle" ]; then \
		echo "No signed $(CONFIG) device build found at $$app_bundle." >&2; \
		exit 1; \
	fi; \
	xcrun devicectl device install app --device "$$device" "$$app_bundle"; \
	xcrun devicectl device process launch --terminate-existing --device "$$device" "$(BUNDLE_ID)"

uninstall:
	@set -e; \
	device='$(DEVICE)'; \
	if [ -z "$$device" ]; then \
		devices_json="$$(mktemp -t pocketmai-devices.XXXXXX)"; \
		trap 'rm -f "$$devices_json"' EXIT; \
		xcrun devicectl list devices --json-output "$$devices_json" >/dev/null; \
		device="$$(jq -r '.result.devices[] | select(.hardwareProperties.platform == "iOS") | .identifier' "$$devices_json" | head -n 1)"; \
	fi; \
	if [ -z "$$device" ] || [ "$$device" = "null" ]; then \
		echo "No connected iOS device found. Pass DEVICE=<UDID> to select one." >&2; \
		exit 1; \
	fi; \
	xcrun devicectl device uninstall app --device "$$device" "$(BUNDLE_ID)"

repl:
	@set -a; \
	if [ -f ./env.sh ] \
		&& [ -z "$${PMAI_PROVIDER+x}$${MAI_PROVIDER+x}" ] \
		&& [ -z "$${PMAI_MODEL+x}$${MAI_MODEL+x}$${OPENAI_MODEL+x}" ] \
		&& [ -z "$${PMAI_BASE_URL+x}$${MAI_BASE_URL+x}$${OPENAI_BASE_URL+x}" ] \
		&& [ -z "$${PMAI_API_KEY+x}$${MAI_API_KEY+x}$${OPENAI_API_KEY+x}" ]; then \
		. ./env.sh; \
	fi; \
	swift run --package-path MaiCore pmai $(ARGS)

repl-install:
	swift build --package-path MaiCore -c release --product pmai
	mkdir -p $(BINDIR)
	cp -f "$$(swift build --package-path MaiCore -c release --show-bin-path)/pmai" $(BINDIR)/pmai
	chmod 755 $(BINDIR)/pmai
	$(STRIP) $(BINDIR)/pmai

repl-uninstall:
	rm -f "$(BINDIR)/pmai"

# Fully static Linux build that also runs on musl distributions such as
# Alpine. Needs the Swift Static Linux SDK matching the toolchain. swift-tui
# does not build against musl, so the /visual workspace is left out.
MUSL_ARCH ?= $(shell uname -m)
repl-musl:
	PMAI_NO_VISUAL=1 swift build --package-path MaiCore -c release --product pmai \
		--swift-sdk $(MUSL_ARCH)-swift-linux-musl -Xswiftc -Osize

plugin-fixture:
	swift build --package-path MaiCore --product MaiFixturePlugin

fmt:
	xcrun swift-format format -i -r PocketMai PocketMaiShare Shared SharedWidgetKit MaiCore/Sources MaiCore/Tests MaiCore/Package.swift

check-shared-tooling:
	test "$$(readlink aitest/Sources/aitest/AgentTooling.swift)" = "../../../Shared/AgentTooling.swift"

aitest-build: check-shared-tooling
	swift build --package-path aitest

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED_DATA) clean
