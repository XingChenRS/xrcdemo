// PluginMain.m — 热加载插件的入口（v2）。
//
// 这个 dylib 由 CI 编译、私服托管、设备侧外层 dylib 联网拉取后 dlopen。
// **改这里 = 只重跑 CI，不用重注入/重签名/重装 app** —— 那才是耗时的部分。
//
// 与外层的唯一契约见 xrc_plugin_abi.h：导出
//     int xrc_plugin_main(const xrc_host_t *host);
// 返回 0 = 成功。整个调用被外层包在 @try/@catch + 信号兜底里。
//
// v2 相对 v1 的三处修订：
//   1) 所有内存读取改走 mach_vm_read_overwrite（地址不可读时返回错误而非
//      把进程带走）。v1 直接解引用，探针读到垃圾指针 → 真机实测秒崩。
//   2) 策略解析先抠掉 "_fields" 段。那段里每个键都有同名的说明文字
//      （值是 "1=…" 开头的字符串），朴素 strstr 会先撞上它，把
//      plugin_probe:0 误读成 1 —— 真机实测踩过。
//   3) 探针不再假设字段语义，改为**原始 hex dump**（对象头 + 策略指定的
//      任意区段/绝对地址），短串解码按本二进制实测的 byte23 约定。
//
// v2.2 新增 plugin_raw_applog：以**空表单**直调 OnlineManager 的 slot72
// （真实实例来自 om_find）。宿主强发会把策略表单注入 X1，body 变成我们给的
// 内容；空表单则走方法内部 0x100625384 分支（默认构造路径）——这才是游戏
// 自然调用时会走的语义，服务端因此能收到**真实载荷**。
// 调用形状（this, map, cb）复刻宿主已验证过的强发（X2 必须有合法对象，
// 否则方法内 [X2+0x18] 崩）。调用后立刻从宿主捕获缓冲取回明文+帧并 dump。
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#include "xrc_plugin_abi.h"
#include "XRCProfile.h"

#define PLUGIN_VERSION "2.4"

// ---------------------------------------------------------------- 安全内存读
// vm_read_overwrite：地址未映射时返回 KERN 错误，不会 SIGSEGV。
// （用 vm_ 而不是 mach_vm_ 前缀：iOS SDK 只声明了前者，二者在 arm64 上等价。）
static bool rd(uint64_t addr, void *buf, size_t n) {
    if (!addr) return false;
    vm_size_t out = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                          (vm_address_t)addr, (vm_size_t)n,
                          (vm_address_t)(uintptr_t)buf, &out);
    return kr == KERN_SUCCESS && out == n;
}
static uint64_t rd64(uint64_t addr) { uint64_t v = 0; rd(addr, &v, 8); return v; }
static uint8_t  rd8(uint64_t addr)  { uint8_t  v = 0; rd(addr, &v, 1); return v; }

// ---------------------------------------------------------------- 策略解析
// 把 "_fields" 那个对象用空格抹掉（等长替换，保留偏移），之后朴素 strstr 安全。
static void pol_strip_fields(char *json) {
    char *p = strstr(json, "\"_fields\"");
    if (!p) return;
    char *b = strchr(p, '{');
    if (!b) return;
    int depth = 0;
    char *q = b;
    while (*q) {
        if (*q == '"') {                    // 串：整段跳过（含转义）
            q++;
            while (*q && *q != '"') {
                if (*q == '\\' && q[1]) q++;
                q++;
            }
            if (*q == '"') q++;
            continue;
        }
        if (*q == '{') depth++;
        else if (*q == '}') { depth--; if (depth == 0) { q++; break; } }
        q++;
    }
    memset(p, ' ', (size_t)(q - p));
}

static int pol_get_num(const char *json, const char *key, long long *out) {
    if (!json || !key) return 0;
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    *out = strtoll(p + 1, NULL, 0);
    return 1;
}

static int pol_get_str(const char *json, const char *key, char *out, size_t outsz) {
    if (!json || !key) return 0;
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < outsz) out[i++] = *p++;
    out[i] = 0;
    return 1;
}

