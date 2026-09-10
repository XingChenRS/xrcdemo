// XRCGameplay.m — gp.update hook + 谱面钟 retime + seek（含 replay/循环）。
// seek 平移 = 音频 seek + 谱面钟 base 平移（判定比较 |note - (cur - base)|，
// 所以 base -= (cur - target) 即整体平移）。转场直调路线已废弃（UAF），
// XRC_HAS_TRANSITION 保持 0，仅保留编译分支与探针。

#import <Foundation/Foundation.h>
#import "AccCommon.h"    // acc_flog
#include <limits.h>
#include <sys/mman.h>
#include <errno.h>
#include <mach/vm_map.h>
#include <mach/mach_init.h>
#include "XRCGameplay.h"
#include "XRCRuntime.h"
#include "XRCProbe.h"
#include "XRCClock.h"
#include "XRCPlayer.h"
#include "XRCProfile.h"

#if __has_include(<ptrauth.h>)
#  include <ptrauth.h>
#endif

_Atomic(void *) xrc_gp_instance = NULL;

static void (*s_orig_gp_update)(void *, uint64_t, uint64_t, uint64_t, uint64_t) = NULL;
static void *s_gp_last_clock = NULL;
static uint64_t s_gp_last_real_us = 0;

// ---- deferred 操作状态机 ----
// 崩溃教训（2026-09-10 ips）：转场函数内部读 note_group+48（谱面钟），
// note_group 为 NULL 时 far=0x30 崩溃。所有执行路径必须先做**两级非空校验**：
//   scene != NULL && *(scene + XRC_GP_NOTEGROUP_OFF) != NULL
// 且请求在场景指针变化（换场/重开）时自动作废——旧场景的请求在新场景上无意义。
static _Atomic(uint32_t) s_pending_op    = XRC_OP_NONE;
static _Atomic(uint32_t) s_pending_ms    = 0;
static _Atomic(uint64_t) s_pending_scene = 0;   // 登记请求时的 scene 指针
static _Atomic(uint64_t) s_last_exec_us  = 0;   // 冷却起点（真实时间 us）
static _Atomic(uint64_t) s_exec_gen      = 0;
#define XRC_OP_COOLDOWN_US  (1500 * 1000ULL)    // 转场/seek 冷却 1.5s
#define XRC_OP_MAX_IDLE_US  (4000 * 1000ULL)    // 请求超过 4s 未执行 → 丢弃

bool xrc_gameplay_request(xrc_op_t op, uint32_t param_ms) {
    void *scene = atomic_load(&xrc_gp_instance);
    if (!scene) {
        acc_flog(@"request rejected: no live scene");
        return false;
    }
    uint32_t cur = atomic_load(&s_pending_op);
    if (cur != XRC_OP_NONE) {
        acc_flog(@"request rejected: pending op=%u", cur);
        return false;
    }
    atomic_store(&s_pending_scene, (uint64_t)scene);
    atomic_store(&s_pending_ms, param_ms);
    atomic_store(&s_pending_op, op);
    return true;
}

xrc_op_t xrc_gameplay_pending_op(void) {
    return (xrc_op_t)atomic_load(&s_pending_op);
}

// 两级非空校验：返回可用 note_group，否则 NULL。
static void *s_valid_note_group(void *scene) {
    if (!scene) return NULL;
    void *ng = *(void **)((char *)scene + XRC_GP_NOTEGROUP_OFF);
    if (!ng) return NULL;
    // 谱面钟必须可读（转场内部第一步就读 +48）
    void *clk = *(void **)((char *)ng + XRC_CLOCK_IN_NOTEGROUP_OFF);
    if (!clk) return NULL;
    return ng;
}

