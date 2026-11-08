ARCHS = arm64 arm64e
TARGET = iphone:clang::16.0

INSTALL_TARGET_PROCESSES = SpringBoard BatteryService

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BatteryHealthFix

BatteryHealthFix_FILES = Tweak.xm
BatteryHealthFix_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BatteryHealthFix_LDFLAGS = -lobjc -framework IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
