// XRCClock.h — 时间基准：真实时间单一实现 + warp 计算 + freeze。
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <time.h>
#include <sys/time.h>

// 唯一真实时间实现。返回值 0 表示失败。
uint64_t xrc_real_now_us(void);

// 时间 warp：t0 重设（换速/解冻时由调用方决定语义）。
void xrc_clock_warp_reset(void);
void xrc_clock_set_rate(double rate);
double xrc_clock_get_rate(void);

// freeze 计数（>0 时 warp 冻结在 frozen_us）。
void xrc_clock_freeze_inc(void);
void xrc_clock_freeze_dec(void);
int32_t xrc_clock_freeze_count(void);

// fishhook 入口（gettimeofday 拦截），供 Tweak.x 注册。
int xrc_clock_gettimeofday(struct timeval *tv, void *tz);
// 原 gettimeofday（fishhook 保存），XRCGameplay 的 retime 用。
extern int (*xrc_clock_orig_gettimeofday)(struct timeval *, void *);
