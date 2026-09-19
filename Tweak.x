// Tweak.x — xrcdemo bootstrap + 悬浮球 UI（悬浮球逻辑见 XRCFloatButton）。
// 游戏逻辑全部在 XRC* 模块；交互全部在 XRCPracticePanel（ArcCreate 同构）。
#define XRC_TWEAK_VERSION  @"beta1.0"
#define XRC_BUILD_LABEL    @"Sideload"
// 版本契约（beta1.0）：基线 = Arcaea iOS 7.0.255；跨版本适配见 README §4。
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
#include <string.h>
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
#include "XRCHook.h"
#include "XRCDump.h"
#include "XRCNet.h"
#include "XRCOMLog.h"
#include "XRCHotLoad.h"

extern UIApplication *UIApp;

void xrc_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - 全局 UI 状态（配置快照 + 控件）

static xrc_config_t g_cfg = {0};
XRCFloatButton *button = nil;   // XRCLog.h extern（UI hook 引用）

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

// 练习面板桥接：保留 XRCMenuBridge 类名（供 UIWindow hook 引用），
// 内部转发到 XRCPracticePanel（ArcCreate 同构）。
@interface XRCMenuBridge : NSObject
+ (instancetype)shared;
- (void)show;
- (void)hide;
- (UIWindow *)keyWindow;
@end

@implementation XRCMenuBridge
+ (instancetype)shared {
    static XRCMenuBridge *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [XRCMenuBridge new]; });
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
    // 单击 = 开/关练习面板（v9.0.0 用户定案：再单击关闭）
    button.onTap = ^{
        if ([[XRCPracticePanel shared] isVisible])
            [[XRCMenuBridge shared] hide];
        else
            [[XRCMenuBridge shared] show];
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
    UIWindow *w = [[XRCMenuBridge shared] keyWindow];
    [button attachToWindow:w];
    if (!g_cfg.button_enabled) [button setHiddenState:YES];
}

#pragma mark - bootstrap

