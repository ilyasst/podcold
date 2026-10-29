ARCHS = armv7
TARGET = iphone:clang:15.6:6.0
DEBUG = 0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# Link against the same legacy runtime shipped in the working upstream IPA.
_THEOS_TARGET_SWIFT_LDPATHS = /workspace/.build-linux/runtime /workspace/.build-linux/toolchain/linux/iphone/lib/swift-5.0/iphoneos /workspace/.build-linux/toolchain/linux/iphone/lib/swift/iphoneos

APPLICATION_NAME = podcold
podcold_FILES = $(wildcard Sources/*.swift Sources/Models/*.swift Sources/Networking/*.swift Sources/Playback/*.swift Sources/Views/*.swift Sources/ViewControllers/*.swift Sources/Networking/*.c Sources/Networking/*.S)
podcold_FRAMEWORKS = UIKit Foundation AVFoundation MediaPlayer Security SystemConfiguration CFNetwork AudioToolbox CoreGraphics QuartzCore ImageIO
podcold_CFLAGS = -I/workspace/podcold/ThirdParty/curl/include -fmodules-cache-path=/workspace/.build-linux/clang-module-cache
podcold_SWIFTFLAGS = -enable-objc-interop -I/workspace/podcold/ThirdParty/curl/include -resource-dir /workspace/.build-linux/toolchain/linux/iphone/lib/swift -module-cache-path /workspace/.build-linux/module-cache
ifeq ($(PODCOLD_DEVICE_TESTING),1)
podcold_SWIFTFLAGS += -D PODCOLD_DEVICE_TESTING
endif
podcold_SWIFT_BRIDGING_HEADER = Sources/podcold-Bridging-Header.h
podcold_LDFLAGS = -resource-dir /workspace/.build-linux/toolchain/linux/iphone/lib/clang/13.0.0 -L/workspace/.build-linux/sdks/iPhoneOS15.6.sdk/usr/lib/swift -L/workspace/podcold/ThirdParty/curl/lib -lcurl -lssl -lcrypto -lz -lc++ -rpath @executable_path/Frameworks -weak-lswiftCoreMIDI -weak-lswiftDataDetection -weak-lswiftFileProvider -weak-lswiftUniformTypeIdentifiers -weak-lswift_Concurrency
podcold_RESOURCE_DIRS = Resources

# Swift's class registration needs Apple's back-deployment shims on iOS 7.
# Swift's Linux link driver does not add libarclite automatically like Xcode.
podcold_LDFLAGS += -Wl,-force_load,/workspace/.build-linux/toolchain/linux/iphone/lib/arc/libarclite_iphoneos.a

include $(THEOS_MAKE_PATH)/application.mk
