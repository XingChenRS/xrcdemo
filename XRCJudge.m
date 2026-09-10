// XRCJudge.m — 改判：slot 注册 + 完全接管 handler。
// 完全接管 sub_1009D9ED8（7.0.255，ABI 已确认：X0=note，X8=out，无 sret）。
// 逻辑版本无关：note 字段偏移从 XRCProfile.h 读取。
// TODO(v1.1)：窗口值语义按表 B 消费格式完成（replay-chain 笔记 §9 待解码后实现）。

#import <Foundation/Foundation.h>
#import "AccCommon.h"    // acc_flog
#include <sys/mman.h>     // mprotect（CMP 站点改写）
#include <errno.h>
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
// ---- 改判 handler（CMP 立即数改写策略，2026-09-10 架构切换）----
// 背景：完全接管 sub_10091E684 需要精确复刻 6 条出口路径（Pure/Far/Lost 的
// commit+fx、长条 commit_ln+fx、Miss），漏一条即出 bug（真机教训）。
//
// 新策略（用户提出，更稳）：**不接管函数，只改它的 8 个 CMP 立即数**。
//   分支 B（分段钟）：0x10091e720(Pure) / e728(Far) / e730(Lost) / e738(上界)
//   分支 A（普通钟）：0x10091e788(Pure) / e7cc(Far) / e810(Lost) / e848(上界)
// handler 每次被调用时按需重写（只在配置变化时写），随后**直通原函数**
// （X0/X1/X2 未动，原逻辑零复刻）。
//
// 写 __TEXT 需要绕过页签名：mprotect 到 RW 产生 COW 匿名页（旁路签名）。
// 失败则降级为直通（仅日志），不影响游戏。
#if XRC_HAS_JUDGE_STUB
extern uint64_t xrc_image_base(void);   // Tweak.x 提供
static _Atomic(float) s_window_scale = 1.0f;

// 原函数入口（长条回退/直通用）。槽的 native 重放区 = 静态地址，需按 slide 重定位。
static uint64_t (*s_orig_judge)(uint64_t note_group, uint64_t note, int64_t ts) = NULL;

// 8 个 CMP 站点的静态偏移（相对 image base）
static const uint64_t s_cmp_sites[8] = {
    XRC_CMP_B_PURE, XRC_CMP_B_FAR, XRC_CMP_B_LOST, XRC_CMP_B_MISS,
    XRC_CMP_A_PURE, XRC_CMP_A_FAR, XRC_CMP_A_LOST, XRC_CMP_A_MISS,
};
// 上次写入的阈值（避免重复 patch）
static _Atomic(int) s_applied[8] = {0,0,0,0,0,0,0,0};
static _Atomic(bool) s_patch_ok = false;
static _Atomic(bool) s_patch_tried = false;

// 配置阈值（ms）——UI 四档写入（顺序：Pure/Far/Lost/Miss）
static _Atomic(int) s_th[4] = {25, 50, 100, 120};
static _Atomic(uint32_t) s_call_total = 0;

// 把一个 CMP Wn,#imm12 指令字改成新的 imm12（保留 Rn 与指令形态）
static inline uint32_t s_remake_cmp(uint32_t orig, int imm) {
    if (imm < 0) imm = 0;
    if (imm > 0xFFF) imm = 0xFFF;          // imm12 上限
    return (orig & ~(0xFFFu << 10)) | ((uint32_t)imm << 10);
}

