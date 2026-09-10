TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# Active build: sideload dylib only. Prior privileged-install and main-binary
# surgery experiments are not part of the maintained build path.
LIBRARY_NAME = ArcDemo

ArcDemo_FILES = Tweak.x
ArcDemo_FILES += XRCClock.m
ArcDemo_FILES += XRCPlayer.m
ArcDemo_FILES += XRCGameplay.m
ArcDemo_FILES += XRCJudge.m
ArcDemo_FILES += XRCConfig.m
ArcDemo_FILES += XRCFloatButton.m
ArcDemo_FILES += XRCPracticePanel.m
ArcDemo_FILES += XRCRuntime.m
ArcDemo_FILES += XRCProbe.m
ArcDemo_FILES += fishhook.c
ArcDemo_FILES += $(wildcard WHToast/WHToast/*.m)

ArcDemo_CFLAGS  += -fobjc-arc
ArcDemo_CFLAGS += -I./WHToast -I./include

ArcDemo_LIBRARIES = substrate
ArcDemo_LOGOSFLAGS = -c generator=MobileSubstrate
ArcDemo_LDFLAGS = -Xlinker -not_for_dyld_shared_cache

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function
ADDITIONAL_CFLAGS += -Wno-error=deprecated-declarations
ADDITIONAL_CFLAGS += -include Prefix.pch

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

.PHONY: sideload package-sideload

sideload:
	$(MAKE)

package-sideload:
	$(MAKE) package
