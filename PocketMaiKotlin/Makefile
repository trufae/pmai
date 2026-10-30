SHELL = /bin/bash
VERSION = 0.1.0
CONFIGURATION ?= debug
APK = PocketMaiKotlin-$(VERSION)$(if $(filter debug,$(CONFIGURATION)),-debug).apk
export CONFIGURATION ANDROID_ABIS SWIFT JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT
export ANDROID_NDK_HOME ANDROID_NDK_ROOT SWIFT_SDKS_PATH SWIFT_ANDROID_SDK_ROOT SWIFT_ANDROID_SDK
export PMAI_ANDROID_KEYSTORE PMAI_ANDROID_KEY_ALIAS PMAI_ANDROID_STORE_PASSWORD PMAI_ANDROID_KEY_PASSWORD

.PHONY: all apk debug release install test clean
all: apk
apk:
	bash scripts/build.sh
debug:
	$(MAKE) apk CONFIGURATION=debug
release:
	$(MAKE) apk CONFIGURATION=release
install: apk
	set -e; source scripts/environment.sh; "$${ADB:-adb}" install -r "$(APK)"
test:
	set -e; source scripts/environment.sh; export PMAI_NO_MLX=1; \
		SWIFT="$$SWIFT" python3 ../test/run-tests.py mobile; \
		./gradlew :app:testDebugUnitTest
clean:
	set -e; source scripts/environment.sh; ./gradlew :app:clean :bridge:clean
