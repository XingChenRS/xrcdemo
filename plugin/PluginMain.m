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
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <stdlib.h>
#include <string.h>

#include "xrc_plugin_abi.h"
#include "XRCProfile.h"

#define PLUGIN_VERSION "2"

// ---------------------------------------------------------------- 安全内存读
// mach_vm_read_overwrite：地址未映射时返回 KERN 错误，不会 SIGSEGV。
static bool rd(uint64_t addr, void *buf, size_t n) {
    if (!addr) return false;
    mach_vm_size_t out = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
                          (mach_vm_address_t)addr, (mach_vm_size_t)n,
                          (mach_vm_address_t)(uintptr_t)buf, &out);
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

    free(raw);
    free(pol);
    return 0;
}
