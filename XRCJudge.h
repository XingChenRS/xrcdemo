// XRCJudge.h — 改判：静态桩（跳板 v2）+ dylib 完全接管 handler。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 注册 handler 到已注入的 slot（inject.py --stub）。返回是否注册成功
// （未打桩的版本返回 false，静默降级）。
bool xrc_judge_install(uint64_t image_base);

// 配置判定窗口（ms）。四档 → 级联阈值映射见 XRCJudge.m。
void xrc_judge_set_windows(int max_ms, int pure_ms, int far_ms, int lost_ms);

// 当前生效窗口（UI 显示用）。
void xrc_judge_get_windows(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms);

// 窗口缩放（历史字段，仅展示；生效以四档阈值为准）。
void xrc_judge_set_scale(float scale);
float xrc_judge_get_scale(void);

// 统计转储（每次调用/各档计数）——诊断用。
void xrc_judge_log_stats(void);

// 桩点是否真正激活（未打桩/未注册时为 false → UI 灰掉改判区）。
bool xrc_judge_is_active(void);

// 自动演奏（默认关）：一切判定（含漏扫 ts=-1 直调）强制 Pure 出口。
// 依据：漏扫（sub_10091F688 内，note时间+120ms 触发、ts=-1）同样流经本 handler。
void xrc_judge_set_autoplay(bool on);
bool xrc_judge_autoplay(void);