// 文件日志（侧载下 Console 不便）。
void xrc_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[xrcdemo] %@", line);
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        NSString *path = [docs stringByAppendingPathComponent:@"xrcdemo.log"];
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
        xrc_log(@"==== xrcdemo %@ build %s doBootstrap begin ====",
                 XRC_TWEAK_VERSION, XRC_BUILD_STAMP);
        uint64_t base = xrc_image_base();
        g_xrc = xrc_runtime_discover();
        @try { initButton(); }       @catch (NSException *e) { xrc_log(@"initButton EX: %@", e); }
        @try { xrc_player_install(base); }      @catch (NSException *e) { xrc_log(@"player EX: %@", e); }
        @try { xrc_gameplay_install_hooks(base); } @catch (NSException *e) { xrc_log(@"gameplay EX: %@", e); }
        @try {
            if (xrc_judge_install(base))
                xrc_judge_log_stats();   // 安装成功 → 打一次基线统计
        } @catch (NSException *e) { xrc_log(@"judge EX: %@", e); }
        @try { xrc_probe_run(); }               @catch (NSException *e) { xrc_log(@"probe EX: %@", e); }
        // BRK 桩：验证形态（见 XRCProfile.h）。处理器已在 %ctor 装好，这里只注册桩点。
        @try { xrc_brk_setup(base); }           @catch (NSException *e) { xrc_log(@"brk EX: %@", e); }
        // 拥有/解锁链开关（功能账 §1）：配置项，默认关；打开后四桩强制"拥有=真"
        @try {
            xrc_brk_set_unlock_own(g_cfg.unlock_own);
            xrc_brk_set_unlock_fv(g_cfg.unlock_fv);
            xrc_brk_set_unlock_do(g_cfg.unlock_do);
            xrc_brk_set_gate_open(g_cfg.gate_open);
        }
        @catch (NSException *e) { xrc_log(@"unlock flags EX: %@", e); }
        // cb 验证链开关（功能账 §3）：默认关；打开后就绪恒真+校验/错码分发跳过
        @try { xrc_brk_set_cb_bypass(g_cfg.cb_bypass); }
        @catch (NSException *e) { xrc_log(@"cb flag EX: %@", e); }
        // 登录门守卫开关（功能账 §1.4）：默认开；开=解锁/领奖/联机不再弹"必须在线登录"
        // 自动演奏（功能账 §5）：默认关；开=一切判定强制 Pure（走现有判定 handler）
        @try { xrc_judge_set_autoplay(g_cfg.autoplay); }
        @catch (NSException *e) { xrc_log(@"autoplay flag EX: %@", e); }
        // 私服重定向：NSURLConnection 层改写 URL（不改 TLS；换域后 pin 自然放行）
        @try {
            xrc_net_install();
            xrc_net_set_base(g_cfg.net_base ? g_cfg.net_base.UTF8String : NULL);
            xrc_net_set_match(g_cfg.net_match ? g_cfg.net_match.UTF8String : NULL);
            xrc_net_set_enabled(g_cfg.net_enabled);
        } @catch (NSException *e) { xrc_log(@"net EX: %@", e); }
        @try {
            static dispatch_once_t tw_once;
            dispatch_once(&tw_once, ^{
                struct rebinding rs[1] = {
                    { "gettimeofday", (void *)xrc_clock_gettimeofday, (void **)&xrc_clock_orig_gettimeofday },
                };                rebind_symbols(rs, 1);
            });
        } @catch (NSException *e) { xrc_log(@"timewarp EX: %@", e); }
        if (g_cfg.speed_count > 0)
            xrc_clock_set_rate((double)g_cfg.speeds[g_cfg.rate_index]);
        xrc_log(@"config path: %@", xrc_config_path());
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            // BRK 桩统计：只在计数变化时落一行（回答"applog 何时触发"）。
            // ap_*（自动演奏）站点是逐音符/逐帧热点，不走这里——见下方 10s 汇总，避免刷爆日志。
            static uint32_t last_brk[XRC_BRK_MAX_SLOTS];
            int ns = xrc_brk_slot_count();
            for (int i = 0; i < ns; i++) {
                const char *nm = xrc_brk_slot_name(i);
                if (nm && strncmp(nm, "ap_", 3) == 0) continue;
                uint32_t h = xrc_brk_hits(i);
                if (h != last_brk[i]) {
                    xrc_log(@"[brk] %s hits=%u last=%.3fms",
                            xrc_brk_slot_name(i), h,
                            (double)xrc_brk_last_hit_us(i) / 1000.0);
                    last_brk[i] = h;
                }
            }
            // 自动演奏汇总：每 10s 一行（mark/skip/窗口强判/引擎 tick 数）+ 判定计数。
            // 用于对账"物量/分数 vs 原谱"：tick1 = 引擎发的 Pure tick 判定数量。
            {
                static int ap_tick = 0;
                if (++ap_tick >= 20) {
                    ap_tick = 0;
                    uint32_t st[6] = {0};
                    xrc_brk_ap_stats(st);
                    xrc_log(@"[ap] mark=%u disp=%u win_note=%u win_tap=%u tick1=%u tick2=%u lock=%u",
                            st[0], st[1], st[2], st[3], st[4], st[5], xrc_brk_lock_hits());
                    xrc_judge_log_stats();
                }
            }
            // applog 明文捕获落盘（加密前）。缓冲放静态区，避免块捕获大数组。
            static uint32_t last_cap_seq = 0;
            static uint8_t  capbuf[XRC_BRK_CAP_MAX];
            uint32_t cap_seq = xrc_brk_capture_seq();
            if (cap_seq != last_cap_seq) {
                last_cap_seq = cap_seq;
                size_t n = xrc_brk_capture_take(capbuf, sizeof(capbuf));
                if (n) {
                    NSString *dir = [NSSearchPathForDirectoriesInDomains(
                                        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                                     stringByAppendingPathComponent:@"xrcdemo-net"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                             withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *path = [dir stringByAppendingPathComponent:
                                      [NSString stringWithFormat:@"applog-%u.bin", cap_seq]];
                    NSData *blob = [NSData dataWithBytes:capbuf length:n];
                    BOOL wrote = [blob writeToFile:path atomically:YES];
                    // 前 64 字节 hex + ascii 预览，便于日志里直接看结构
                    NSMutableString *hex = [NSMutableString string];
                    NSMutableString *asc = [NSMutableString string];
                    for (size_t i = 0; i < n && i < 64; i++) {
                        [hex appendFormat:@"%02x", capbuf[i]];
                        [asc appendFormat:@"%c", (capbuf[i] >= 32 && capbuf[i] < 127) ? capbuf[i] : '.'];
                    }
                    xrc_log(@"[brk] applog plaintext %zu bytes wrote=%d -> %@", n, wrote, path);
                    xrc_log(@"[brk]   hex: %@", hex);
                    xrc_log(@"[brk]   asc: %@", asc);
                } else {
                    xrc_log(@"[brk] applog hit but no plaintext captured (buf empty/invalid)");
                }
            }
            // log_blob 密文捕获落盘（载荷加密出口，第二个桩点）。
            // 与明文分开缓冲：两次命中相隔极近，共用会被互相覆盖。
            static uint32_t last_blob_seq = 0;
            static uint8_t  blobbuf[XRC_BRK_CAP_MAX];
            uint32_t blob_seq = xrc_brk_blob_seq();
            if (blob_seq != last_blob_seq) {
                last_blob_seq = blob_seq;
                size_t n = xrc_brk_blob_take(blobbuf, sizeof(blobbuf));
                if (n) {
                    NSString *dir = [NSSearchPathForDirectoriesInDomains(
                                        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                                     stringByAppendingPathComponent:@"xrcdemo-net"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                             withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *path = [dir stringByAppendingPathComponent:
                                      [NSString stringWithFormat:@"logblob-%u.bin", blob_seq]];
                    NSData *blob = [NSData dataWithBytes:blobbuf length:n];
                    BOOL wrote = [blob writeToFile:path atomically:YES];
                    NSMutableString *hex = [NSMutableString string];
                    for (size_t i = 0; i < n && i < 64; i++)
                        [hex appendFormat:@"%02x", blobbuf[i]];
                    xrc_log(@"[brk] log_blob ciphertext %zu bytes wrote=%d -> %@", n, wrote, path);
                    xrc_log(@"[brk]   hex: %@", hex);
                } else {
                    xrc_log(@"[brk] log_blob hit but nothing captured");
                }
            }
            // 内存转储的文件触发器：Documents/xrcdemo-net/DUMP 存在 → 转储并删除它。
            // 这样不用碰 UI 就能触发（Filza/iDownload 里建个空文件即可），
            // 面板按钮走的是同一个入口。
            static uint32_t last_dump_done = 0;
            {
                NSString *docs = NSSearchPathForDirectoriesInDomains(
                    NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSString *netdir = [docs stringByAppendingPathComponent:@"xrcdemo-net"];
                NSString *flag = [netdir stringByAppendingPathComponent:@"DUMP"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
                    [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
                    xrc_dump_start();
                }
                // 转储进度（每 20% 或结束时打一行）
                if (xrc_dump_running()) {
                    int d = xrc_dump_regions_done(), t = xrc_dump_regions_total();
                    if (t > 0 && (d == t || d / 20 != last_dump_done / 20)) {
                        xrc_log(@"[dump] %d/%d regions, %.1f MB",
                                d, t, xrc_dump_bytes_written() / 1048576.0);
                    }
                    last_dump_done = d;
                }
                // OnlineManager 探针 / applog 强发：同一套标志文件机制。
                // PROBE  = 打印累加器与载荷字段（后台线程，内存扫描较重）
                // APPLOG = 直接调 vtable 槽 72 硬造一次上报（留在主线程，网络代码）
                NSString *pf = [netdir stringByAppendingPathComponent:@"PROBE"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:pf]) {
                    [[NSFileManager defaultManager] removeItemAtPath:pf error:nil];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        @try { xrc_om_probe(); } @catch (NSException *e) { xrc_log(@"[om] probe EX: %@", e); }
                    });
                }
                NSString *af = [netdir stringByAppendingPathComponent:@"APPLOG"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:af]) {
                    [[NSFileManager defaultManager] removeItemAtPath:af error:nil];
                    @try { xrc_om_force_applog(); } @catch (NSException *e) { xrc_log(@"[om] force EX: %@", e); }
                }
                // 热加载内层插件：HOTLOAD 标志 → 从私服拉 plugin.dylib 并 dlopen。
                // 这是"改逻辑不重注入"的关键：外层注入一次，之后只换私服上的插件。
                NSString *hf = [netdir stringByAppendingPathComponent:@"HOTLOAD"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:hf]) {
                    [[NSFileManager defaultManager] removeItemAtPath:hf error:nil];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        @try { xrc_hotload_run_logged(); }
                        @catch (NSException *e) { xrc_log(@"[hotload] EX: %@", e); }
                    });
                }
            }
            void *p = xrc_player_get();
            if (xrc_player_detect_change(p)) {
                xrc_log(@"new song: player=%p", p);
                // v9.0.0：不再自动清循环（用户定案——清除只走面板「重置循环段落」按钮）
            }
            if (p) {
                xrc_player_try_capture_length(p);
                xrc_player_poll_position(p);   // 位置兜底（getpos hook 不频繁触发）
            }
        }];
        xrc_log(@"doBootstrap done");
    });
}