// 把 8 个站点写成配置值（返回成功数）。仅在值变化时实际写。
static int s_apply_thresholds(uint64_t image_base) {
    int pure = atomic_load(&s_th[0]);
    int far  = atomic_load(&s_th[1]);
    int lost = atomic_load(&s_th[2]);
    int miss = atomic_load(&s_th[3]);
    int want[8] = {pure, far, lost, miss,   // 分支 B
                   pure, far, lost, miss};  // 分支 A

    int written = 0;
    for (int i = 0; i < 8; i++) {
        int cur = atomic_load(&s_applied[i]);
        if (cur == want[i]) continue;
        uint64_t site = image_base + s_cmp_sites[i];
        uintptr_t page = site & ~(uintptr_t)0x3FFF;
        // 临时开写（COW 匿名页，绕过页签名）
        if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE) != 0) {
            if (!atomic_load(&s_patch_tried))
                acc_flog(@"[judge] mprotect FAILED at %llx (errno=%d) — 改判不可用",
                         site, errno);
            return -1;
        }
        uint32_t *p = (uint32_t *)site;
        uint32_t orig = *p;
        *p = s_remake_cmp(orig, want[i]);
        __builtin___clear_cache((char *)site, (char *)(site + 4));
        mprotect((void *)page, 0x4000, PROT_READ | PROT_EXEC);
        atomic_store(&s_applied[i], want[i]);
        written++;
    }
    return written;
}

// 判定 handler：**不接管**——只在阈值变化时改写 8 个 CMP，然后直通原函数。
// X0/X1/X2 原样保留（trampoline 的 BR 不碰它们）。
static uint64_t s_xrc_judge_handler(uint64_t note_group, uint64_t note, int64_t ts) {
    uint32_t n = atomic_fetch_add(&s_call_total, 1);

    if (!atomic_load(&s_patch_tried)) {
        atomic_store(&s_patch_tried, true);
        extern uint64_t xrc_image_base(void);
        int w = s_apply_thresholds(xrc_image_base());
        atomic_store(&s_patch_ok, w >= 0);
        if (n < 6)
            acc_flog(@"[judge] CMP patch applied: %d sites (ok=%d) th=%d/%d/%d/%d",
                     w, atomic_load(&s_patch_ok),
                     atomic_load(&s_th[0]), atomic_load(&s_th[1]),
                     atomic_load(&s_th[2]), atomic_load(&s_th[3]));
    } else if (n < 12) {
        acc_flog(@"[judge] call#%u (passthrough, patched=%d)", n, atomic_load(&s_patch_ok));
    }
    return s_orig_judge ? s_orig_judge(note_group, note, ts) : 0;
}

// 阈值更新（UI 调用）——标脏，下次判定时写入
void xrc_judge_apply_thresholds(void) {
    extern uint64_t xrc_image_base(void);
    // 重置 applied 以强制重写
    for (int i = 0; i < 8; i++) atomic_store(&s_applied[i], 0x7FFFFFFF);
    atomic_store(&s_patch_ok, s_apply_thresholds(xrc_image_base()) >= 0);
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
    // 原函数入口：跳过 handler 分派，直接进 trampoline 的 native 重放区
    // （ADRP/ADD/LDR/CBZ/BR 之后的 3 条重放指令 —— 见 XRCProfile 布局注释）
    s_orig_judge = (uint64_t (*)(uint64_t, uint64_t, int64_t))
                   (image_base + XRC_STUB_TRAMP_NATIVE_OFF);
    // 完全接管：写 handler 指针即接管；写 0 即原生直通（trampoline 保证）。
    slot->handler = (void *)&s_xrc_judge_handler;
    atomic_store(&s_judge_active, true);
    acc_flog(@"judge handler installed at slot %p (native=%p)", (void *)slot, (void *)s_orig_judge);
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
#if XRC_HAS_JUDGE_STUB
    // 新架构：UI 四档语义映射到判定级联
    //   Max  → Pure 上界（原 25）
    //   Pure → Far  上界（原 50）
    //   Far  → Lost 上界（原 100）
    //   Lost → 上界/Miss 分界（原 120）
    atomic_store(&s_th[0], max_ms);
    atomic_store(&s_th[1], pure_ms);
    atomic_store(&s_th[2], far_ms);
    atomic_store(&s_th[3], lost_ms);
    // 立即生效（改写 8 个 CMP）
    xrc_judge_apply_thresholds();
#endif
}

void xrc_judge_get_windows(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms) {
    if (max_ms)  *max_ms  = atomic_load(&s_win_max);
    if (pure_ms) *pure_ms = atomic_load(&s_win_pure);
    if (far_ms)  *far_ms  = atomic_load(&s_win_far);
    if (lost_ms) *lost_ms = atomic_load(&s_win_lost);
}
