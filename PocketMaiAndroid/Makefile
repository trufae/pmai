SHELL = /bin/bash
CONFIGURATION ?= debug
ifeq ($(CONFIGURATION),release)
APK = app/build/outputs/apk/release/app-release$(if $(PMAI_ANDROID_KEYSTORE),,-unsigned).apk
else
APK = app/build/outputs/apk/debug/app-debug.apk
endif
export SWIFT ADB JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_NDK_ROOT
export SWIFT_SDKS_PATH SWIFT_ANDROID_SDK_ROOT SWIFT_ANDROID_SDK GRADLE ANDROID_ABIS CONFIGURATION
export PMAI_ANDROID_KEYSTORE PMAI_ANDROID_KEY_ALIAS PMAI_ANDROID_STORE_PASSWORD PMAI_ANDROID_KEY_PASSWORD

.PHONY: all apk release test install clean
all: apk

apk:
	bash scripts/build.sh

release:
	$(MAKE) apk CONFIGURATION=release

test:
	set -e; source scripts/environment.sh; \
		sh scripts/bootstrap.sh; \
		SWIFT="$$SWIFT" python3 ../test/run-tests.py chat; \
		PMAI_NO_VISUAL=1 "$$SWIFT" test --build-system native --disable-sandbox --disable-index-store

clean:
	set -e; source scripts/environment.sh; \
		"$${GRADLE:-.deps/AndroidSwiftUI/gradlew}" -p . :app:clean

install: apk
	@if [[ "$(APK)" == *-unsigned.apk ]]; then \
		echo "Cannot install an unsigned release APK; configure signing as described in README.md." >&2; exit 1; \
	fi
	set -e; source scripts/environment.sh; "$${ADB:-adb}" install -r "$(APK)"