// ---- retry 监视器 v2（2026-09-10，确定性检测）----
// 用户流程：勾选开关 → 开启循环或 seek 定位（capture=目标点）→ 游戏中暂停 → Retry。
// 判据（比时钟跳变确定得多）：**音频位置的帧间大回跳**——retry 重建场景会让音频
// 从曲尾/当前点回到曲首（jump < -10s），单点演奏不可能产生。
// 触发后写一个 pending seek（目标=capture）；deferred 状态机在**新场景**的下一帧
// 才执行（旧场景已被 retry 销毁，同一帧不可用）。执行后解除（一次性）。
// 阈值说明：retry/换歌重建后音频必然从曲中/曲尾回到 0ms 附近，单点演奏的
// 帧间正常波动不可能超过 10 秒 → -10s 是"重建类事件"的可靠判据。
#define XRC_RETRY_AUDIO_JUMP_MS  (-10000)   // 音频帧间回跳阈值
static _Atomic(uint32_t) s_capture_ms = 0;      // 目标点（seek/循环 A 写入）；0 = 未武装
static _Atomic(bool)     s_cap_valid = false;
static int32_t           s_prev_audio_ms = -1;
static _Atomic(uint32_t) s_retry_armed_gen = 0; // 触发计数（诊断）

void xrc_gameplay_set_resume_ms(uint32_t ms) {
    atomic_store(&s_capture_ms, ms);
    atomic_store(&s_cap_valid, false);
    s_prev_audio_ms = -1;
    acc_flog(@"retry watch armed: %u ms", ms);
}
uint32_t xrc_gameplay_get_resume_ms(void) { return atomic_load(&s_capture_ms); }

// ---- 自动重建状态机（到 B → 冻结 → triggerAction(retry) → 新场景 seek 回 A）----
// 语义依据：retry = 游戏自身"销毁旧场景→完整重建"链路（replay-chain §11），
// 重建后音频/判定天然从头；配合 + 我们注入 seek 到 A = 真正的循环练习。
// 失败降级链：triggerAction 无效（无暂停态前置？）→ 2s 超时 → 解冻 + 日志，
// 用户手动 retry 仍能回 A（音频回跳检测）。
#define XRC_AR_STATE_IDLE     0
#define XRC_AR_STATE_FREEZE   1   // 已冻结，等 N 帧再触发（对齐暂停态）
#define XRC_AR_STATE_TRIGGER  2   // 已触发，等新场景出现
static _Atomic(uint32_t) s_ar_state = XRC_AR_STATE_IDLE;
static _Atomic(uint64_t) s_ar_stamp_us = 0;
static _Atomic(uint64_t) s_ar_scene_before = 0;
static _Atomic(uint32_t) s_ar_target_a = 0;

// 帧内调用（note_group 有效时）：音频位置回跳检测。
static void s_retry_watch_tick(void) {
    if (atomic_load(&s_capture_ms) == 0) { s_prev_audio_ms = -1; return; }
    int32_t pos = (int32_t)xrc_player_position_ms();
    if (pos < 0) return;
    if (!atomic_load(&s_cap_valid)) {
        s_prev_audio_ms = pos;
        atomic_store(&s_cap_valid, true);
        return;
    }
    int32_t jump = pos - s_prev_audio_ms;
    s_prev_audio_ms = pos;
    if (jump < XRC_RETRY_AUDIO_JUMP_MS) {
        // 手动 retry 回位点：循环开启时 = A 点；否则 = capture 点（Reset on Retry）。
        uint32_t a = 0, b = 0;
        xrc_loop_get_range(&a, &b);
        uint32_t target = 0;
        if (xrc_loop_get_enabled() && b > a + 1000) target = a;
        else target = atomic_load(&s_capture_ms);
        if (target && xrc_gameplay_request(XRC_OP_SEEK, target)) {
            atomic_fetch_add(&s_retry_armed_gen, 1);
            acc_flog(@"retry detected (audio jump %d) -> queued seek %u", jump, target);
        }
    }
}

