// XRCRuntime.h — 运行时锚点发现（桩点回报信息机制）。
// dylib 启动扫描 __DATA 中的 xrc_info blob（magic XRC1），把所有静态偏移
// 手动重定位为运行时地址。这是运行时提取，比静态逆向准确；编译期 profile
// 仅作 fallback。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 发现结果（运行时地址，0 = 未找到）。
typedef struct {
    bool     found;            // 是否发现并校验 magic
    uint64_t image_base;       // 主程序 slide 后基址
    uint64_t judge_entry;      // sub_1009D9ED8 运行时地址
    uint64_t judge_slot;       // xrc_slot 运行时地址
    uint64_t gp_vtable;        // GameScene vtable
    uint64_t gp_update;        // 槽 103 每帧函数
    uint64_t mtp_vtable;       // MTP vtable
    uint64_t mtp_getpos;       // 槽 7
} xrc_runtime_t;

// 扫描主程序 __DATA（从 profile 的预期偏移向前后各扫 1MB，容 ASLR 页面差）。
// 优先 info blob；未命中时用编译期 profile 偏移拼 image_base 作为 fallback。
xrc_runtime_t xrc_runtime_discover(void);

// 全局实例（启动时解析一次，全部模块共享）。
extern xrc_runtime_t g_xrc;
