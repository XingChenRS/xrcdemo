// XRCProbe.h — 运行时能力探针（内联组件回报机制）。
// 目的：不再依赖静态试错。dylib 启动后主动验证：
//   1. 桩点是否真的注入（读被 patch 的入口字节 + trampoline 字节比对）
//   2. slot.orig 是否合理（= 入口 VA 重定位值）
//   3. vtable hook 是否真的装上（读回槽位，剥离 PAC 后比对函数指针）
//   4. 转场锚点是否可用（槽 178 非空）
// 结果写入日志（xrc-arcdemo.log）+ 全局能力结构 g_caps，UI 按能力门控。
#pragma once

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    bool stub_present;        // 入口字节 = 我方 patch
    bool stub_v2;             // trampoline = v2（含 MOV X3,X6；v1 缺 a6 转发）
    bool judge_handler_live;  // slot.orig 合理 且 slot.handler == 我方 handler
    bool gp_hook_live;        // GameScene vtable[103] == xrc_gameplay_update
    bool mtp_hook_live;       // MTP vtable[7] == 我方 getpos
    bool replay_available;    // 转场槽 178 非空
    int  judge_calls;         // handler 累计调用次数（证明端到端活）
} xrc_caps_t;

extern xrc_caps_t g_caps;

// 在全部 install 之后调用一次。逐项检查并打日志。
void xrc_probe_run(void);