// 在游戏循环内执行 pending（self = 当前活场景）。
static void s_exec_pending(void *self) {
    uint32_t op = atomic_load(&s_pending_op);
    if (op == XRC_OP_NONE) return;

    uint64_t now = xrc_real_now_us();

    // 场景变更 → 丢弃陈旧请求（旧场景的 seek/转场在新场景无意义）
    uint64_t req_scene = atomic_load(&s_pending_scene);
    if (req_scene != (uint64_t)self) {
        atomic_store(&s_pending_op, XRC_OP_NONE);
        acc_flog(@"pending op=%u dropped (scene changed %llx -> %p)", op, req_scene, self);
        return;
    }

    uint64_t last = atomic_load(&s_last_exec_us);
    if (last && now - last < XRC_OP_COOLDOWN_US) return;  // 冷却中

    // 过期丢弃
    static uint64_t s_req_time = 0;
    if (s_req_time == 0) s_req_time = now;
    if (now - s_req_time > XRC_OP_MAX_IDLE_US) {
        atomic_store(&s_pending_op, XRC_OP_NONE);
        s_req_time = 0;
        return;
    }

    uint32_t ms = atomic_load(&s_pending_ms);

    // 执行前最终校验（崩溃 guard）
    void *note_group = s_valid_note_group(self);
    if (!note_group) {
        acc_flog(@"pending op=%u aborted: note_group/clock null (scene=%p)", op, self);
        atomic_store(&s_pending_op, XRC_OP_NONE);
        return;
    }

    atomic_store(&s_pending_op, XRC_OP_NONE);   // 先清（防执行内重入）
    atomic_store(&s_last_exec_us, now);
    s_req_time = 0;
    atomic_fetch_add(&s_exec_gen, 1);

    if (op == XRC_OP_SEEK || op == XRC_OP_SEEK_REPLAY || op == XRC_OP_LOOP_REWIND) {
        // 音频 seek（player 可能已换歌，重新取）
        void *player = xrc_player_get();
        if (player) {
            xrc_clock_freeze_inc();
            xrc_player_seek_ms(player, ms);
            xrc_clock_freeze_dec();
        }
        // 谱面钟平移：判定比较的是"当前值 - 基准"，基准 -= (cur - target) 即可。
        // 写 +40/+36 后两分支都能自洽（分支 B 的 clock_ms = +32 - +40 同理）。
        int32_t cur_ms = xrc_chart_clock_ms(note_group);
        if (cur_ms >= -3000) {
            void *clk = *(void **)((char *)note_group + XRC_CLOCK_IN_NOTEGROUP_OFF);
            int32_t *base_off = (int32_t *)((char *)clk + XRC_CLK_BASE_OFF);
            *base_off += cur_ms - (int32_t)ms;
        }
        s_gp_last_real_us = 0;
        acc_flog(@"seek executed: ms=%u (cur was %d)", ms, cur_ms);
    }

    if (op == XRC_OP_SEEK_REPLAY || op == XRC_OP_LOOP_REWIND) {
        // 循环回绕/重播：位置已由 seek 平移给出，监视保持武装（用户可能随后 retry）；
        // 但把音频基准重置，避免回绕本身被识别成 retry。
        if (atomic_load(&s_capture_ms) != 0) {
            s_prev_audio_ms = (int32_t)xrc_player_position_ms();
            atomic_store(&s_cap_valid, true);
        }
        acc_flog(@"replay executed via seek (op=%u)", op);
    }
}

// ---- vtable swizzle（PAC 感知）----
int xrc_swizzle_vtable(uint64_t vtable_addr, uint64_t orig_fn_off, void *new_fn, void **out_orig) {
    extern uint64_t xrc_image_base(void);
    uint64_t base = xrc_image_base();
    if (!base) return INT_MIN;
    uint64_t target = base + orig_fn_off;
    void **vt = (void **)vtable_addr;
    // 同 6.13：地址合理性检查 + [-4, 64) 槽搜索
    if ((uintptr_t)vt < 0x100000000ULL || ((uintptr_t)vt & 7) != 0) return INT_MIN;
    for (int i = 0; i < 200; i++) {
        void *cur = vt[i];
        if (!cur) continue;
#if __has_feature(ptrauth_calls)
        void *stripped = ptrauth_strip(cur, ptrauth_key_asia);
#else
        void *stripped = cur;
#endif
        if ((uint64_t)stripped != target) continue;
        uintptr_t page = (uintptr_t)&vt[i] & ~(uintptr_t)0x3FFF;
        bool wrote = false;
        if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE) == 0) {
            wrote = true;
        } else {
            kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                                          0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            wrote = (kr == KERN_SUCCESS);
        }
        if (!wrote) return INT_MIN;
        if (out_orig) *out_orig = stripped;
