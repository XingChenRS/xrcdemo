TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 热加载内层插件。与主 dylib 分开编译：改插件只重跑这一半，
# 设备侧完全不用动（外层联网拉取，见 XRCHotLoad.m）。
LIBRARY_NAME = xrcplugin

xrcplugin_FILES = PluginMain.m
xrcplugin_CFLAGS += -fobjc-arc -I..
xrcplugin_LDFLAGS = -Xlinker -not_for_dyld_shared_cache

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk
