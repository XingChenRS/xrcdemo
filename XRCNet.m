// XRCNet.m — 私服重定向与请求日志实现。
//
// 为什么在 NSURLConnection 层做：游戏的 HttpAsynConnection 最终都走
// -[NSURLConnection initWithRequest:delegate:startImmediately:]；在这里改写 URL
// 能一次覆盖所有 API（成绩、auth、cb 下载、applog…），且完全不碰 TLS 栈——
// 换域后 TrustKit 因域名不在 pin 表而返回 DomainNotPinned，证书由系统正常校验。
//
// 注意：不改 scheme/host 之外的任何东西。path 与 query 原样保留，服务端因此
// 能看到真实端点（含 /coordinatedballetclock/42/ 前缀），便于对照与日志。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdatomic.h>
#include <string.h>

#include "XRCNet.h"
#include "XRCProfile.h"
#import "XRCLog.h"

static _Atomic(bool) s_enabled = false;
static _Atomic(unsigned long long) s_requests = 0;
static _Atomic(unsigned long long) s_rewritten = 0;

static NSString *s_base = nil;      // 目标 base，如 http://192.168.1.10:8080
static NSArray<NSString *> *s_match = nil;   // 需要改写的 host 列表

static IMP s_orig_init = NULL;

static NSArray<NSString *> *s_default_match(void) {
    // 默认改写名单集中在 XRCProfile.h（跨版本单一编辑点）
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *h in [@(XRC_NET_DEFAULT_MATCH) componentsSeparatedByString:@","]) {
        NSString *t = [h stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [a addObject:t];
    }
    return a.count ? a : @[ @"arcapi-v4.lowiro.com" ];
}

void xrc_net_set_enabled(bool on) { atomic_store(&s_enabled, on); }
bool xrc_net_enabled(void) { return atomic_load(&s_enabled); }

void xrc_net_set_base(const char *base) {
    s_base = (base && *base) ? @(base) : nil;
    xrc_log(@"[net] base = %@", s_base ?: @"(none)");
}

void xrc_net_set_match(const char *hosts) {
    if (hosts && *hosts) {
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *h in [@(hosts) componentsSeparatedByString:@","]) {
            NSString *t = [h stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [a addObject:t];
        }
        s_match = a.count ? a : s_default_match();
    } else {
        s_match = s_default_match();
    }
}

unsigned long long xrc_net_requests(void) { return atomic_load(&s_requests); }
unsigned long long xrc_net_rewritten(void) { return atomic_load(&s_rewritten); }

// 改写 scheme/host/port，保留 path/query/fragment
static NSURL *s_rewrite(NSURL *url) {
    if (!s_base || !url) return nil;
    NSString *host = url.host;
    if (!host) return nil;
    BOOL matched = NO;
    for (NSString *h in s_match) {
        if ([host caseInsensitiveCompare:h] == NSOrderedSame) { matched = YES; break; }
    }
    if (!matched) return nil;

    NSURLComponents *base = [NSURLComponents componentsWithString:s_base];
    if (!base.scheme || !base.host) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = base.scheme;
    c.host = base.host;
    c.port = base.port;
    return c.URL;
}

static void s_log_request(NSURLRequest *req) {
    NSString *method = req.HTTPMethod ?: @"GET";
    NSUInteger bodyLen = req.HTTPBody.length;
    NSDictionary *hdrs = req.allHTTPHeaderFields;
    xrc_log(@"[net] %@ %@ (body=%lu, hdrs=%lu)",
            method, req.URL.absoluteString, (unsigned long)bodyLen,
            (unsigned long)hdrs.count);
}

// -[NSURLConnection initWithRequest:delegate:startImmediately:]
static id s_init_with_request(id self, SEL _cmd, NSURLRequest *req, id delegate, BOOL start) {
    atomic_fetch_add(&s_requests, 1);
    if (req) {
        @try {
            if (atomic_load(&s_enabled)) {
                NSURL *nu = s_rewrite(req.URL);
                if (nu) {
                    NSMutableURLRequest *m = [req mutableCopy];
                    m.URL = nu;
                    req = m;
                    atomic_fetch_add(&s_rewritten, 1);
                }
            }
            s_log_request(req);
        } @catch (NSException *e) {
            xrc_log(@"[net] EX: %@", e);
        }
    }
    return ((id (*)(id, SEL, NSURLRequest *, id, BOOL))s_orig_init)(self, _cmd, req, delegate, start);
}

// 结果观测：委托类是游戏的 HttpAsynConnection。只记录、原样转发，不改行为。
// 目的：区分"请求没发出去"（ATS/连接层拦截）与"发出去了但服务端没响应"。
static IMP s_orig_fail = NULL;
static IMP s_orig_resp = NULL;

static void s_hook_fail(id self_, SEL _cmd, NSURLConnection *c, NSError *err) {
    @try {
        xrc_log(@"[net] ✗ FAILED %@ — %@ (%ld)",
                c.originalRequest.URL.path, err.localizedDescription, (long)err.code);
    } @catch (NSException *e) {}
    if (s_orig_fail) ((void (*)(id, SEL, NSURLConnection *, NSError *))s_orig_fail)(self_, _cmd, c, err);
}

static void s_hook_resp(id self_, SEL _cmd, NSURLConnection *c, NSURLResponse *r) {
    @try {
        NSInteger code = [(NSHTTPURLResponse *)r statusCode];
        xrc_log(@"[net] ← %ld %@", (long)code, c.originalRequest.URL.path);
    } @catch (NSException *e) {}
    if (s_orig_resp) ((void (*)(id, SEL, NSURLConnection *, NSURLResponse *))s_orig_resp)(self_, _cmd, c, r);
}

static void s_swizzle_result_logging(void) {
    Class hc = objc_getClass("HttpAsynConnection");
    if (!hc) { xrc_log(@"[net] HttpAsynConnection absent (result logging off)"); return; }
    Method mf = class_getInstanceMethod(hc, @selector(connection:didFailWithError:));
    if (mf) {
        s_orig_fail = method_getImplementation(mf);
        method_setImplementation(mf, (IMP)s_hook_fail);
        xrc_log(@"[net] result logging: didFailWithError hooked");
    } else {
        xrc_log(@"[net] didFailWithError absent, skip");
    }
    Method mr = class_getInstanceMethod(hc, @selector(connection:didReceiveResponse:));
    if (mr) {
        s_orig_resp = method_getImplementation(mr);
        method_setImplementation(mr, (IMP)s_hook_resp);
    }
}

void xrc_net_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_match = s_default_match();
        Class cls = objc_getClass("NSURLConnection");
        if (!cls) { xrc_log(@"[net] NSURLConnection not found"); return; }
        SEL sel = @selector(initWithRequest:delegate:startImmediately:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { xrc_log(@"[net] method not found"); return; }
        s_orig_init = method_getImplementation(m);
        method_setImplementation(m, (IMP)s_init_with_request);
        xrc_log(@"[net] installed (match=%@)", [s_match componentsJoinedByString:@","]);
        s_swizzle_result_logging();
    });
}
