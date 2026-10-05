SHELL = /bin/bash
APK = app/build/outputs/apk/debug/app-debug.apk
export SWIFT ADB JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_NDK_ROOT
export SWIFT_SDKS_PATH SWIFT_ANDROID_SDK_ROOT SWIFT_ANDROID_SDK GRADLE ANDROID_ABIS CONFIGURATION

.PHONY: all apk test install
all: apk

apk:
	bash scripts/build.sh

test:
	set -e; source scripts/environment.sh; \
		sh scripts/bootstrap.sh; \
		"$$SWIFT" test --package-path ../MaiCore --filter portable; \
		PMAI_NO_VISUAL=1 "$$SWIFT" test --build-system native --disable-sandbox

install: apk
	set -e; source scripts/environment.sh; "$${ADB:-adb}" install -r "$(APK)"
