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

void xrc_hotload_run_logged(void) {
    xrc_log(@"[hotload] begin: %s", XRC_PLUGIN_URL);
    bool ok = xrc_hotload_run();
    xrc_log(@"[hotload] %@", ok ? @"插件已加载并返回" : @"未加载（沿用内置行为）");
}

bool xrc_hotload_run(void) {
    NSData *blob = s_fetch(XRC_PLUGIN_URL, 3.0);
    if (!blob.length) {
        xrc_log(@"[hotload] 拉取失败（服务器未跑 / 文件不存在 / 网络）");
        return false;
    }
    NSString *path = [s_plugin_dir() stringByAppendingPathComponent:@"plugin.dylib"];
    // 先写临时文件再原子替换：避免半截文件被 dlopen
    NSString *tmp = [path stringByAppendingString:@".new"];
    if (![blob writeToFile:tmp atomically:YES]) {
        xrc_log(@"[hotload] 写盘失败: %@", tmp);
        return false;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:nil]) {
        xrc_log(@"[hotload] 替换失败: %@", path);
        return false;
    }
    xrc_log(@"[hotload] 已落盘 %lu 字节 -> %@", (unsigned long)blob.length, path);

    // 越狱设备 AMFI 已绕过，未签名 dylib 可 dlopen；非越狱会被拒（预期内）
    void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *e = dlerror();
        xrc_log(@"[hotload] dlopen 失败: %s", e ? e : "(no error)");
        return false;
    }
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
