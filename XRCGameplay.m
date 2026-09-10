// XRCGameplay.m — gp.update hook + 谱面钟 retime + seek + 转场重放。
// 6.13 已验证语义迁入；7.0 转场骨架（XRC_HAS_TRANSITION 分支）。

#import <Foundation/Foundation.h>
#import "AccCommon.h"    // acc_flog
#include <limits.h>
#include <sys/mman.h>
#include <errno.h>
#include <mach/vm_map.h>
#include <mach/mach_init.h>
#include "XRCGameplay.h"
#include "XRCRuntime.h"
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
// 场景代数：转场后新场景 +1160 等字段变化 → 通过 self 指针变化检测场景切换，
// 旧场景的 pending 请求自动作废（指针不同）。
static _Atomic(uint32_t) s_pending_op    = XRC_OP_NONE;
static _Atomic(uint32_t) s_pending_ms    = 0;
static _Atomic(uint64_t) s_last_exec_us  = 0;   // 冷却起点（真实时间 us）
static _Atomic(uint64_t) s_exec_gen      = 0;   // 执行代（防同帧重复）
#define XRC_OP_COOLDOWN_US  (1500 * 1000ULL)    // 转场/seek 冷却 1.5s
#define XRC_OP_MAX_IDLE_US  (4000 * 1000ULL)    // 请求超过 4s 未执行 → 丢弃

bool xrc_gameplay_request(xrc_op_t op, uint32_t param_ms) {
    uint32_t cur = atomic_load(&s_pending_op);
    if (cur != XRC_OP_NONE) {
        acc_flog(@"request rejected: pending op=%u", cur);
        return false;
    }
    atomic_store(&s_pending_ms, param_ms);
    atomic_store(&s_pending_op, op);
    return true;
}

xrc_op_t xrc_gameplay_pending_op(void) {
    return (xrc_op_t)atomic_load(&s_pending_op);
}

// 请求到期清理（避免卡死状态机）
static void s_pending_expire_if_stale(uint64_t now_us) {
    uint64_t req_time = atomic_load(&s_last_exec_us);
    if (req_time && now_us - req_time > XRC_OP_MAX_IDLE_US) {
        atomic_store(&s_pending_op, XRC_OP_NONE);
    }
}

// 在游戏循环内执行 pending（self = 当前活场景）。
static void s_exec_pending(void *self) {
    uint32_t op = atomic_load(&s_pending_op);
    if (op == XRC_OP_NONE) return;

    uint64_t now = xrc_real_now_us();
    uint64_t last = atomic_load(&s_last_exec_us);
    if (last && now - last < XRC_OP_COOLDOWN_US) return;  // 冷却中
    s_pending_expire_if_stale(now);

    uint32_t ms = atomic_load(&s_pending_ms);
    atomic_store(&s_pending_op, XRC_OP_NONE);   // 先清（防止执行内重入）
    atomic_store(&s_last_exec_us, now);
    atomic_fetch_add(&s_exec_gen, 1);

    if (op == XRC_OP_SEEK || op == XRC_OP_SEEK_REPLAY) {
        // 音频 seek + 谱面钟平移（纯数据操作，安全）
        void *player = xrc_player_get();
        if (player) {
            xrc_clock_freeze_inc();
            xrc_player_seek_ms(player, ms);
            xrc_clock_freeze_dec();
        }
        void *note_group = *(void **)((char *)self + XRC_GP_NOTEGROUP_OFF);
        int32_t cur_ms = xrc_chart_clock_ms(note_group);
        if (cur_ms >= -3000) {
            void *clk = note_group ? *(void **)((char *)note_group + XRC_CLOCK_IN_NOTEGROUP_OFF) : NULL;
            if (clk) {
                int32_t *base_off = (int32_t *)((char *)clk + XRC_CLK_BASE_OFF);
                *base_off += cur_ms - (int32_t)ms;
            }
        }
        s_gp_last_real_us = 0;
        acc_flog(@"seek executed: ms=%u (cur was %d)", ms, cur_ms);
    }

#if XRC_HAS_TRANSITION
    if (op == XRC_OP_SEEK_REPLAY || op == XRC_OP_LOOP_REWIND) {
        // 转场重开：谱面钟已平移到目标（上面 seek 已做），带进度转场
        if (xrc_transition_resume(self, true))
            acc_flog(@"transition resume executed (op=%u, ms=%u)", op, ms);
        else
            acc_flog(@"transition resume FAILED (op=%u)", op);
    }
#endif
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
#if XRC_HAS_TRANSITION
            int32_t pos = xrc_chart_clock_ms(note_group);
            if (pos > 0) xrc_loop_tick(self, (uint32_t)pos);
#endif
        }
        s_exec_pending(self);   // deferred 操作（seek/转场）在活场景循环内执行
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

#pragma mark - 循环/转场状态（分 profile）

#if XRC_HAS_TRANSITION
typedef void (*transition_fn)(void *scene, int resume);

static _Atomic(bool) s_loop_enabled = false;
static _Atomic(uint32_t) s_loop_a = 0;
static _Atomic(uint32_t) s_loop_b = 0;

bool xrc_transition_resume(void *gameplay, bool resume) {
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
}

bool xrc_loop_get_enabled(void) { return atomic_load(&s_loop_enabled); }
void xrc_loop_set_range(uint32_t a_ms, uint32_t b_ms) {
    // ArcCreate 夹取语义：To >= From + 1000；非法值视为关闭
    if (b_ms <= a_ms + 1000) {
        atomic_store(&s_loop_a, 0);
        atomic_store(&s_loop_b, 0);
        atomic_store(&s_loop_enabled, false);
        return;
    }
    atomic_store(&s_loop_a, a_ms);
    atomic_store(&s_loop_b, b_ms);
    atomic_store(&s_loop_enabled, true);
}
void xrc_loop_get_range(uint32_t *from_ms, uint32_t *to_ms) {
    if (from_ms) *from_ms = atomic_load(&s_loop_a);
    if (to_ms)   *to_ms   = atomic_load(&s_loop_b);
}
void xrc_loop_tick(void *gameplay, uint32_t pos_ms) {
    if (!atomic_load(&s_loop_enabled)) return;
    if (pos_ms >= atomic_load(&s_loop_b)) {
        // 循环回到 A：deferred 执行（复用状态机，保证在活场景内跑）
        xrc_gameplay_request(XRC_OP_LOOP_REWIND, atomic_load(&s_loop_a));
    }
}
#else
bool xrc_transition_resume(void *gameplay, bool resume) { return false; }
bool xrc_loop_get_enabled(void) { return false; }
void xrc_loop_set_range(uint32_t from_ms, uint32_t to_ms) {}
void xrc_loop_get_range(uint32_t *from_ms, uint32_t *to_ms) {
    if (from_ms) *from_ms = 0;
    if (to_ms)   *to_ms   = 0;
}
void xrc_loop_tick(void *gameplay, uint32_t pos_ms) {}
#endif