// ---------------------------------------------------------------- 打印工具
// 16 字节/行：地址 + hex + ASCII。
static void dump_hex(const xrc_host_t *host, const char *tag, uint64_t addr, size_t len) {
    for (size_t off = 0; off < len; off += 16) {
        uint8_t b[16];
        size_t n = len - off < 16 ? len - off : 16;
        if (!rd(addr + off, b, n)) {
            host->log("[%s] %08llx <不可读>", tag,
                      (unsigned long long)(addr + off));
            return;
        }
        char hex[16 * 3 + 1], asc[17];
        size_t k = 0, a = 0;
        for (size_t i = 0; i < n; i++) {
            k += (size_t)snprintf(hex + k, sizeof(hex) - k, "%02x ", b[i]);
            asc[a++] = (b[i] >= 32 && b[i] < 127) ? (char)b[i] : '.';
        }
        asc[a] = 0;
        host->log("[%s] %08llx: %-48s %s", tag,
                  (unsigned long long)(addr + off), hex, asc);
    }
}

// "off:len, off:len"（十六进制，len 可省=16）→ 以 add_base 为基准逐段 dump。
static void dump_ranges(const xrc_host_t *host, const char *tag,
                        const char *spec, uint64_t add_base) {
    const char *p = spec;
    while (*p) {
        while (*p == ' ' || *p == ',' || *p == '\t') p++;
        if (!*p) break;
        char *end;
        uint64_t a = strtoull(p, &end, 16);
        if (end == p) break;
        p = end;
        while (*p == ' ' || *p == ':') p++;
        uint64_t n = strtoull(p, &end, 16);
        if (end == p) n = 16;
        p = end;
        if (!n) n = 16;
        if (n > 0x10000) n = 0x10000;       // 单段上限 64KB，防手滑
        host->log("[%s] ---- %s +%llx (%llu 字节)", tag, tag,
                  (unsigned long long)a, (unsigned long long)n);
        dump_hex(host, tag, add_base + a, (size_t)n);
    }
}

// 本二进制实测的 libc++ 短串约定（sub_100623AEC @0x100625268 反汇编）：
// byte23 带符号 <0（长串）→ ptr@+0 / size@+8；否则 byte23 **原值**即长度。
static void fmt_string(uint64_t s, char *out, size_t outsz) {
    out[0] = 0;
    if (!s) { snprintf(out, outsz, "<null>"); return; }
    uint8_t flag = rd8(s + 23);
    uint64_t data;
    size_t n;
    if (flag & 0x80) { data = rd64(s); n = (size_t)rd64(s + 8); }
    else             { data = s;       n = flag; }
    if (!n) { snprintf(out, outsz, "\"\""); return; }
    char buf[256];
    size_t k = n < sizeof(buf) - 1 ? n : sizeof(buf) - 1;
    if (!rd(data, buf, k)) {
        snprintf(out, outsz, "<不可读 len=%zu>", n);
        return;
    }
    size_t w = 0;
    for (size_t i = 0; i < k && w + 1 < outsz; i++)
        out[w++] = (buf[i] >= 32 && buf[i] < 127) ? (char)buf[i] : '.';
    out[w] = 0;
}

// 若 vec 处像 std::vector<std::string>（24B 元素），逐条解码。
static void try_vec_strings(const xrc_host_t *host, const char *tag, uint64_t vec) {
    uint64_t b = rd64(vec), e = rd64(vec + 8), c = rd64(vec + 16);
    if (!b || !e) { host->log("[%s] %08llx: 不似 vector (b=0)", tag,
                              (unsigned long long)vec); return; }
    uint64_t bytes = e - b;
    if (e < b || bytes % 24 || bytes > 24 * 128 ||
        (c && c < b) || (c && (c - b) % 24)) {
        host->log("[%s] %08llx: 不似 vector<string> (b=%llx e=%llx c=%llx)",
                  tag, (unsigned long long)vec, (unsigned long long)b,
                  (unsigned long long)e, (unsigned long long)c);
        return;
    }
    size_t n = (size_t)(bytes / 24);
    host->log("[%s] %08llx: vector<string> %zu 条 @%llx", tag,
              (unsigned long long)vec, n, (unsigned long long)b);
    for (size_t i = 0; i < n; i++) {
        char s[256];
        fmt_string(b + i * 24, s, sizeof(s));
        host->log("[%s]   [%zu] %s", tag, i, s);
    }
}

