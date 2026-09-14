// XRCHotLoad.m — 热加载实现。
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "XRCHotLoad.h"
#include "xrc_plugin_abi.h"
#include "XRCProfile.h"
#include "XRCRuntime.h"
#include "XRCHook.h"
#include "XRCOMLog.h"
#import "XRCLog.h"

#define XRC_PLUGIN_URL   "http://127.0.0.1:8080/__xrc/plugin.dylib"

static NSString *s_plugin_dir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"xrcdemo-net"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// 同步 GET（本文件只在后台队列被调，阻塞可接受）。
static NSData *s_fetch(const char *url, NSTimeInterval timeout) {
    NSURL *u = [NSURL URLWithString:@(url)];
    if (!u) return nil;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.timeoutInterval = timeout;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __block NSData *body = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:r
        completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (d.length && code == 200) body = d;
            dispatch_semaphore_signal(sem);
        }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                             (int64_t)((timeout + 1.0) * NSEC_PER_SEC)));
    return body;
}

// 外层能力表。尾部追加字段时记得同步 xrc_plugin_abi.h 的 abi 号。
static void s_host_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:@(fmt) arguments:ap];
    va_end(ap);
    xrc_log(@"[plugin] %@", s);
}

static char *s_host_policy_json(void) {
    return xrc_policy_json_copy();          // XRCOMLog 提供，malloc 串
}

static xrc_host_t s_host;

// dlopen 的候选路径，按序尝试。
//
// 为什么 bundle 排第一：App 沙盒**不允许对数据容器里的文件做可执行 mmap**
// （真机实测：`file system sandbox blocked mmap()`，注意这跟 AMFI 签名是两套机制，
// 越狱绕过的是后者）。而 app bundle 是沙盒放行的 —— 外层 libxrcdemo.dylib 自己
// 就是从那里 dlopen 进来的，这就是证据。
//
// 部署方式因此变成：私服取文件 → 由**外部**（PC 侧经 root SSH 推送 + 设备上
// ldid -S 签名）落进 bundle。用户不需要做任何事。
static NSArray<NSString *> *s_candidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    if (bundle.length) {
        [a addObject:[bundle stringByAppendingPathComponent:@"xrc_plugin.dylib"]];
    }
    [a addObject:[s_plugin_dir() stringByAppendingPathComponent:@"plugin.dylib"]];
    return a;
}

static NSString *s_fetch_target(void) {
    return [s_plugin_dir() stringByAppendingPathComponent:@"plugin.dylib"];
}

// 把下载到的插件放进候选里的"可执行映射放行"位置。
// 沙盒内进程写不了自己的 bundle —— 这一步交给外部（见上面的部署说明）。
static bool s_try_dlopen(NSString *path, void **out_handle) {
    const char *p = path.UTF8String;
    if (!p || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return false;
    xrc_log(@"[hotload] 尝试 dlopen: %@", path);
    void *h = dlopen(p, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *e = dlerror();
        xrc_log(@"[hotload]   失败: %s", e ? e : "(no error)");
        return false;
    }
    *out_handle = h;
    return true;
}

void xrc_hotload_run_logged(void) {
    xrc_log(@"[hotload] begin: %s", XRC_PLUGIN_URL);
    bool ok = xrc_hotload_run();
    xrc_log(@"[hotload] %@", ok ? @"插件已加载并返回" : @"未加载（沿用内置行为）");
}

bool xrc_hotload_run(void) {
    // 1) 先尽力把最新插件拉到本地（失败不致命 —— bundle 里可能已有旧版可用）
    NSData *blob = s_fetch(XRC_PLUGIN_URL, 3.0);
    if (blob.length) {
        NSString *path = s_fetch_target();
        NSString *tmp = [path stringByAppendingString:@".new"];
        if ([blob writeToFile:tmp atomically:YES]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if ([[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:nil]) {
                xrc_log(@"[hotload] 已落盘 %lu 字节 -> %@",
                        (unsigned long)blob.length, path);
            }
        }
    } else {
        xrc_log(@"[hotload] 拉取失败（服务器未跑 / 文件不存在），改试本地候选");
    }

    // 2) 依次试候选路径
    void *h = NULL;
    for (NSString *cand in s_candidates()) {
        if (s_try_dlopen(cand, &h)) {
            xrc_log(@"[hotload] dlopen 成功: %@", cand);
            break;
        }
    }
    if (!h) return false;
    xrc_plugin_main_t fn = (xrc_plugin_main_t)dlsym(h, "xrc_plugin_main");
    if (!fn) {
        xrc_log(@"[hotload] 找不到入口 xrc_plugin_main");
        dlclose(h);
        return false;
    }

    memset(&s_host, 0, sizeof(s_host));
    s_host.abi        = XRC_PLUGIN_ABI_NOW;
    s_host.image_base = g_xrc.image_base;
    s_host.version    = "xrcdemo/om12+hotload";
    s_host.log        = s_host_log;
    s_host.om_find          = xrc_om_find;
    s_host.om_probe         = xrc_om_probe;
    s_host.om_force_applog  = xrc_om_force_applog;
    s_host.mem_rd64         = xrc_om_mem_rd64;
    s_host.mem_wr64         = xrc_om_mem_wr64;
    s_host.policy_json      = s_host_policy_json;
    s_host.brk_capture_seq  = xrc_brk_capture_seq;
    s_host.brk_capture_take = xrc_brk_capture_take;
    s_host.brk_blob_seq     = xrc_brk_blob_seq;
    s_host.brk_blob_take    = xrc_brk_blob_take;
    s_host.brk_blob_sp      = xrc_brk_blob_sp;
    s_host.brk_set_unlock_all = xrc_brk_set_unlock_all;
    s_host.brk_set_cb_bypass  = xrc_brk_set_cb_bypass;

    int rc = -1;
    @try {
        rc = fn(&s_host);
    } @catch (NSException *e) {
        xrc_log(@"[hotload] 插件抛异常: %@", e);
        rc = -2;
    }
    xrc_log(@"[hotload] xrc_plugin_main 返回 %d", rc);
    // 故意不 dlclose：插件常驻，且它可能注册了后续要用的东西
    return rc == 0;
}
