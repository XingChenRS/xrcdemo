// xrc_plugin_abi.h — 外层 dylib 与热加载插件之间的唯一契约。
//
// 为什么要这层：内层（联网拉下来的 plugin.dylib）需要用到外层已经建好的能力
// （定位 OnlineManager、强发 applog、读内存、写日志…）。让它去 dlsym 外层符号
// 既脆弱又依赖加载选项；改成**外层把能力表直接传进来**，版本一目了然。
//
// 版本纪律：本结构只许**尾部追加**字段，不许改已有字段的类型/顺序；
// 每次追加把 abi 加一。内层先检查 host->abi 再决定用哪些字段。
#pragma once

#include <stdint.h>
#include <stdbool.h>

#define XRC_PLUGIN_ABI_V1 1u
#define XRC_PLUGIN_ABI_V2 2u   // v2：尾部追加功能开关（unlock_all / cb_bypass）
#define XRC_PLUGIN_ABI_V3 3u   // v3：开关组一拆四（unlock_own/fv/do + gate_open），去掉登录门
#define XRC_PLUGIN_ABI_NOW XRC_PLUGIN_ABI_V3

typedef struct xrc_host {
    uint32_t abi;                  // = XRC_PLUGIN_ABI_NOW（内层必须校验）
    uint32_t reserved0;
    uint64_t image_base;           // 主程序 slide 后基址
    const char *version;           // 外层版本串（日志用）

    // 日志（与 xrc_log 同签名，NS_FORMAT_FUNCTION 不跨 ABI，故用普通 C 变参）
    void (*log)(const char *fmt, ...);

    // OnlineManager
    uint64_t (*om_find)(void);             // 扫可写内存按 vptr 定位单例；0=未找到
    void     (*om_probe)(void);            // 打印累加器/载荷字段
    bool     (*om_force_applog)(void);     // 强制调用槽 72

    // 原始内存（自带可读性兜底；地址非法返回 0/false）
    uint64_t (*mem_rd64)(uint64_t addr);
    bool     (*mem_wr64)(uint64_t addr, uint64_t val);

    // 策略（服务器 /__xrc/policy 或 Documents/xrcdemo-net/policy.json）
    // 返回 JSON 文本；调用方负责 free。取不到返回 NULL。
    char *   (*policy_json)(void);

    // BRK 捕获（明文 / 整帧）
    uint32_t (*brk_capture_seq)(void);
    size_t   (*brk_capture_take)(void *buf, size_t cap);
    uint32_t (*brk_blob_seq)(void);
    size_t   (*brk_blob_take)(void *buf, size_t cap);
    uint64_t (*brk_blob_sp)(void);

    // 功能开关（v2 追加；见功能账 §1/§3。内层：host->abi 校验版本）
    void     (*brk_set_unlock_all)(bool on);   // [v2 遗留字段] 老外层用；v3 外层置 NULL
    void     (*brk_set_cb_bypass)(bool on);    // cb 就绪恒真 + 校验/错码分发跳过
    // v3 追加：开关组一拆四（每个都可独立拨动）
    void     (*brk_set_unlock_own)(bool on);   // 拥有链 unlock_l1/l2/l3
    void     (*brk_set_unlock_fv)(bool on);    // lock_fv（FV fast path 全解锁）
    void     (*brk_set_unlock_do)(bool on);    // lock_do（DO/konzetsu 分支全解锁）
    void     (*brk_set_gate_open)(bool on);    // fv_gate（链门 1 = 放行）
} xrc_host_t;

// 内层必须导出的唯一入口。整个调用包在 @try/@catch + 信号兜底里。
// 返回 0 = 成功；非 0 = 失败码（外层只记日志，不致命）。
typedef int (*xrc_plugin_main_t)(const xrc_host_t *host);
