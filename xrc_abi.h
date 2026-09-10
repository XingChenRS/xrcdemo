// xrc_abi.h — xrcdemo dylib 与注入器（inject.py）共享的 ABI 契约。
// 未来抽取到 projects/core 的候选文件：slot 布局 + info blob + handler 签名。
#pragma once

#include <stdint.h>
#include <stdbool.h>

#define XRC_MAGIC     0x58424331u  // 'XRC1'
#define XRC_INFO_VERSION 2         // v2: slot 24B + 判定链 handler ABI（v1 为 16B/slot）

// 桩点 slot（主程序 __DATA 尾部零填充，inject.py 写入）。
// handler = 0 时跳板原样直通（行为与未注入一致）。
struct xrc_slot {
    void    *handler;   // +0  dylib 运行时注册；完全接管，不调原函数
    void    *orig;      // +8  注入器写入原入口（运行时 = image_base + 静态偏移）
    uint64_t reserved;  // +16 预留（未来桩点参数/标志）
};

// info blob（__DATA 零填充区，dyld 不 rebase）：
// dylib 启动扫描 magic → 用 *静态偏移* 手动重定位所有 VA。
// 这是"桩点回报信息"机制：运行时提取的地址比静态逆向准确。
// 布局 = { u32 magic, u32 version, u64 fields[6], u64 reserved[8] }，共 120B。
struct xrc_info {
    uint32_t magic;          // XRC_MAGIC
    uint32_t version;        // XRC_INFO_VERSION
    uint64_t judge_entry_off;// sub_10091E684 静态偏移（判定核）
    uint64_t judge_slot_off; // slot 静态偏移
    uint64_t gp_vtable_off;  // GameScene vtable 静态偏移
    uint64_t gp_update_off;  // 槽 103 每帧函数静态偏移
    uint64_t mtp_vtable_off; // MTP vtable 静态偏移
    uint64_t mtp_getpos_off; // 槽 7 静态偏移
    uint64_t reserved[8];    // 未来桩点/锚点
};

// 改判 handler（完全接管 sub_10091E684 的语义）。
// ABI（7.0.255 已确认，trampoline v2 契约）：
//   X0 = note_group，X1 = note，X2 = ts（判定时刻 ms），X3 = a6（caller X6 透传）
// 跳板在 BR 前执行 `MOV X3, X6`，因此 handler 能拿到判定核从不写、
// 但落账函数 sub_100ACB880 需要的第 6 参。返回 1 = 消费该 note，0 = 未消费。
// 用普通 C 函数即可（BR 不改 LR，RET 直接回调用方）。
typedef uint64_t (*xrc_judge_handler_t)(uint64_t note_group, uint64_t note,
                                        int64_t ts, uint64_t a6);
