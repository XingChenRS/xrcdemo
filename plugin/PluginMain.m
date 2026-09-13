// PluginMain.m — 热加载插件的入口。
//
// 这个 dylib 由 CI 编译、私服托管、设备侧外层 dylib 联网拉取后 dlopen。
// **改这里 = 只重跑 CI，不用重注入/重签名/重装 app** —— 那才是耗时的部分。
//
// 与外层的唯一契约见 xrc_plugin_abi.h：导出
//     int xrc_plugin_main(const xrc_host_t *host);
// 返回 0 = 成功。整个调用被外层包在 @try/@catch + 信号兜底里。
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

#include "xrc_plugin_abi.h"

#define PLUGIN_VERSION "1"

// 极简 JSON 取值：够用即可，不引第三方。命中返回 1 并把值拷进 out。
static int pol_get(const char *json, const char *key, char *out, size_t outsz) {
    if (!json || !key) return 0;
    const char *p = strstr(json, key);
    if (!p) return 0;
    p = strchr(p, ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '"') {
        p++;
        size_t i = 0;
        while (*p && *p != '"' && i + 1 < outsz) out[i++] = *p++;
        out[i] = 0;
        return 1;
    }
    size_t i = 0;
    while (*p && *p != ',' && *p != '}' && i + 1 < outsz) out[i++] = *p++;
    while (i && (out[i - 1] == ' ' || out[i - 1] == '\n')) i--;
    out[i] = 0;
    return i > 0;
}

int xrc_plugin_main(const xrc_host_t *host) {
    if (!host || host->abi < XRC_PLUGIN_ABI_V1) {
        return 1;   // ABI 不认识，直接退
    }
    host->log("plugin v%s 已加载 (host abi=%u, image=%llx, ver=%s)",
              PLUGIN_VERSION, host->abi,
              (unsigned long long)host->image_base,
              host->version ? host->version : "?");

    char *pol = host->policy_json ? host->policy_json() : NULL;
    if (pol) host->log("policy: %s", pol);

    // 行为由策略驱动，插件本身不含策略常量 —— 这样连插件都很少需要改。
    char v[64];

    if (pol && pol_get(pol, "\"plugin_probe\"", v, sizeof(v)) && v[0] == '1') {
        host->log("→ probe");
        if (host->om_probe) host->om_probe();
    }
    if (pol && pol_get(pol, "\"plugin_force_applog\"", v, sizeof(v)) && v[0] == '1') {
        host->log("→ force_applog");
        if (host->om_force_applog) {
            bool ok = host->om_force_applog();
            host->log("force_applog -> %d", (int)ok);
        }
    }

    if (pol) free(pol);
    return 0;
}