#if __has_feature(ptrauth_calls)
        void *signed_new = ptrauth_sign_unauthenticated(new_fn,
                              ptrauth_key_asia,
                              ptrauth_blend_discriminator(&vt[i], 0));
        vt[i] = signed_new;
#else
        vt[i] = new_fn;
#endif
        mprotect((void *)page, 0x4000, PROT_READ);
        return i;
    }
    return INT_MIN;
}

// ---- 谱面钟 ----
int32_t xrc_chart_clock_ms(void *note_group) {
    if (!note_group) return -1;
    void *clk = *(void **)((char *)note_group + XRC_CLOCK_IN_NOTEGROUP_OFF);
    if (!clk) return -1;
    if (*(uint8_t *)((char *)clk + XRC_CLK_FLAG45_OFF) & 1)
        return *(int32_t *)((char *)clk + XRC_CLK_ALT_START_OFF) - *(int32_t *)((char *)clk + XRC_CLK_BASE_OFF);
    int32_t v = *(int32_t *)((char *)clk + XRC_CLK_CUR_OFF);
    int32_t off = (v <= 0) ? XRC_CLK_NEG_LEAD_MS : 0;
    return v - *(int32_t *)((char *)clk + XRC_CLK_BASE_OFF) + off;
}

// ---- gp.update retime（6.13 语义）----
static void s_gp_retime_logic_clock(void *note_group) {
    if (!note_group) return;
    if (xrc_clock_freeze_count() > 0) return;
    void *clk = *(void **)((char *)note_group + XRC_CLOCK_IN_NOTEGROUP_OFF);
    if (!clk) return;
    uint64_t now_us = xrc_real_now_us();
    if (!now_us) return;
    if (clk != s_gp_last_clock || s_gp_last_real_us == 0 || now_us <= s_gp_last_real_us) {
        s_gp_last_clock = clk;
        s_gp_last_real_us = now_us;
        return;
    }
    uint64_t delta_us = now_us - s_gp_last_real_us;
    if (delta_us > 200000ULL) delta_us = 200000ULL;
    s_gp_last_real_us = now_us;
    int32_t delta_ms = (int32_t)(delta_us / 1000ULL);
    if (delta_ms <= 0) return;
    double rate = xrc_clock_get_rate();
    int32_t adjust = 0;
    if (rate < 0.999 || rate > 1.001)
        adjust = (int32_t)((1.0 - rate) * (double)delta_ms);
    if (adjust == 0) return;
    int32_t *base_off = (int32_t *)((char *)clk + XRC_CLK_BASE_OFF);
    int64_t after = (int64_t)(*base_off) + (int64_t)adjust;
    if (after > INT_MAX) after = INT_MAX;
    if (after < INT_MIN) after = INT_MIN;
    *base_off = (int32_t)after;
}

void xrc_gameplay_update(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    if (self) {
        atomic_store(&xrc_gp_instance, self);
        void *note_group = *(void **)((char *)self + XRC_GP_NOTEGROUP_OFF);
        if (note_group) {
            s_gp_retime_logic_clock(note_group);
            int32_t pos = xrc_chart_clock_ms(note_group);
            if (pos > 0) xrc_loop_tick(self, (uint32_t)pos);
        }
        s_exec_pending(self);   // deferred 操作（seek/转场）在活场景循环内执行

        // retry 监视 v2（音频回跳）；循环卡死恢复保留。
        if (note_group) {
            s_retry_watch_tick();
            // 循环卡死恢复：pos 停滞超 1.5s 且位于 [A,B) 内 → 强制回 A
            int32_t pos = xrc_chart_clock_ms(note_group);
            static int32_t s_stall_pos = 0;
            static uint64_t s_stall_since = 0;
            uint64_t now_us = xrc_real_now_us();
            if (pos != s_stall_pos) {
                s_stall_pos = pos;
                s_stall_since = now_us;
            } else if (s_stall_since && now_us - s_stall_since > 1500000ULL) {
                uint32_t a = 0, b = 0;
                xrc_loop_get_range(&a, &b);
                if (xrc_loop_get_enabled() && pos < (int32_t)b - 200
                    && atomic_load(&s_ar_state) == XRC_AR_STATE_IDLE) {
                    if (xrc_gameplay_request(XRC_OP_LOOP_REWIND, a))
                        acc_flog(@"loop stall at %d -> forced rewind to %u", pos, a);
                }
                s_stall_since = now_us;
            }
        }
    }
    if (s_orig_gp_update) s_orig_gp_update(self, a2, a3, a4, a5);
}

