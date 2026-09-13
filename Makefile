TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# xrcdemo：侧载 dylib（含改判桩注入器）。主程序手术仅限 inject.py --stub。
LIBRARY_NAME = xrcdemo

xrcdemo_FILES = Tweak.x
xrcdemo_FILES += XRCClock.m
xrcdemo_FILES += XRCPlayer.m
xrcdemo_FILES += XRCGameplay.m
xrcdemo_FILES += XRCJudge.m
xrcdemo_FILES += XRCConfig.m
xrcdemo_FILES += XRCFloatButton.m
xrcdemo_FILES += XRCPracticePanel.m
xrcdemo_FILES += XRCRuntime.m
xrcdemo_FILES += XRCProbe.m
xrcdemo_FILES += XRCHook.m
xrcdemo_FILES += XRCDump.m
xrcdemo_FILES += XRCNet.m
xrcdemo_FILES += XRCOMLog.m
xrcdemo_FILES += XRCHotLoad.m
xrcdemo_FILES += fishhook.c
xrcdemo_FILES += $(wildcard WHToast/WHToast/*.m)

xrcdemo_CFLAGS  += -fobjc-arc
xrcdemo_CFLAGS += -I./WHToast -I./include

xrcdemo_LIBRARIES = substrate
xrcdemo_LOGOSFLAGS = -c generator=MobileSubstrate
xrcdemo_LDFLAGS = -Xlinker -not_for_dyld_shared_cache

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function
ADDITIONAL_CFLAGS += -Wno-error=deprecated-declarations

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

.PHONY: sideload package-sideload

sideload:
	$(MAKE)

package-sideload:
	$(MAKE) package
