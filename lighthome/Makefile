TARGET := iphone:clang:10.3:8.2
ARCHS = armv7
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LightHome
LightHome_FILES = Tweak.x
LightHome_CFLAGS = -fobjc-arc
# The 10.3 SDK stubs omit this armv7-only symbol; iOS 9 libobjc has it at runtime.
LightHome_LDFLAGS = -Wl,-U,_objc_msgSend_stret

include $(THEOS_MAKE_PATH)/tweak.mk
