// xrc-arcdemo / Tweak.x — bootstrap + 悬浮 UI。
// 游戏逻辑全部在 XRC* 模块；交互全部在 XRCPracticePanel（ArcCreate 同构）。
#define XRC_TWEAK_VERSION  @"v8.9.9"
#define XRC_BUILD_LABEL    @"Sideload"
// 构建号：CI 生成 xrc_build_stamp.h（commit sha + 时间）；本地构建回退 "dev"。
// 日志首行打印——用于确认实际装配的版本，杜绝版本混淆。
#if __has_include("xrc_build_stamp.h")
#  include "xrc_build_stamp.h"
#endif
#ifndef XRC_BUILD_STAMP
#  define XRC_BUILD_STAMP "dev"
#endif

#import <substrate.h>
#import <time.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#import <stdatomic.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "fishhook.h"
#import "XRCFloatButton.h"
#import "XRCPracticePanel.h"
#import "WHToast/WHToast.h"

#include "XRCProfile.h"
#include "XRCRuntime.h"
#include "XRCProbe.h"
#include "XRCClock.h"
#include "XRCPlayer.h"
#include "XRCGameplay.h"
#include "XRCJudge.h"
#include "XRCConfig.h"

extern UIApplication *UIApp;

void acc_flog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - 全局 UI 状态（配置快照 + 控件）

static xrc_config_t g_cfg = {0};
XRCFloatButton *button = nil;   // AccCommon.h extern（UI hook 引用）

#pragma mark - 主程序定位（唯一跨模块的 image base 实现）

uint64_t xrc_image_base(void) {
    static uint64_t cached = 0;
    if (cached) return cached;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, ".dylib") != NULL) continue;
        const char *slash = strrchr(name, '/');
        if (slash && strcmp(slash + 1, "Arc-mobile") == 0) {
            cached = (uint64_t)_dyld_get_image_header(i);
            break;
        }
    }
    if (!cached && n > 0)
        cached = (uint64_t)_dyld_get_image_header(0);
    return cached;
}

#pragma mark - 菜单（UI 逻辑，配置读写走 XRCConfig）

// 练习面板桥接：保留 AccMenuController 类名（供 UIWindow hook 引用），
// 内部转发到 XRCPracticePanel（ArcCreate 同构）。
@interface AccMenuController : NSObject
+ (instancetype)shared;
- (void)show;
- (void)hide;
- (UIWindow *)keyWindow;
@end

@implementation AccMenuController
+ (instancetype)shared {
    static AccMenuController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [AccMenuController new]; });
    return s;
}
- (void)show { [[XRCPracticePanel shared] show]; }
- (void)hide { [[XRCPracticePanel shared] hide]; }
- (UIWindow *)keyWindow {
    if ([UIApp.delegate respondsToSelector:@selector(window)]) {
        UIWindow *w = [UIApp.delegate performSelector:@selector(window)];
        if (w) return w;
    }
    for (UIWindow *w in UIApp.windows) if (w.isKeyWindow) return w;
    return UIApp.windows.firstObject;
}
@end

#pragma mark - UI overlay

%group ui
%hook NSBundle
+ (NSBundle *)bundleForClass:(Class)aClass {
    if (aClass == [%c(WHToastView) class]) {
        NSBundle *main = [NSBundle mainBundle];
        return main ?: %orig;
    }
    return %orig;
}
%end

%hook UIWindow
- (void)bringSubviewToFront:(UIView *)view {
    %orig;
    if (view == button) return;
    if (button) %orig(button);
    // 练习面板自身管理层级（show 时已 bringSubviewToFront）
}
- (void)addSubview:(UIView *)view {
    %orig;
    if (view == button) return;
    if (button) [self bringSubviewToFront:button];
}
%end
%end

#pragma mark - floating button bootstrap

static void initButton(void) {
    [WHToast setShowMask:NO];
    button = [XRCFloatButton shared];
    // 单击 = 打开练习面板（ArcCreate 同构：时间轴/循环/速度/跳转）
    button.onTap = ^{
        [[AccMenuController shared] show];
    };
    // 长按 = 切换速度预设（原单击行为）
    button.onLongPress = ^{
        if (g_cfg.speed_count <= 0) return;
        g_cfg.rate_index = (g_cfg.rate_index + 1) % g_cfg.speed_count;
        xrc_clock_set_rate((double)g_cfg.speeds[g_cfg.rate_index]);
        xrc_config_save(&g_cfg);
        if (g_cfg.toast) {
            [WHToast showMessage:[NSString stringWithFormat:@"%.3fx (tap opens menu)", g_cfg.speeds[g_cfg.rate_index]]
                                       duration:0.5 finishHandler:^{}];
        }
    };
    UIWindow *w = [[AccMenuController shared] keyWindow];
    [button attachToWindow:w];
    if (!g_cfg.button_enabled) [button setHiddenState:YES];
}