void xrc_gameplay_install_hooks(uint64_t image_base) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!g_xrc.gp_vtable || !g_xrc.gp_update) return;  // 锚点未就绪 → 静默降级
        int slot = xrc_swizzle_vtable(g_xrc.gp_vtable,
                                      g_xrc.gp_update - g_xrc.image_base,
                                      (void *)xrc_gameplay_update,
                                      (void **)&s_orig_gp_update);
        if (slot != INT_MIN) acc_flog(@"gp.update vtable installed slot=%d", slot);
    });
}

// ---- seek（音频链可用时走完整路径；7.0 getpos/getCurrentSound 已重定位）----
void xrc_seek_ms(uint32_t ms) {
    void *player = xrc_player_get();
    if (!player) {
        // 谱面钟平移仍然保留（无音频时谱面可跳）
        void *gp = atomic_load(&xrc_gp_instance);
        if (gp) {
            void *note_group = *(void **)((char *)gp + XRC_GP_NOTEGROUP_OFF);
            int32_t cur_ms = xrc_chart_clock_ms(note_group);
            if (cur_ms >= -3000) {
                void *clk = note_group ? *(void **)((char *)note_group + XRC_CLOCK_IN_NOTEGROUP_OFF) : NULL;
                if (clk) {
                    int32_t *base_off = (int32_t *)((char *)clk + XRC_CLK_BASE_OFF);
                    *base_off += cur_ms - (int32_t)ms;
                }
            }
        }
        s_gp_last_real_us = 0;
        return;
    }

    xrc_clock_freeze_inc();
    if (xrc_player_seek_ms(player, ms))
        acc_flog(@"audio seek to %u ms", ms);

    void *gp = atomic_load(&xrc_gp_instance);
    if (gp) {
        void *note_group = *(void **)((char *)gp + XRC_GP_NOTEGROUP_OFF);
        int32_t cur_ms = xrc_chart_clock_ms(note_group);
        if (cur_ms >= -3000) {
            int32_t delta = cur_ms - (int32_t)ms;
            // 直接读 clk 写 base_off（retime 同款字段）
            void *clk = note_group ? *(void **)((char *)note_group + XRC_CLOCK_IN_NOTEGROUP_OFF) : NULL;
            if (clk) {
                int32_t *base_off = (int32_t *)((char *)clk + XRC_CLK_BASE_OFF);
                *base_off += delta;
            }
        }
    }
    s_gp_last_real_us = 0;
    xrc_clock_freeze_dec();
}

#pragma mark - 循环 / 自动重建（玩法语义说明）

/*
 * 玩法定义（2026-09-10 与用户闭合）：
 *
 * 【A-B 循环练习】
 *   用户流程：播放到起点按「起点」→ 播放到终点按「终点」→ 开「循环」。
 *   到 B 点后：冻结时间域（对齐游戏暂停语义）→ 100ms 后程序化触发
 *   triggerAction(retry)（= 暂停菜单 Retry 的同一函数，完整重建场景）
 *   → 新场景首帧 seek 回 A → 解冻。判定计数/连击随重建自然归零。
 *   失败降级：2s 内未见新场景（trigger 无效）→ 解冻 + 日志，用户手动
 *   retry 仍会经音频回跳检测回到 A。
 *
 * 【退出重进 vs retry 的区别】
 *   换歌/退出重进 = 播放器实例更换（player 指针变化）→ xrc_loop_reset_all()
 *   清空练习状态。retry = 同一播放器、场景重建 → 状态保留，正好用于循环。
 *
 * 【手动 retry 回位】
 *   循环开启时回 A 点；否则回「重开回起点」记录的目标（Reset on Retry）。
 *   检测依据 = 音频位置帧间回跳 > 10s（retry 重建的必然特征）。
 */

