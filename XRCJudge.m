// XRCJudge.m — 改判：slot 注册 + 完全接管 handler。
// 完全接管 sub_1009D9ED8（7.0.255，ABI 已确认：X0=note，X8=out，无 sret）。
// 逻辑版本无关：note 字段偏移从 XRCProfile.h 读取。
// TODO(v1.1)：窗口值语义按表 B 消费格式完成（replay-chain 笔记 §9 待解码后实现）。

#import <Foundation/Foundation.h>
#import "AccCommon.h"    // acc_flog
#include "XRCJudge.h"
#include "XRCProfile.h"
#include "XRCRuntime.h"
#include "xrc_abi.h"

static _Atomic(int) s_win_max  = 25;
static _Atomic(int) s_win_pure = 50;
static _Atomic(int) s_win_far  = 100;
static _Atomic(int) s_win_lost = 120;

// ---- 完全接管 handler（X0=note, X8=out）----
// 7.0.255 窗口求值器输出语义（IDA 已确认）：*out = 单个 f32 窗口值（ms），
// caller 把它加到特效时间基上（sub_100BB5508 L115 vadd_f32）。
// handler 采用"缩放"路线：调原函数拿基准窗口 → 乘用户缩放 → 写回。
// 无需复刻表 B（note 类型分派原函数自己做）。
// ---- 改判 handler（完全接管 sub_10091E684）----
// 判定函数语义（IDA 完整读出，两分支同构于 6.13 sub_100870FD0）：
//   B 分支（谱面钟 [clk+45]==1）：delta = |note_time - (clk32 - clk40)|
//   A 分支（普通钟）：delta = |note_time - clk52 + clk40 + (clk52<=0 ? -3000 : 0)|
//   级联（默认值）：delta < 26 → Pure(0)；< 51 → Far(1)；< 101 → Lost(2)；
//                   < 121 → Lost(3, 长条专用)；>= 121 → return 0（Miss，不消费）
//   落账：sub_100ACB880(note_group+56, note, grade, early/late)
//   返回：1 = 本次消费该 note；0 = 未消费（Miss）
//
// handler 完全接管：用**可配置阈值**复刻同一级联。阈值来自 UI 四档
// （Max/Pure/Far/Lost → 对应 25/50/100/120 附近），实现真正的动态改判。
#if XRC_HAS_JUDGE_STUB
// 原函数入口（未使用——完全接管；保留作回退开关）
static uint64_t (*s_orig_judge)(uint64_t note, void *out) = NULL;
static _Atomic(float) s_window_scale = 1.0f;

// 可配置阈值（ms）——UI 四档写入
static _Atomic(int) s_th_pure = 25;
static _Atomic(int) s_th_far  = 50;
static _Atomic(int) s_th_lost = 100;
static _Atomic(int) s_th_miss = 120;

// note 字段偏移（profile）
#define XRC_NOTE_TIME_OFF     24
// 谱面钟偏移
#define XRC_CLK_FLAG45        45
#define XRC_CLK_ALT_START     32
#define XRC_CLK_BASE          40
#define XRC_CLK_CUR           52

static _Atomic(uint32_t) s_call_total = 0;

// 落账函数（note_group+56 的对象，grade, dir）—— 与原函数一致地调用
typedef void (*commit_fn)(uint64_t, uint64_t, int, int);
static commit_fn s_commit = NULL;