#pragma mark - bootstrap

// 文件日志（侧载下 Console 不便）。
void acc_flog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[xrc-arcdemo] %@", line);
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        NSString *path = [docs stringByAppendingPathComponent:@"xrc-arcdemo.log"];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

static void doBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        acc_flog(@"==== xrc-arcdemo tweak %@ build %s doBootstrap begin ====",
                 XRC_TWEAK_VERSION, XRC_BUILD_STAMP);
        uint64_t base = xrc_image_base();
        g_xrc = xrc_runtime_discover();
        @try { initButton(); }       @catch (NSException *e) { acc_flog(@"initButton EX: %@", e); }
        @try { xrc_player_install(base); }      @catch (NSException *e) { acc_flog(@"player EX: %@", e); }
        @try { xrc_gameplay_install_hooks(base); } @catch (NSException *e) { acc_flog(@"gameplay EX: %@", e); }
        @try {
            if (xrc_judge_install(base))
                xrc_judge_log_stats();   // 安装成功 → 打一次基线统计
        } @catch (NSException *e) { acc_flog(@"judge EX: %@", e); }
        @try { xrc_probe_run(); }               @catch (NSException *e) { acc_flog(@"probe EX: %@", e); }
        @try {
            static dispatch_once_t tw_once;
            dispatch_once(&tw_once, ^{
                struct rebinding rs[1] = {
                    { "gettimeofday", (void *)xrc_clock_gettimeofday, (void **)&xrc_clock_orig_gettimeofday },
                };                rebind_symbols(rs, 1);
            });
        } @catch (NSException *e) { acc_flog(@"timewarp EX: %@", e); }
        if (g_cfg.speed_count > 0)
            xrc_clock_set_rate((double)g_cfg.speeds[g_cfg.rate_index]);
        acc_flog(@"config path: %@", xrc_config_path());
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            void *p = xrc_player_get();
            if (xrc_player_detect_change(p)) {
                acc_flog(@"new song: player=%p", p);
                xrc_loop_reset_all();   // 退出重进 = 练习状态归零（retry 同播放器，不走这里）
            }
            if (p) {
                xrc_player_try_capture_length(p);
                xrc_player_poll_position(p);   // 位置兜底（getpos hook 不频繁触发）
            }
        }];
        acc_flog(@"doBootstrap done");
    });
}

static void onAppDidEnterBackground(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    xrc_clock_freeze_inc();
    acc_flog(@"app -> background, warp frozen (count=%d)", xrc_clock_freeze_count());
}

static void onAppWillEnterForeground(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    xrc_clock_freeze_dec();
    acc_flog(@"app -> foreground, warp unfrozen (count=%d)", xrc_clock_freeze_count());
}

static void onAppLaunched(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object,
                          CFDictionaryRef userInfo) {
    acc_flog(@"onAppLaunched notification fired");
    doBootstrap();
}

%ctor {
    acc_flog(@"ctor entered (dylib loaded ok)");
    @try { %init(ui); }   @catch (NSException *e) { acc_flog(@"%%init(ui) EX: %@", e); }
    @try { xrc_config_load(&g_cfg); }  @catch (NSException *e) { acc_flog(@"config EX: %@", e); }
    @try {
        xrc_judge_set_windows(g_cfg.judge_max_ms, g_cfg.judge_pure_ms,
                              g_cfg.judge_far_ms, g_cfg.judge_lost_ms);
        float scale = (g_cfg.judge_max_ms + g_cfg.judge_pure_ms +
                       g_cfg.judge_far_ms + g_cfg.judge_lost_ms) / 270.0f;
        xrc_judge_set_scale(scale);
    } @catch (NSException *e) {}
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        onAppLaunched,
        (CFStringRef)UIApplicationDidFinishLaunchingNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        onAppDidEnterBackground,
        (CFStringRef)UIApplicationDidEnterBackgroundNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        onAppWillEnterForeground,
        (CFStringRef)UIApplicationWillEnterForegroundNotification,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        acc_flog(@"3s fallback bootstrap");
        doBootstrap();
    });
}