// 在镜像自身（__TEXT/__DATA_CONST/__DATA 合计 ~26MB）里搜 8 字节等于 obj 的槽位。
// 单例模式的全局指针就藏在 __DATA/__BSS —— 找到它就能静态 refscan 出 getter，
// 再顺藤摸瓜找到所有使用点（包括调虚表槽 72 的那处）。
static void find_obj_refs(const xrc_host_t *host, uint64_t obj) {
    const uint64_t base = host->image_base;
    const uint64_t span = 0x1900000;
    const size_t chunk = 1u << 20;
    uint8_t *buf = malloc(chunk + 8);
    if (!buf) return;
    host->log("[om2] 搜指向 obj 的指针（镜像内 %llx..%llx）：",
              (unsigned long long)base, (unsigned long long)(base + span));
    int hits = 0;
    uint64_t last_va = 0;
    for (uint64_t off = 0; off < span && hits < 24; off += chunk - 8) {
        size_t want = (size_t)((span - off < chunk) ? span - off : chunk);
        if (!rd(base + off, buf, want)) continue;
        size_t n = want / 8;
        const uint64_t *p = (const uint64_t *)buf;
        for (size_t i = 0; i < n; i++) {
            if (p[i] == obj) {
                uint64_t va = base + off + i * 8;
                if (va != last_va) {
                    host->log("[om2]   +%llx  (va %llx)",
                              (unsigned long long)(va - base), (unsigned long long)va);
                    last_va = va;
                    if (++hits >= 24) break;
                }
            }
        }
    }
    if (!hits) host->log("[om2]   （镜像内没有直接指针）");
    free(buf);
}

// ---------------------------------------------------------------- 探针 v2
static void probe_v2(const xrc_host_t *host, const char *pol) {
    uint64_t want = host->image_base + XRC_OM_VTABLE_OFF;
    uint64_t obj = host->om_find ? host->om_find() : 0;
    if (!obj) { host->log("[om2] 未定位到 OM 单例（vptr=%llx）",
                          (unsigned long long)want); return; }
    uint64_t vptr = rd64(obj);
    host->log("[om2] obj=%llx vptr=%llx want=%llx %s",
              (unsigned long long)obj, (unsigned long long)vptr,
              (unsigned long long)want, vptr == want ? "OK" : "??");

    // 登记偏移的交叉验证（读失败一律 0，语义以 hex dump 为准）
    host->log("[om2] +f0=%llu +140(user)=%llu +148=%llu",
              (unsigned long long)rd64(obj + XRC_OM_OFF_ACC_COUNT),
              (unsigned long long)rd64(obj + XRC_OM_OFF_USER_ID),
              (unsigned long long)rd64(obj + XRC_OM_OFF_FIFTY));

    // 谁持有 obj —— 单例全局槽（静态反查 getter 的锚点）
    find_obj_refs(host, obj);

    // 默认：对象头原始视图
    dump_hex(host, "om2", obj, 0x180);

    // 策略附加：obj 相对 + 绝对地址区段（同一次启动内地址有效）
    char spec[512];
    if (pol && pol_get_str(pol, "om_hex", spec, sizeof(spec)) && spec[0])
        dump_ranges(host, "om2", spec, obj);
    if (pol && pol_get_str(pol, "abs_hex", spec, sizeof(spec)) && spec[0])
        dump_ranges(host, "abs", spec, 0);

    // 登记的三个"疑似 vector"位置逐一验证
    try_vec_strings(host, "om2.f8", obj + XRC_OM_OFF_VEC_BEGIN);
    try_vec_strings(host, "om2.100", obj + XRC_OM_OFF_VEC_END);
    try_vec_strings(host, "om2.108", obj + XRC_OM_OFF_VEC_CAP);
}