// replay 定案（2026-09-10）：不再直调转场函数（sub_100CA9590 会读旧场景
// note_group → UAF，已两次真机崩溃）。改为 seek 平移路线——音频 seek +
// 谱面钟 base 平移（XRC_CLK_BASE_OFF）。已判 note 不重现、计分不回滚，
// 属"练习定位"语义；循环 = 到 B 点后 deferred seek 回 A，往复。
// XRC_HAS_TRANSITION 保留为 0（转场直调路线已废弃，槽 178 仅作探测）。

typedef void (*transition_fn)(void *scene, int resume);

static _Atomic(bool) s_loop_enabled = false;
static _Atomic(uint32_t) s_loop_a = 0;
static _Atomic(uint32_t) s_loop_b = 0;

bool xrc_transition_resume(void *gameplay, bool resume) {
#if XRC_HAS_TRANSITION
    extern uint64_t xrc_image_base(void);
    uint64_t base = xrc_image_base();
    if (!base || !XRC_OFF_GP_VTABLE) return false;
    void **vt = (void **)(base + XRC_OFF_GP_VTABLE);
    void *fn_raw = vt[XRC_TRANSITION_VTABLE_SLOT];
    if (!fn_raw) return false;
#if __has_feature(ptrauth_calls)
    void *fn = ptrauth_strip(fn_raw, ptrauth_key_asia);
    void *signed_fn = ptrauth_sign_unauthenticated(fn, ptrauth_key_asia,
                        ptrauth_blend_discriminator(&vt[XRC_TRANSITION_VTABLE_SLOT], 0));
    ((transition_fn)signed_fn)(gameplay, resume ? 1 : 0);
#else
    ((transition_fn)fn_raw)(gameplay, resume ? 1 : 0);
#endif
    return true;
#else
    (void)gameplay; (void)resume;
    return false;
#endif
}

bool xrc_loop_get_enabled(void) { return atomic_load(&s_loop_enabled); }
void xrc_loop_set_range(uint32_t a_ms, uint32_t b_ms) {
    // 2026-09-10 交互重构：设定区间**不再自动启用**（面板流程：设起点→设终点→开循环）。
    // 区间合法性（b >= a+1000）在 tick 时检查。
    atomic_store(&s_loop_a, a_ms);
    atomic_store(&s_loop_b, b_ms);
}
void xrc_loop_set_enabled(bool on) {
    uint32_t a = atomic_load(&s_loop_a), b = atomic_load(&s_loop_b);
    if (on && b <= a + 1000) return;   // 区间不完整不允许开启
    atomic_store(&s_loop_enabled, on);
    acc_flog(@"loop %s (A=%u B=%u)", on ? "ON" : "OFF", a, b);
}
// 换歌（退出重进）→ 练习状态归零。retry 不改 player 指针，不会走到这里。
// 换歌/退出重进 = 练习状态归零（用户定义：只要退出重进就视作换歌，哪怕进同一首）。
// 触发链：Tweak.x 的 0.5s 轮询（player 指针变化）+ 面板 tick 的三信号联合判据
// （指针 / 曲长归零 / 位置回跳——v8.9.6 真机教训：单靠指针会漏）。
// retry 不走这里：retry 是同一播放器实例内的场景重建，状态必须保留才能续练。
void xrc_loop_reset_all(void) {
    atomic_store(&s_loop_enabled, false);
    atomic_store(&s_loop_a, 0);
    atomic_store(&s_loop_b, 0);
    xrc_gameplay_set_resume_ms(0);
    acc_flog(@"practice state cleared (song change)");
}
void xrc_loop_get_range(uint32_t *from_ms, uint32_t *to_ms) {
    if (from_ms) *from_ms = atomic_load(&s_loop_a);
    if (to_ms)   *to_ms   = atomic_load(&s_loop_b);
}
// 程序化 retry（步进 1：只做"选中 Retry + 清理复位"）
// 证据：sub_100947C20(pauseLayer) 即用户点 Retry 时序列的第①步（内部读
// PauseLayer+688 的 PauseOverlay 树，故必须先构造 PauseLayer）。
// 历史：直调 triggerAction(13)（旧 s_ar_trigger_retry）被游戏静默忽略
// （v8.9.6 真机日志连续 TIMEOUT 证实）——action 13 需要暂停层上下文。
static void s_ar_trigger_retry(void) {
    extern uint64_t xrc_image_base(void);
    uint64_t base = xrc_image_base();
    if (!base) return;
    uint64_t locator = *(uint64_t *)(base + XRC_OFF_SERVICE_LOCATOR);
    if (!locator) { acc_flog(@"auto-retry: service locator null"); return; }
    uint64_t game_model = *(uint64_t *)(locator + 0x10);
    if (!game_model) { acc_flog(@"auto-retry: game model null"); return; }
    void *scene = (void *)atomic_load(&s_ar_scene_before);   // 当前活场景（= delegate）
    if (!scene) { acc_flog(@"auto-retry: no scene"); return; }
    // PauseLayer(delegate=scene, gameModel, style=0)
    uint64_t (*pause_factory)(void *, uint64_t, int) =
        (uint64_t (*)(void *, uint64_t, int))(base + XRC_OFF_PAUSE_FACTORY);
    uint64_t pl = pause_factory(scene, game_model, 0);
    if (!pl) { acc_flog(@"auto-retry: pause factory returned null"); return; }
    // 暂停完成例程（= Retry 点击序列第①步；内部经 delegate 转场景清理复位）
    void (*setup)(uint64_t) = (void (*)(uint64_t))(base + XRC_OFF_PAUSE_SETUP);
    setup(pl);
    acc_flog(@"auto-retry: pause-layer retry setup done (pl=%p gm=%p)",
             (void *)pl, (void *)game_model);
}

