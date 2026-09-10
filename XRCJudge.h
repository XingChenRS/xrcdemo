// XRCJudge.h — 改判：slot 注册 + 完全接管 handler。
#pragma once

#include <stdint.h>

// 在找到 __xrc_slots（桩点注入后）时注册 handler。slot_off 来自 profile。
// 返回是否注册成功（未打桩的版本返回 false，静默降级）。
bool xrc_judge_install(uint64_t image_base);

// 配置窗口（由 XRCConfig 调用）：max/pure/far/lost ms。
void xrc_judge_set_windows(int max_ms, int pure_ms, int far_ms, int lost_ms);

// 当前生效窗口（UI 显示用）。
void xrc_judge_get_windows(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms);

// 窗口缩放（handler 生效路径）：scale = 四档之和 / 270.0（默认 1.0）。
void xrc_judge_set_scale(float scale);
float xrc_judge_get_scale(void);

// 立即应用阈值（改写判定函数的 8 个 CMP 立即数）。UI 提交时调用。
void xrc_judge_apply_thresholds(void);

// 桩点是否真正激活（未打桩/未注册时为 false → UI 隐藏改判区）。
bool xrc_judge_is_active(void);