// ---------------------------------------------------------------- 真实 applog 调用
// no-op 回调（X2）。形状复刻宿主 XRCOMLog 的实现：__base 的对象布局里
// __f_ 指针在 +0x18；虚表 [2] 是 __clone()（返回自身即可）。
static void  s_cb_noop(void) {}
static void *s_cb_vtbl[8];
static struct { void *vtbl; } s_cb_base;
static uint8_t s_cb[0x40];
static void *s_cb_clone_self(void) { return (void *)&s_cb_base; }

// libc++ std::string 写入（与宿主 s_put_string 同一套实测约定）：
// ≤22 内联、byte23 记长度；否则长串 {ptr, size, cap|1<<63}。
static void put_string(uint8_t *dst, const void *src, size_t n) {
    const uint8_t *s = (const uint8_t *)src;
    if (n <= 22) {
        memcpy(dst, s, n);
        dst[n] = 0;
        dst[23] = (uint8_t)n;
    } else {
        uint8_t *buf = malloc(n + 1);
        if (!buf) return;
        memcpy(buf, s, n);
        buf[n] = 0;
        *(uint64_t *)dst      = (uint64_t)(uintptr_t)buf;
        *(uint64_t *)(dst + 8)  = n;
        *(uint64_t *)(dst + 16) = n | (1ULL << 63);
    }
}

// 单对 std::map 的容器/节点静态区（宿主同款右倾链的退化形态）
static uint8_t s_map[0x40];
static uint8_t s_node[0x50];
static uint8_t s_emap[0x40];   // 空 map

// 标准 base64（带 padding）。用途：v2.4 把 PFX 二进制转成 ASCII 安全值 ——
// 实测发现表单序列化器按 C 字符串处理值（遇 0x00 截断、不做 percent-encode），
// 所以真实上报的 log_blob 必然是 ASCII 化的（base64 最可能）。
static size_t b64_encode(const uint8_t *in, size_t n, char *out) {
    static const char *T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0, i = 0;
    while (i + 3 <= n) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8) | in[i+2];
        out[o++] = T[(v >> 18) & 63]; out[o++] = T[(v >> 12) & 63];
        out[o++] = T[(v >> 6) & 63];  out[o++] = T[v & 63];
        i += 3;
    }
    if (n - i == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[o++] = T[(v >> 18) & 63]; out[o++] = T[(v >> 12) & 63]; out[o++] = '='; out[o++] = '=';
    } else if (n - i == 2) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8);
        out[o++] = T[(v >> 18) & 63]; out[o++] = T[(v >> 12) & 63]; out[o++] = T[(v >> 6) & 63]; out[o++] = '=';
    }
    out[o] = 0;
    return o;
}

// 用 OM+0xa0 处的真实 blob（vector<uint8_t>）组装 {"log_blob": <值>} 表单。
// encode_base64=false：原始二进制（v2.3，会被 NUL 截断，留作对照）；
// true：base64 文本（v2.4，ASCII 安全，疑似真实格式）。
static bool build_blob_form(uint64_t obj, size_t *out_len, bool encode_base64) {
    uint64_t beg = rd64(obj + 0xa0);
    uint64_t end = rd64(obj + 0xa8);
    if (!beg || end <= beg || end - beg > 0x10000) return false;
    size_t n = (size_t)(end - beg);
    uint8_t *copy = malloc(n);
    if (!copy) return false;
    if (!rd(beg, copy, n)) { free(copy); return false; }

    memset(s_map, 0, sizeof(s_map));
    memset(s_node, 0, sizeof(s_node));
    put_string(s_node + 0x20, "log_blob", 8);       // key
    if (encode_base64) {
        char *b64 = malloc((n / 3 + 2) * 4 + 8);
        if (!b64) { free(copy); return false; }
        size_t m = b64_encode(copy, n, b64);
        free(copy);
        put_string(s_node + 0x38, b64, m);          // value（长串）
        *out_len = m;
    } else {
        put_string(s_node + 0x38, copy, n);         // value（长串，勿 free）
        *out_len = n;
    }
    *(uint64_t *)(s_node + 0x18) = 1;                          // 黑节点
    *(uint64_t *)(s_node + 0x10) = (uint64_t)(uintptr_t)(s_map + 8);  // parent = &end_node
    *(uint64_t *)(s_map + 0x00)  = (uint64_t)(uintptr_t)s_node;  // __begin_node_
    *(uint64_t *)(s_map + 0x08)  = (uint64_t)(uintptr_t)s_node;  // 根
    *(uint64_t *)(s_map + 0x10)  = 1;                            // size
    return true;
}