void xrc_loop_tick(void *gameplay, uint32_t pos_ms) {
    uint32_t st = atomic_load(&s_ar_state);
    uint64_t now = xrc_real_now_us();

    if (st == XRC_AR_STATE_IDLE) {
        if (!atomic_load(&s_loop_enabled)) return;
        uint32_t b = atomic_load(&s_loop_b);
        if (pos_ms >= b && b > atomic_load(&s_loop_a) + 1000) {
            // 到 B：冻结（对齐游戏暂停语义）→ 延迟 100ms → 触发 retry
            xrc_clock_freeze_inc();
            atomic_store(&s_ar_target_a, atomic_load(&s_loop_a));
            atomic_store(&s_ar_scene_before, (uint64_t)gameplay);
            atomic_store(&s_ar_stamp_us, now);
            atomic_store(&s_ar_state, XRC_AR_STATE_FREEZE);
            acc_flog(@"loop auto-retry: freeze at %u (A=%u)", pos_ms,
                     atomic_load(&s_loop_a));
        }
        return;
    }

    if (st == XRC_AR_STATE_FREEZE) {
        if (now - atomic_load(&s_ar_stamp_us) < 100000ULL) return;
        s_ar_trigger_retry();
        atomic_store(&s_ar_stamp_us, now);
        atomic_store(&s_ar_state, XRC_AR_STATE_TRIGGER);
        return;
    }

    if (st == XRC_AR_STATE_TRIGGER) {
        uint64_t before = atomic_load(&s_ar_scene_before);
        if ((uint64_t)gameplay != before) {
            // 新场景已出现：排队 seek 回 A（pending 绑定新场景，下一帧执行），解冻
            uint32_t a = atomic_load(&s_ar_target_a);
            xrc_clock_freeze_dec();
            if (xrc_gameplay_request(XRC_OP_LOOP_REWIND, a))
                acc_flog(@"loop auto-retry: new scene -> rewind to %u", a);
            else
                acc_flog(@"loop auto-retry: rewind request rejected (a=%u)", a);
            atomic_store(&s_ar_state, XRC_AR_STATE_IDLE);
            return;
        }
        if (now - atomic_load(&s_ar_stamp_us) > 2000000ULL) {
            // 2s 超时：未出现新场景 → 解冻，退化为旧行为（等手动 retry）。
            // v8.9.6 日志显示没有暂停层上下文时"复位"被静默忽略——若这版仍超时，
            // 说明还需要真正的场景重建调用（下一步：步进 2 = delegate 全序列）。
            xrc_clock_freeze_dec();
            atomic_store(&s_ar_state, XRC_AR_STATE_IDLE);
            acc_flog(@"loop auto-retry: TIMEOUT (setup ineffective) - unfroze");
        }
    }
}