// 判定 handler：X0 = note_group, X1 = note（见 sub_10091E684 签名 a1=note_group, a2=note）
static uint64_t s_xrc_judge_handler(uint64_t note_group, uint64_t note) {
    uint32_t n = atomic_fetch_add(&s_call_total, 1);
    if (n == 0 || n % 1000 == 0) {
        acc_flog(@"[judge] call#%u note_group=%llx note=%llx", n, note_group, note);
    }
    if (!note_group || !note) return 0;

    // 读谱面钟
    uint64_t clk = *(uint64_t *)(note_group + 48);
    if (!clk) return 0;
    int32_t note_time = *(int32_t *)(note + XRC_NOTE_TIME_OFF);

    int32_t delta, dir;
    if (*(uint8_t *)(clk + XRC_CLK_FLAG45) & 1) {
        int32_t v8 = *(int32_t *)(clk + XRC_CLK_ALT_START);
        int32_t v9 = *(int32_t *)(clk + XRC_CLK_BASE);
        delta = note_time - v8 + v9;
        dir = ((v8 - v9) < note_time) ? 1 : 2;
    } else {
        int32_t v13 = *(int32_t *)(clk + XRC_CLK_CUR);
        int32_t v15 = *(int32_t *)(clk + XRC_CLK_BASE);
        int32_t off = (v13 <= 0) ? 3000 : 0;
        delta = note_time - v13 + v15 + off;
        dir = ((v13 - v15 + (v13 <= 0 ? -3000 : 0)) < note_time) ? 1 : 2;
    }
    if (delta < 0) delta = -delta;

    // 配置阈值级联（动态改判核心）
    int th_pure = atomic_load(&s_th_pure);
    int th_far  = atomic_load(&s_th_far);
    int th_lost = atomic_load(&s_th_lost);
    int th_miss = atomic_load(&s_th_miss);

    int grade;
    if (delta <= th_pure)      grade = 0;   // Pure
    else if (delta <= th_far)  grade = 1;   // Far
    else if (delta <= th_lost) grade = 2;   // Lost
    else if (delta <= th_miss) grade = 3;   // Lost(长条)
    else {
        if (n < 5) acc_flog(@"[judge] miss: delta=%d note_time=%d", delta, note_time);
        return 0;                            // Miss（不消费）——与原函数一致
    }

    if (n < 5) {
        acc_flog(@"[judge] grade=%d delta=%d th=%d/%d/%d/%d",
                 grade, delta, th_pure, th_far, th_lost, th_miss);
    }

    // 落账（与原函数相同的调用）
    if (s_commit)
        s_commit(*(uint64_t *)(note_group + 56), note, grade, dir);
    return 1;   // 消费该 note
}
#endif

// 窗口缩放（由配置四档换算：scale = (max+pure+far+lost)/270.0，默认 25/50/100/120）
void xrc_judge_set_scale(float scale) {
    if (scale < 0.1f) scale = 0.1f;
    if (scale > 5.0f) scale = 5.0f;
    atomic_store(&s_window_scale, scale);
}

float xrc_judge_get_scale(void) {
    return atomic_load(&s_window_scale);
}

static _Atomic(bool) s_judge_active = false;

bool xrc_judge_is_active(void) {
    return atomic_load(&s_judge_active);
}

bool xrc_judge_install(uint64_t image_base) {
#if XRC_HAS_JUDGE_STUB
    uint64_t slot_va = g_xrc.judge_slot;
    if (!slot_va) {
        acc_flog(@"judge stub: slot anchor missing (stub not injected?)");
        return false;
    }
    struct xrc_slot *slot = (struct xrc_slot *)slot_va;
    // 落账函数：判定函数内 sub_100ACB880（7.0.255）
    s_commit = (commit_fn)(image_base + XRC_OFF_JUDGE_COMMIT_FN);
    // 完全接管：写 handler 指针即接管；写 0 即原生直通（trampoline 保证）。
    slot->handler = (void *)&s_xrc_judge_handler;
    atomic_store(&s_judge_active, true);
    acc_flog(@"judge handler installed at slot %p (commit=%p)", (void *)slot, (void *)s_commit);
    return true;
#else
    (void)image_base;
    return false;
#endif
}

void xrc_judge_set_windows(int max_ms, int pure_ms, int far_ms, int lost_ms) {
    atomic_store(&s_win_max,  max_ms);
    atomic_store(&s_win_pure, pure_ms);
    atomic_store(&s_win_far,  far_ms);
    atomic_store(&s_win_lost, lost_ms);
    // 直通 handler 阈值：Pure/Far/Lost/Miss（UI 四档 → 判定级联）
    atomic_store(&s_th_pure, max_ms);
    atomic_store(&s_th_far,  pure_ms);
    atomic_store(&s_th_lost, far_ms);
    atomic_store(&s_th_miss, lost_ms);
}

void xrc_judge_get_windows(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms) {
    if (max_ms)  *max_ms  = atomic_load(&s_win_max);
    if (pure_ms) *pure_ms = atomic_load(&s_win_pure);
    if (far_ms)  *far_ms  = atomic_load(&s_win_far);
    if (lost_ms) *lost_ms = atomic_load(&s_win_lost);
}