static void hex_dump_lines(const xrc_host_t *host, const char *tag,
                           const uint8_t *b, size_t n) {
    for (size_t off = 0; off < n; off += 32) {
        char line[32 * 3 + 1];
        size_t k = 0, m = n - off < 32 ? n - off : 32;
        for (size_t i = 0; i < m; i++)
            k += (size_t)snprintf(line + k, sizeof(line) - k, "%02x", b[off + i]);
        host->log("[%s] %04zx: %s", tag, off, line);
    }
}

// mode 1 = 空表单（直通语义验证）；mode 2 = {log_blob: OM+0xa0 真实 blob}
static void call_real_applog(const xrc_host_t *host, int mode) {
    uint64_t obj = host->om_find ? host->om_find() : 0;
    if (!obj) { host->log("[raw] OM 未定位"); return; }
    uint64_t fn = rd64(rd64(obj) + 0x240);
    if (!fn) { host->log("[raw] slot72 为空"); return; }

    // 空 libc++ std::map：begin == &end_node（=map+8），size=0。
    memset(s_emap, 0, sizeof(s_emap));
    *(uint64_t *)(s_emap)      = (uint64_t)(uintptr_t)(s_emap + 8);
    *(uint64_t *)(s_emap + 8)  = 0;
    *(uint64_t *)(s_emap + 16) = 0;

    uint8_t *map = s_emap;
    if (mode == 2 || mode == 3) {
        size_t blen = 0;
        bool b64 = (mode == 3);
        if (build_blob_form(obj, &blen, b64)) {
            uint64_t p0 = rd64(obj + 0xa0);
            host->log("[raw] 表单 = {log_blob: %zu 字节%s}  前16字节 %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
                      blen, b64 ? " base64" : "",
                      (unsigned)rd8(p0 + 0), (unsigned)rd8(p0 + 1),
                      (unsigned)rd8(p0 + 2), (unsigned)rd8(p0 + 3),
                      (unsigned)rd8(p0 + 4), (unsigned)rd8(p0 + 5),
                      (unsigned)rd8(p0 + 6), (unsigned)rd8(p0 + 7),
                      (unsigned)rd8(p0 + 8), (unsigned)rd8(p0 + 9),
                      (unsigned)rd8(p0 + 10), (unsigned)rd8(p0 + 11),
                      (unsigned)rd8(p0 + 12), (unsigned)rd8(p0 + 13),
                      (unsigned)rd8(p0 + 14), (unsigned)rd8(p0 + 15));
            map = s_map;
        } else {
            host->log("[raw] OM+0xa0 blob 读取失败，退回空表单");
        }
    }

    memset(s_cb, 0, sizeof(s_cb));
    if (!s_cb_vtbl[0]) {
        for (int i = 0; i < 8; i++) s_cb_vtbl[i] = (void *)&s_cb_noop;
        s_cb_vtbl[2] = (void *)&s_cb_clone_self;
        s_cb_base.vtbl = s_cb_vtbl;
    }
    *(uint64_t *)(s_cb + 0x18) = (uint64_t)(uintptr_t)&s_cb_base;

    host->log("[raw] 调用 slot72 fn=%llx obj=%llx map=%p cb=%p mode=%d",
              (unsigned long long)fn, (unsigned long long)obj, map, s_cb, mode);
    ((void (*)(uint64_t, void *, void *))(uintptr_t)fn)(obj, map, s_cb);
    host->log("[raw] 调用返回");

    // 立刻取回捕获（宿主在 BRK 处理器里存的），防止后续任何异常丢帧
    static uint8_t cap[0x1000];
    size_t n1 = host->brk_capture_take ? host->brk_capture_take(cap, sizeof(cap)) : 0;
    if (n1) {
        host->log("[raw] 明文捕获 %zu 字节:", n1);
        hex_dump_lines(host, "raw.plain", cap, n1 > 0x200 ? 0x200 : n1);
    } else {
        host->log("[raw] 无明文捕获（obj+0x128 未被写/无效）");
    }
    size_t n2 = host->brk_blob_take ? host->brk_blob_take(cap, sizeof(cap)) : 0;
    if (n2) {
        host->log("[raw] 帧捕获 %zu 字节, sp=%llx",
                  n2, (unsigned long long)(host->brk_blob_sp ? host->brk_blob_sp() : 0));
        hex_dump_lines(host, "raw.frame", cap, n2);
    } else {
        host->log("[raw] 无帧捕获");
    }
}