static void onAppDidEnterBackground(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    xrc_clock_freeze_inc();
    xrc_log(@"app -> background, warp frozen (count=%d)", xrc_clock_freeze_count());
}

static void onAppWillEnterForeground(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    xrc_clock_freeze_dec();
    xrc_log(@"app -> foreground, warp unfrozen (count=%d)", xrc_clock_freeze_count());
}

static void onAppLaunched(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object,
                          CFDictionaryRef userInfo) {
    xrc_log(@"onAppLaunched notification fired");
    doBootstrap();
}

%ctor {
    xrc_log(@"ctor entered (dylib loaded ok)");
    @try { %init(ui); }   @catch (NSException *e) { xrc_log(@"%%init(ui) EX: %@", e); }
    @try { xrc_config_load(&g_cfg); }  @catch (NSException *e) { xrc_log(@"config EX: %@", e); }
    @try {
        xrc_judge_set_windows(g_cfg.judge_max_ms, g_cfg.judge_pure_ms,
                              g_cfg.judge_far_ms, g_cfg.judge_lost_ms);
        float scale = (g_cfg.judge_max_ms + g_cfg.judge_pure_ms +
                       g_cfg.judge_far_ms + g_cfg.judge_lost_ms) / 270.0f;
        xrc_judge_set_scale(scale);
    } @catch (NSException *e) {}
    // BRK 桩：处理器安装 + **立即注册**（2026-09-15 时序教训：cb 校验在 didFinishLaunching
    // 之前就有后台线程命中；注册晚于命中 = 空表分发 → 秒崩）。doBootstrap 里的 setup
    // 保留为幂等刷新（同 site 重复注册只换 handler）。
    @try { xrc_brk_setup_early(); } @catch (NSException *e) { xrc_log(@"brk early EX: %@", e); }
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
        xrc_log(@"3s fallback bootstrap");
        doBootstrap();
    });
}