// ---------------------------------------------------------------- 入口
int xrc_plugin_main(const xrc_host_t *host) {
    if (!host || host->abi < XRC_PLUGIN_ABI_V1) {
        return 1;   // ABI 不认识，直接退
    }
    host->log("plugin v%s 已加载 (host abi=%u, image=%llx, ver=%s)",
              PLUGIN_VERSION, host->abi,
              (unsigned long long)host->image_base,
              host->version ? host->version : "?");

    char *raw = host->policy_json ? host->policy_json() : NULL;
    char *pol = raw ? strdup(raw) : NULL;
    if (raw) host->log("policy: %s", raw);
    if (pol) pol_strip_fields(pol);

    // 行为由策略驱动，插件本身不含策略常量 —— 这样连插件都很少需要改。
    long long v = 0;
    if (pol && pol_get_num(pol, "plugin_probe", &v) && v == 1) {
        host->log("→ probe v2");
        probe_v2(host, pol);
    }
    v = 0;
    if (pol && pol_get_num(pol, "plugin_force_applog", &v) && v == 1) {
        host->log("→ force_applog");
        if (host->om_force_applog) {
            bool ok = host->om_force_applog();
            host->log("force_applog -> %d", (int)ok);
        }
    }
    v = 0;
    if (pol && pol_get_num(pol, "plugin_raw_applog", &v) && (v == 1 || v == 2 || v == 3)) {
        host->log("→ raw_applog mode=%lld（直调 slot72）", v);
        call_real_applog(host, (int)v);
    }

    // 拥有/解锁链开关（功能账 §1）：策略驱动。热载重触发即生效（无需重启 app）。
    // 目标函数在外层（libxrcdemo 的 XRCHook），经 RTLD_DEFAULT 动态解析。
    v = 0;
    if (pol && pol_get_num(pol, "unlock_all", &v)) {
        void (*set_unlock)(bool) =
            (void (*)(bool))dlsym(RTLD_DEFAULT, "xrc_brk_set_unlock_all");
        if (set_unlock) {
            set_unlock(v == 1);
            host->log("→ unlock_all = %lld", v);
        } else {
            host->log("→ unlock_all: 外层未导出 xrc_brk_set_unlock_all（需重新注入新外层）");
        }
    }
    // cb 验证链开关（功能账 §3）：同上，策略驱动
    v = 0;
    if (pol && pol_get_num(pol, "cb_bypass", &v)) {
        void (*set_cb)(bool) =
            (void (*)(bool))dlsym(RTLD_DEFAULT, "xrc_brk_set_cb_bypass");
        if (set_cb) {
            set_cb(v == 1);
            host->log("→ cb_bypass = %lld", v);
        } else {
            host->log("→ cb_bypass: 外层未导出 xrc_brk_set_cb_bypass（需重新注入新外层）");
        }
    }
    // 观察：四桩命中统计（unlock_l1/l2/l3/story_gate 是否在跑）
    v = 0;
    if (pol && pol_get_num(pol, "unlock_stats", &v) && v == 1) {
        uint32_t (*hits)(int) = (uint32_t (*)(int))dlsym(RTLD_DEFAULT, "xrc_brk_hits");
        int      (*count)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "xrc_brk_slot_count");
        const char *(*sname)(int) = (const char *(*)(int))dlsym(RTLD_DEFAULT, "xrc_brk_slot_name");
        if (hits && count && sname) {
            int n = count();
            for (int i = 0; i < n; i++)
                host->log("[unlock] slot %s hits=%u", sname(i), hits(i));
        } else {
            host->log("[unlock] 统计接口未找到");
        }
    }

    free(raw);
    free(pol);
    return 0;
}
