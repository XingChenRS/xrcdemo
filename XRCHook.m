// XRCHook.m — BRK 桩实现：SIGTRAP 分发 + 重放跳板。
//
// 注入器把 site 处的一条指令写成 `BRK #0`（D4200000）。执行到那里触发 SIGTRAP，
// 本模块的处理器按 PC 查表命中后，把 ucontext 的 PC 改成 replay 跳板地址——跳板
// 内容是「原始指令 + B 回 site+4」，于是执行流无感续上。
//
// 处理器内**只允许 async-signal-safe 操作**：查表 + 原子计数 + 改 PC。
// 任何日志/Objective-C 一律留给主线程定时器读取统计后落盘。
//
// 安全要点：查不到自己的桩点时**必须 chain 给前一个 SIGTRAP 处理器**，否则会
// 吞掉 Swift 运行时的 BRK #1 陷阱与 Crashlytics 的崩溃捕获。
// ucontext.h 在 Darwin 被标为 deprecated，需先定义 _XOPEN_SOURCE 才暴露
// ucontext_t / mcontext_t；取完立即 undef，避免影响后续 Foundation / Mach 头。
#define _XOPEN_SOURCE 700
#include <ucontext.h>
#undef _XOPEN_SOURCE

#import <Foundation/Foundation.h>

#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <mach/mach_time.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>

#include "XRCHook.h"
#include "XRCProfile.h"
#include "XRCJudge.h"   // autoplay 站点处理器复用 xrc_judge_autoplay/_pure
#import "XRCLog.h"

#if XRC_HAS_BRK_HOOK

typedef struct {
    _Atomic(uint64_t) site;
    _Atomic(uint64_t) replay;
    void (*handler)(void *);
    _Atomic(uint32_t) hits;
    _Atomic(uint64_t) last_us;   // mach_absolute_time 折算微秒
    const char *name;
} xrc_brk_slot_t;

static xrc_brk_slot_t s_slots[XRC_BRK_MAX_SLOTS];
static _Atomic(int)   s_count = 0;
static struct sigaction s_prev;
static bool s_installed = false;
// 主程序基址（分发器兜底路径用，PC 相关、不能现算）。
// 注意：必须用 xrc_image_base()（按名字扫 dyld 找 "Arc-mobile"）——
// 2026-09-15 血训：_dyld_get_image_header(0) 在越狱环境（Dopamine）下不是主程序，
// 早期注册全部落到错误地址（patched=0 + 读出路径字符串）→ 真正的 BRK 命中反而链默认 → 崩。
extern uint64_t xrc_image_base(void);
static _Atomic(uint64_t) s_main_base = 0;
// mach_timebase 在安装时算好，处理器内不做非安全调用
static uint64_t s_tb_num = 1, s_tb_den = 1;

static inline uint64_t s_now_us(void) {
    uint64_t t = mach_absolute_time();
    // ns = t * numer / denom；先乘后除保精度。timebase 不可用时退化返回原始 ticks。
    return s_tb_den ? (t * s_tb_num) / s_tb_den : t;
}

// ---------------- applog 明文捕获 ----------------
// 缓冲放在 dylib 自己的 BSS，不占栈；处理器内只 memcpy + 原子写。
static uint8_t        s_cap[XRC_BRK_CAP_MAX];
static _Atomic(size_t)   s_cap_len = 0;
static _Atomic(uint32_t) s_cap_seq = 0;
static _Atomic(bool)     s_cap_on  = false;
static uint32_t          s_cap_taken = 0;

void xrc_brk_capture_enable(bool on) { atomic_store(&s_cap_on, on); }
uint32_t xrc_brk_capture_seq(void)   { return atomic_load(&s_cap_seq); }

size_t xrc_brk_capture_take(void *buf, size_t cap) {
    uint32_t seq = atomic_load(&s_cap_seq);
    if (seq == s_cap_taken) return 0;
    s_cap_taken = seq;
    size_t n = atomic_load(&s_cap_len);
    if (!n) return 0;
    if (n > cap) n = cap;
    __builtin_memcpy(buf, s_cap, n);
    return n;
}

// applog 桩点的处理器：入口 X0 = OnlineManager，+0x128/+0x130 = 明文 begin/end。
// 必须在加密之前拿到——入口即满足。
static void s_applog_capture(void *vctx) {
    if (!atomic_load(&s_cap_on)) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    uint64_t self = uc->uc_mcontext->__ss.__x[0];
    // 轻量健全性检查：指针必须在用户空间且对齐，避免处理器内二次缺页
    if (self < 0x100000000ULL || (self & 7)) return;
    uint64_t begin = *(volatile uint64_t *)(self + XRC_APPLOG_BUF_BEGIN_OFF);
    uint64_t end   = *(volatile uint64_t *)(self + XRC_APPLOG_BUF_END_OFF);
    if (!begin || end <= begin || (begin & 7) || (end & 7)) { return; }
    uint64_t n = end - begin;
    if (n > XRC_BRK_CAP_MAX) n = XRC_BRK_CAP_MAX;
    __builtin_memcpy(s_cap, (const void *)begin, (size_t)n);
    atomic_store(&s_cap_len, (size_t)n);
    atomic_fetch_add(&s_cap_seq, 1);
}

// ---------------- log_blob 密文捕获 ----------------
// 第二个桩点（载荷加密出口）。命中时密文是栈上 SP+0x290 处的一个 libc++ std::string
// （源码位置见 XRCProfile.h 的注释）。独立缓冲，免得和入口那份明文互相覆盖。
static uint8_t        s_cap2[XRC_BRK_CAP_MAX];
static _Atomic(size_t)   s_cap2_len = 0;
static _Atomic(uint32_t) s_cap2_seq = 0;
static _Atomic(uint64_t) s_cap2_sp  = 0;
static uint32_t          s_cap2_taken = 0;

uint32_t xrc_brk_blob_seq(void) { return atomic_load(&s_cap2_seq); }
uint64_t xrc_brk_blob_sp(void)  { return atomic_load(&s_cap2_sp); }

size_t xrc_brk_blob_take(void *buf, size_t cap) {
    uint32_t seq = atomic_load(&s_cap2_seq);
    if (seq == s_cap2_taken) return 0;
    s_cap2_taken = seq;
    size_t n = atomic_load(&s_cap2_len);
    if (!n) return 0;
    if (n > cap) n = cap;
    __builtin_memcpy(buf, s_cap2, n);
    return n;
}

static void s_applog_blob_capture(void *vctx) {
    if (!atomic_load(&s_cap_on)) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    uint64_t sp = (uint64_t)__darwin_arm_thread_state64_get_sp(uc->uc_mcontext->__ss);
    if (sp < 0x100000000ULL || (sp & 7)) return;
    // 直接搬整个栈帧，不猜偏移。
    // 上一版按静态分析取 SP+0x240，抓回来是 URL 而不是 log_blob 的值 —— 说明
    // 那个槽在命中时刻还不是密文。与其继续猜，不如把帧整体带走离线搜：
    //   · URL 已知（上一版实测在 SP+0x240）
    //   · 字面量 "log_blob" 应当在帧里
    //   · 密文是高熵段，肉眼/熵值都能挑出来
    // 帧大小按 0x700 取（该函数 SUB SP,SP,#0x5A0 + 保存区，足够覆盖）。
    uint64_t n = XRC_APPLOG_BLOB_FRAME_LEN;
    __builtin_memcpy(s_cap2, (const void *)sp, (size_t)n);
    atomic_store(&s_cap2_len, (size_t)n);
    atomic_store(&s_cap2_sp, sp);
    atomic_fetch_add(&s_cap2_seq, 1);
}

// ---------------- 开关组：拥有链 + 锁态/链门（功能账 §1；v2.12 拆分）----------------
// 直返桩通用出口：写 x0 = val、PC = LR（函数体不执行、栈帧未建立，直返安全），并计数。
static _Atomic(uint32_t) s_lock_hits = 0;
uint32_t xrc_brk_lock_hits(void) { return atomic_load(&s_lock_hits); }
static void s_ret(uint64_t val, void *vctx) {
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    ss->__x[0] = val;
    __darwin_arm_thread_state64_set_pc_fptr(*ss,
        (void *)__darwin_arm_thread_state64_get_lr(*ss));
    atomic_fetch_add(&s_lock_hits, 1);
}

// 四个独立开关（原 `unlockAll` 一拆四，2026-09-19 定稿）：
//   own  → unlock_l1/l2/l3（拥有链；服务器已全授予时在线冗余，留作离线用）
//   fv   → lock_fv（FV 五曲 fast path → 五难度全解）
//   do   → lock_do（DO/konzetsu 分支 → 同上）
//   gate → fv_gate（终章链门；**1 = 放行**，决定整表是否解锁）
// 另有 chain_prog（守崩桩）**不设开关、恒生效**，见下。
static _Atomic(bool) s_unlock_own = false;
static _Atomic(bool) s_unlock_fv  = false;
static _Atomic(bool) s_unlock_do  = false;
static _Atomic(bool) s_gate_open  = false;

void xrc_brk_set_unlock_own(bool on) { atomic_store(&s_unlock_own, on); }
void xrc_brk_set_unlock_fv(bool on)  { atomic_store(&s_unlock_fv, on); }
void xrc_brk_set_unlock_do(bool on)  { atomic_store(&s_unlock_do, on); }
void xrc_brk_set_gate_open(bool on)  { atomic_store(&s_gate_open, on); }
bool xrc_brk_unlock_own(void) { return atomic_load(&s_unlock_own); }
bool xrc_brk_unlock_fv(void)  { return atomic_load(&s_unlock_fv); }
bool xrc_brk_unlock_do(void)  { return atomic_load(&s_unlock_do); }
bool xrc_brk_gate_open(void)  { return atomic_load(&s_gate_open); }

static void s_unlock_force_true(void *vctx) {     // unlock_l1/l2/l3 共用
    if (!atomic_load(&s_unlock_own)) return;
    s_ret(1, vctx);
}

// ---------------- cb 验证链开关（功能账 §3）----------------
static _Atomic(bool) s_cb_bypass = false;

void xrc_brk_set_cb_bypass(bool on) { atomic_store(&s_cb_bypass, on); }
bool xrc_brk_cb_bypass(void)        { return atomic_load(&s_cb_bypass); }

// 就绪位 getter 桩：恒真直返
static void s_cb_ready_true(void *vctx) {
    if (!atomic_load(&s_cb_bypass)) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    ss->__x[0] = 1;
    __darwin_arm_thread_state64_set_pc_fptr(*ss,
        (void *)__darwin_arm_thread_state64_get_lr(*ss));
}

// void 函数整体跳过桩（校验器 / 错码分发）：x0 不动，直接按 LR 返回
static void s_cb_skip_void(void *vctx) {
    if (!atomic_load(&s_cb_bypass)) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    __darwin_arm_thread_state64_set_pc_fptr(*ss,
        (void *)__darwin_arm_thread_state64_get_lr(*ss));
}

// ---------------- 曲目锁态覆盖（v2.6 建；v2.11 极性修正；v2.12 拆开关）----------------
// 锁状态函数 `sub_100919E5C` 内的两个专属子分支（各自唯一调用方 = 锁态函数自身）：
//   · 0x100991508 = FV 五曲 fast path（硬编码集合经 song+0x257 开关；id 改名后该路不再命中）；
//   · 0x100AAE50C = DO(konzetsu) 分支（读存档 insightPrechallengeRevealIndex；未推进时只放行 FTR/INS）。
// 二者都返回"五字节打包"的按难度解锁位（b0..b4 = PST/PRS/FTR/BYD/INS，**1 = 可玩**）→
// 直返 `0x0101010101` = 五难度全解。
// ⚠ DO 专属曲绘与 b4 的冲突（2026-09-19 实测）：`sub_10084EE7C` 里"包==konzetsu 且锁态 b4 置位
//   → 用 img/jacket_locked_konzetsu.jpg"。五字节全置 1 会让 DO 曲显示那张专属曲绘（**是曲绘、
//   不是挂锁**，可玩性不受影响）；反之让 b4=0 保普通曲绘，则 cell 的"全 1 才算解锁"判据失败 →
//   挂锁回来。二者共用 b4，**不可兼得**，现取"无挂锁 + 专属曲绘"。
static void s_lock_fv(void *vctx) {
    if (!atomic_load(&s_unlock_fv)) return;
    s_ret(0x0000000101010101ULL, vctx);
}
static void s_lock_do(void *vctx) {
    if (!atomic_load(&s_unlock_do)) return;
    s_ret(0x0000000101010101ULL, vctx);
}

// 终章链门覆盖（v2.7 建，v2.11 修正极性，v2.12 独立开关 gateOpen）：
// `sub_10099156C` 的返回语义经两处消费点钉死——
//   ① `sub_100919874`（可玩性谓词）直返它的值，消费点 sub_1008660F8 的 `CBNZ W0`（选中该难度）
//      把非零当"可用"；
//   ② `sub_100991508` 里 `if (56C & 1) → 返回全 0 字节（全锁）`，方向一致。
//   ⇒ **1 = 放行、0 = 锁**。v2.10 曾返 0 → 全曲锁死（实机事故）；入口直返 **1**。
static void s_finale_gate_open(void *vctx) {
    if (!atomic_load(&s_gate_open)) return;
    s_ret(1, vctx);
}

// 链进度覆盖（v2.10）：`sub_10098FB1C` 是 7.0 新增「链」系统的查表点——硬编码曲名（InitFunc_194 表）
//   拼 `"<名>|<难度>"` 去 mgr+0x28 容器查节点对象，而对象按 songlist 的 **id** 注册 → id 改名或
//   set 挪位即查不到 → 该函数不判空直接读 [NULL+0x28]（实测崩溃链 CA118C → 18A3A8 → 98F5BC → 98FB1C）。
//   直返 100（其自身"无场景对象"路径的合法进度值）→ 不再查表（改名/挪包安全），
//   并让链门 v19=(98FB1C==0) 恒为 0。**不设开关**：资源改名的守崩桩，必须常开。
static void s_chain_prog_neutral(void *vctx) {
    s_ret(100, vctx);
}


// ---------------- 自动演奏站点处理器（eve 全量对齐；功能账 §5.2，2026-09-18）----------------
// 全部受 xrc_judge_autoplay() 开关：关 → 处理器直接返回（不改 PC）→ 分发器送回重放跳板，
// 行为与未注入完全一致。命中时寄存器即现场（ucontext），按站点约定读 X20/X27/X28/X2 等。
// 站点语义与 eve 实件的逐条对照见 XRCProfile.h 的出处注释。
static inline uint64_t s_ap_ld64(uint64_t a) { return *(volatile uint64_t *)a; }
static inline uint32_t s_ap_ld32(uint64_t a) { return *(volatile uint32_t *)a; }
static inline uint8_t  s_ap_ld8 (uint64_t a) { return *(volatile uint8_t  *)a; }
static inline bool     s_ap_ptr_ok(uint64_t p) { return p >= 0x100000000ULL && (p & 7u) == 0; }

// 自动演奏诊断计数（v2.1；0.5s 定时器按 10s 汇总落日志，Tweak.x）。
// v2.3 语义：mark = 逐帧标志写次数，disp = 引擎标记函数（事件派发）实际调用次数（应 ≈ 音符数）。
static _Atomic(uint32_t) s_ap_stat_mark = 0, s_ap_stat_dispatch = 0;
static _Atomic(uint32_t) s_ap_stat_win_note = 0, s_ap_stat_win_tap = 0;
static _Atomic(uint32_t) s_ap_stat_tick1 = 0, s_ap_stat_tick2 = 0;
void xrc_brk_ap_stats(uint32_t out[6]) {
    out[0] = atomic_load(&s_ap_stat_mark);
    out[1] = atomic_load(&s_ap_stat_dispatch);
    out[2] = atomic_load(&s_ap_stat_win_note);
    out[3] = atomic_load(&s_ap_stat_win_tap);
    out[4] = atomic_load(&s_ap_stat_tick1);
    out[5] = atomic_load(&s_ap_stat_tick2);
}

// 谱面时刻（与判定核/判定 pass 同一公式：clock = ng+0x30）。
static int32_t s_ap_chart_now(uint64_t ng) {
    if (!s_ap_ptr_ok(ng)) return -1;
    uint64_t clk = s_ap_ld64(ng + XRC_CLOCK_IN_NOTEGROUP_OFF);
    if (!s_ap_ptr_ok(clk)) return -1;
    if (s_ap_ld8(clk + XRC_CLK_FLAG45_OFF) == 1)
        return (int32_t)((int32_t)s_ap_ld32(clk + XRC_CLK_ALT_START_OFF) -
                         (int32_t)s_ap_ld32(clk + XRC_CLK_BASE_OFF));
    int32_t cur  = (int32_t)s_ap_ld32(clk + XRC_CLK_CUR_OFF);
    int32_t base = (int32_t)s_ap_ld32(clk + XRC_CLK_BASE_OFF);
    return cur - base + (cur > 0 ? 0 : XRC_CLK_NEG_LEAD_MS);
}

// 长条/弧"被触"标记（v2.4：与 eve mark_long_note_touched 逐条对齐；出处见 XRCProfile.h）。
// 历史：v2.1 每帧重调引擎标记函数 → 事件派发 ~840/s → 音效/特效积压（真机日志定量）；
//       v2.3 拆成"逐帧标志 + 每音符一次调用"，修掉积压，但两处语义仍缺：
//         · hold 未写 note+0x30=0 / note+0xA8=1（后者 = "被接住"，引擎 sub_10091E58C 联合尾部时刻读
//           → 不写则长条/弧显示为"未接住、直接穿过判定线"）；
//         · arc 误调 hold 的标记函数（eve 对 arc 调弧消费 sub_100187620：按最近段时刻算 sprite 到期、
//           派发事件 0、调弧对象 vtable 刷新）。
// v2.4 语义：
//   守卫：active==1；弧须非 void；now >= 音符头部；now <= 尾部 +100ms；hold 还须 now >= 头部 +16ms；
//   每音符一次（门闩）：arc → sub_100187620(note, {…,+0x34=-1}, now)；hold → sub_1008E4864(note)
//                        （之后补 note+0x30 低字=0、note+0xA8=1）；
//   逐帧：note+0x64 字 = 0x0101（维持引擎 Pure tick 路径；弧另写 sprite +0x10/+0x12/+0x14）。
static _Atomic(uint64_t) s_ap_latch_ptr[256];
static _Atomic(uint32_t) s_ap_latch_t[256];

static bool s_ap_dispatch_once(uint64_t note, int32_t t0) {
    uint32_t h = (uint32_t)((note >> 4) ^ (uint64_t)(uint32_t)t0) & 255u;
    if (atomic_load(&s_ap_latch_ptr[h]) == note && atomic_load(&s_ap_latch_t[h]) == (uint32_t)t0)
        return false;
    atomic_store(&s_ap_latch_ptr[h], note);
    atomic_store(&s_ap_latch_t[h], (uint32_t)t0);
    atomic_fetch_add(&s_ap_stat_dispatch, 1);
    return true;
}

// 守卫（eve 同款）：vtable ∈ {arc,hold}、active==1、弧须非 void（note+0xA4==0）。
static void s_ap_mark_ln(uint64_t note, uint64_t ng) {
    uint64_t mb = atomic_load(&s_main_base);
    if (!mb || !s_ap_ptr_ok(note)) return;
    uint64_t vt = s_ap_ld64(note);
    bool is_arc  = (vt == mb + XRC_LN_VPTR_ARC);
    bool is_hold = (vt == mb + XRC_LN_VPTR_HOLD);
    if (!is_arc && !is_hold) return;
    if (s_ap_ld8(note + XRC_NOTE_ACTIVE_OFF) != 1) return;
    if (is_arc && s_ap_ld32(note + XRC_LN_VOID_OFF) != 0) return;   // void/trace 弧不标记
    int32_t now = s_ap_chart_now(ng);
    if (now < 0) return;
    int32_t t0  = (int32_t)s_ap_ld32(note + XRC_NOTE_TIME_OFF);
    int32_t t1  = (int32_t)s_ap_ld32(note + XRC_NOTE_TIME_END_OFF);
    if (now < t0) return;                 // 头部之前不标记（eve）
    if (now > t1 + 100) return;           // 尾部之后 +100ms 停止（eve）
    if (is_hold && now < t0 + 16) return; // hold 头部 16ms 内不标记（eve）
    // 1) 每音符一次的引擎调用（touch-begin 语义）
    if (s_ap_dispatch_once(note, t0)) {
        if (is_arc) {
            uint8_t ctx[0x40] = {0};
            *(int32_t *)(ctx + 0x34) = -1;   // 事件结构：仅 +0x34 被读（-1 = 无手指哨兵，eve 同款）
            ((void (*)(uint64_t, void *, int32_t))(mb + XRC_OFF_FN_ARC_CONSUME))(note, ctx, now);
        } else {
            ((void (*)(uint64_t))(mb + XRC_OFF_FN_MARK_HOLD))(note);
        }
    }
    // 2) hold 的"被接住"状态（eve hold 分支专属；缺它则显示未接住）
    if (is_hold) {
        *(volatile uint32_t *)(note + XRC_NOTE_HOLD_POS_OFF) = 0;
        *(volatile uint8_t  *)(note + XRC_NOTE_HELD_OFF)     = 1;
    }
    // 3) 逐帧维持"被触"（引擎每帧清；只写字段，不派发事件）
    *(volatile uint16_t *)(note + XRC_NOTE_LNSTATE_OFF) = 0x0101;
    // 4) 弧：sprite 触摸态字段（+0x10/+0x12/+0x14=now+500，eve 配方）
    if (is_arc) {
        uint64_t spr = ((uint64_t (*)(uint64_t))(mb + XRC_OFF_FN_ARC_SPRITE))(note);
        if (s_ap_ptr_ok(spr)) {
            *(volatile uint16_t *)(spr + 0x10) = 0x0101;
            *(volatile uint8_t  *)(spr + 0x12) = 1;
            *(volatile float    *)(spr + 0x14) = (float)(now + 500);
        }
    }
    atomic_fetch_add(&s_ap_stat_mark, 1);
}

// 长条触摸态读取点（命中时 X0 = 长条 note、X20 = note group）：标记后不改 PC → 重放原 LDRB。
static void s_ap_ln_state(void *vctx) {
    if (!xrc_judge_autoplay()) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    s_ap_mark_ln(ss->__x[0], ss->__x[20]);
}

// 长条判定派发前的 vtable 装载点（命中时 X27 = 长条 note）：同上（兜底标记）。
static void s_ap_ln_tick(void *vctx) {
    if (!xrc_judge_autoplay()) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    s_ap_mark_ln(ss->__x[27], ss->__x[20]);
}

// 窗口点强判（note_win / arctap_win 共用）：note = 音符寄存器、ng = X20、now = X2。
// 谱面时刻 >= note+0x1C（窗口时刻）→ 直调 commit(Pure, judge_time=窗口时刻) + fx[1]，
// PC 跳至原版汇合点；未到窗口 → 不改 PC → 重放原 CMP（NZCV 由真实执行产生，分支语义不变）。
static void s_ap_window(void *vctx, int note_reg, uint64_t cont_off, _Atomic(uint32_t) *ctr) {
    if (!xrc_judge_autoplay()) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    uint64_t note = ss->__x[note_reg];
    uint64_t ng   = ss->__x[20];
    int32_t  now  = (int32_t)ss->__x[2];
    uint64_t mb   = atomic_load(&s_main_base);
    if (!mb || !s_ap_ptr_ok(note) || !s_ap_ptr_ok(ng) || now < 0) return;
    if (s_ap_ld8(note + XRC_NOTE_ACTIVE_OFF) != 1) return;   // active（eve 同款守卫）
    int32_t t_end = (int32_t)s_ap_ld32(note + XRC_NOTE_TIME_END_OFF);
    if (t_end > now) return;   // 窗口未到：原版比较继续（重放）
    xrc_judge_autoplay_pure(ng, note, t_end);
    atomic_fetch_add(ctr, 1);
    __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)(mb + cont_off));
}

static void s_ap_note_win(void *vctx)   { s_ap_window(vctx, 28, XRC_AP_NOTE_WIN_CONT_OFF, &s_ap_stat_win_note); }
static void s_ap_arctap_win(void *vctx) { s_ap_window(vctx, 27, XRC_AP_ARCTAP_WIN_CONT_OFF, &s_ap_stat_win_tap); }

// 引擎 tick 计数（诊断；命中点 = 两个 tick 助手的返回后 MOV X26,X0，X0 = 本次 tick 数）。
// 不改 PC → 分发器重放该 MOV。用来对账"引擎自己发了多少 tick 判定"。
static void s_ap_tickcnt(void *vctx, _Atomic(uint32_t) *ctr) {
    if (!xrc_judge_autoplay()) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    int32_t n = (int32_t)uc->uc_mcontext->__ss.__x[0];
    if (n > 0) atomic_fetch_add(ctr, (uint32_t)n);
}
static void s_ap_tickcnt1(void *vctx) { s_ap_tickcnt(vctx, &s_ap_stat_tick1); }
static void s_ap_tickcnt2(void *vctx) { s_ap_tickcnt(vctx, &s_ap_stat_tick2); }

// 触摸吞掉（三个输入入口共用）：x0 = 0 并直接按 LR 返回（函数体不执行 = 触摸不进游戏逻辑）。
static void s_ap_swallow(void *vctx) {
    if (!xrc_judge_autoplay()) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    ss->__x[0] = 0;
    __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)__darwin_arm_thread_state64_get_lr(*ss));
}

// 弧线视觉（场景 tick 清态点；命中时 X0 = 弧子对象 = sub_100187618(note)、X22 = note）：
// 代执行原版两条清态（STRH/STRB）后重写"被触"值，PC 直接 +8（跳过原版 STRB）。
static void s_ap_arc_visual(void *vctx) {
    if (!xrc_judge_autoplay()) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    uint64_t mb = atomic_load(&s_main_base);
    if (!mb) return;
    uint64_t child = ss->__x[0];
    if (s_ap_ptr_ok(child)) {
        *(volatile uint16_t *)(child + 0x10) = 0;      // 原版 STRH WZR,[X0,#0x10]
        *(volatile uint8_t  *)(child + 0x12) = 0;      // 原版 STRB WZR,[X0,#0x12]
        *(volatile uint16_t *)(child + 0x10) = 0x0101; // 重写"被触"（eve on_arc_visual_clear 同款）
        *(volatile uint8_t  *)(child + 0x12) = 1;
    }
    s_ap_mark_ln(ss->__x[22], ss->__x[19]);   // X22 = 弧 note，X19 = note group（场景 tick 簇的 self）
    __darwin_arm_thread_state64_set_pc_fptr(*ss,
        (void *)(mb + XRC_BRK_AP_ARC_VISUAL_SITE_OFF + 8));
}

// 桩表（site/replay/handler 同源 XRCProfile.h；加桩 = 这里加一行 + inject.py 同步）。
// 放在分发器之前：分发器用它做"未注册兜底"（早期命中时注册可能还没跑，见
// xrc_brk_setup_early —— 2026-09-15 cb_verify 时序崩溃的修复）。
typedef struct {
    const char *name;
    uint64_t    site_off;
    uint64_t    replay_off;
    void      (*handler)(void *);
} xrc_brk_entry_t;

static const xrc_brk_entry_t k_brk_entries[] = {
    { "applog_send", XRC_BRK_APPLOG_SITE_OFF,     XRC_BRK_APPLOG_REPLAY_OFF,     s_applog_capture },
    { "applog_blob", XRC_BRK_APPLOG_BLOB_SITE_OFF, XRC_BRK_APPLOG_BLOB_REPLAY_OFF, s_applog_blob_capture },
    { "unlock_l1",   XRC_BRK_UNLOCK_L1_SITE_OFF,  XRC_BRK_UNLOCK_L1_REPLAY_OFF,  s_unlock_force_true },
    { "unlock_l2",   XRC_BRK_UNLOCK_L2_SITE_OFF,  XRC_BRK_UNLOCK_L2_REPLAY_OFF,  s_unlock_force_true },
    { "unlock_l3",   XRC_BRK_UNLOCK_L3_SITE_OFF,  XRC_BRK_UNLOCK_L3_REPLAY_OFF,  s_unlock_force_true },
    { "cb_ready",    XRC_BRK_CB_READY_SITE_OFF,   XRC_BRK_CB_READY_REPLAY_OFF,   s_cb_ready_true },
    { "cb_verify",   XRC_BRK_CB_VERIFY_SITE_OFF,  XRC_BRK_CB_VERIFY_REPLAY_OFF,  s_cb_skip_void },
    { "cb_dispatch", XRC_BRK_CB_DISPATCH_SITE_OFF, XRC_BRK_CB_DISPATCH_REPLAY_OFF, s_cb_skip_void },
    // ---- 自动演奏（eve 全量对齐；功能账 §5.2，2026-09-18 定位）----
    { "ap_ln_state",      XRC_BRK_AP_LN_STATE_SITE_OFF,     XRC_BRK_AP_LN_STATE_REPLAY_OFF,     s_ap_ln_state },
    { "ap_ln_tick",       XRC_BRK_AP_LN_TICK_SITE_OFF,      XRC_BRK_AP_LN_TICK_REPLAY_OFF,      s_ap_ln_tick },
    { "ap_note_win",      XRC_BRK_AP_NOTE_WIN_SITE_OFF,     XRC_BRK_AP_NOTE_WIN_REPLAY_OFF,     s_ap_note_win },
    { "ap_arctap_win",    XRC_BRK_AP_ARCTAP_WIN_SITE_OFF,   XRC_BRK_AP_ARCTAP_WIN_REPLAY_OFF,   s_ap_arctap_win },
    { "ap_swallow_judge", XRC_BRK_AP_SWALLOW_JUDGE_SITE_OFF, XRC_BRK_AP_SWALLOW_JUDGE_REPLAY_OFF, s_ap_swallow },
    { "ap_swallow_batch", XRC_BRK_AP_SWALLOW_BATCH_SITE_OFF, XRC_BRK_AP_SWALLOW_BATCH_REPLAY_OFF, s_ap_swallow },
    { "ap_swallow_touch", XRC_BRK_AP_SWALLOW_TOUCH_SITE_OFF, XRC_BRK_AP_SWALLOW_TOUCH_REPLAY_OFF, s_ap_swallow },
    { "ap_arc_visual",    XRC_BRK_AP_ARC_VISUAL_SITE_OFF,   XRC_BRK_AP_ARC_VISUAL_REPLAY_OFF,   s_ap_arc_visual },
    // ---- 自动演奏诊断计数（v2.1）：引擎两个 tick 助手的返回点（MOV X26,X0；只计数+重放）----
    { "ap_tickcnt1",      XRC_BRK_AP_TICKCNT1_SITE_OFF,     XRC_BRK_AP_TICKCNT1_REPLAY_OFF,     s_ap_tickcnt1 },
    { "ap_tickcnt2",      XRC_BRK_AP_TICKCNT2_SITE_OFF,     XRC_BRK_AP_TICKCNT2_REPLAY_OFF,     s_ap_tickcnt2 },
    // ---- 曲目锁态覆盖（v2.6 建 / v2.12 拆开关）+ 链守卫（v2.10）----
    { "lock_fv",          XRC_BRK_LOCK_FV_SITE_OFF,         XRC_BRK_LOCK_FV_REPLAY_OFF,         s_lock_fv },
    { "lock_do",          XRC_BRK_LOCK_DO_SITE_OFF,         XRC_BRK_LOCK_DO_REPLAY_OFF,         s_lock_do },
    { "fv_gate",          XRC_BRK_FV_GATE_SITE_OFF,         XRC_BRK_FV_GATE_REPLAY_OFF,         s_finale_gate_open },
    { "chain_prog",       XRC_BRK_CHAIN_PROG_SITE_OFF,      XRC_BRK_CHAIN_PROG_REPLAY_OFF,      s_chain_prog_neutral },
};

static void s_sigtrap(int sig, siginfo_t *info, void *vctx) {
    ucontext_t *uc = (ucontext_t *)vctx;
    if (uc && uc->uc_mcontext) {
        __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
        uint64_t pc = (uint64_t)__darwin_arm_thread_state64_get_pc(*ss);
        int n = atomic_load(&s_count);
        for (int i = 0; i < n; i++) {
            uint64_t site = atomic_load(&s_slots[i].site);
            if (site && site == pc) {
                atomic_fetch_add(&s_slots[i].hits, 1);
                atomic_store(&s_slots[i].last_us, s_now_us());
                if (s_slots[i].handler) s_slots[i].handler(vctx);
                // PC 覆写协议：handler 若自行改了 PC（直返/跳转）则尊重之；
                // 未改（仍等于 site）才送回重放跳板。直返桩依赖这条。
                uint64_t pc1 = (uint64_t)__darwin_arm_thread_state64_get_pc(*ss);
                if (pc1 == pc) {
                    uint64_t rp = atomic_load(&s_slots[i].replay);
                    // no-replay 桩（rp=0）：安全落穿（跳过该条件分支）
                    __darwin_arm_thread_state64_set_pc_fptr(*ss,
                        (void *)(rp ? rp : pc + 4));
                }
                return;
            }
        }
        // 兜底：注册表没匹配上，但 PC 命中已知桩表（早期命中，注册尚未跑）——
        // 走该桩的重放跳板（原行为）。绝不把自家的 BRK 链给默认处理器。
        uint64_t mb = atomic_load(&s_main_base);
        if (mb) {
            for (size_t k = 0; k < sizeof(k_brk_entries) / sizeof(k_brk_entries[0]); k++) {
                if (pc == mb + k_brk_entries[k].site_off) {
                    uint64_t ro = k_brk_entries[k].replay_off;
                    // no-replay 桩（ro=0）：安全落穿
                    __darwin_arm_thread_state64_set_pc_fptr(*ss,
                        (void *)(ro ? mb + ro : pc + 4));
                    return;
                }
            }
        }
    }
    // 不是我们的桩点 —— 原样交给前一个处理器（Swift trap / Crashlytics）
    if (s_prev.sa_flags & SA_SIGINFO) {
        if (s_prev.sa_sigaction) { s_prev.sa_sigaction(sig, info, vctx); return; }
    } else if (s_prev.sa_handler == SIG_IGN) {
        return;
    } else if (s_prev.sa_handler && s_prev.sa_handler != SIG_DFL) {
        s_prev.sa_handler(sig);
        return;
    }
    // SIG_DFL：恢复默认并重抛，避免在同一个 BRK 上死循环
    sigaction(SIGTRAP, &s_prev, NULL);
    raise(SIGTRAP);
}

void xrc_brk_install(void) {
    if (s_installed) return;
    mach_timebase_info_data_t tb = {0};
    if (mach_timebase_info(&tb) == KERN_SUCCESS && tb.denom) {
        s_tb_num = tb.numer; s_tb_den = tb.denom;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = s_sigtrap;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGTRAP, &sa, &s_prev) != 0) {
        xrc_log(@"[brk] sigaction(SIGTRAP) FAILED");
        return;
    }
    atomic_store(&s_main_base, xrc_image_base());
    s_installed = true;
    xrc_log(@"[brk] SIGTRAP handler installed (prev=%p, main=%p)",
            (void *)s_prev.sa_sigaction, (void *)atomic_load(&s_main_base));
}

bool xrc_brk_register(uint64_t site_va, uint64_t replay_va, void (*handler)(void *)) {
    if (!site_va) return false;   // replay_va = 0 合法（no-replay 桩：处理器自设 PC）
    int n = atomic_load(&s_count);
    // 同 site 重复注册 = 换 handler（热载插件用它替换正式版 handler 调试）
    for (int i = 0; i < n; i++) {
        if (atomic_load(&s_slots[i].site) == site_va) {
            atomic_store(&s_slots[i].replay, replay_va);
            s_slots[i].handler = handler;
            return true;
        }
    }
    if (n >= XRC_BRK_MAX_SLOTS) return false;
    atomic_store(&s_slots[n].site, site_va);
    atomic_store(&s_slots[n].replay, replay_va);
    s_slots[n].handler = handler;
    atomic_store(&s_slots[n].hits, 0);
    atomic_store(&s_slots[n].last_us, 0);
    atomic_store(&s_count, n + 1);
    return true;
}

void xrc_brk_setup(uint64_t image_base) {
    xrc_brk_install();
    if (!image_base) { xrc_log(@"[brk] no image base, skipping registration"); return; }
    for (size_t i = 0; i < sizeof(k_brk_entries) / sizeof(k_brk_entries[0]); i++) {
        const xrc_brk_entry_t *e = &k_brk_entries[i];
        uint64_t site   = image_base + e->site_off;
        uint64_t replay = e->replay_off ? image_base + e->replay_off : 0;   // 0 = no-replay 桩
        // 注入校验：site 处必须是 BRK #0，否则说明二进制没打桩 / 版本不符
        uint32_t insn = *(volatile uint32_t *)site;
        bool patched = (insn == 0xD4200000u);
        bool ok = xrc_brk_register(site, replay, e->handler);
        if (ok) {
            int idx = atomic_load(&s_count) - 1;
            // 重复注册路径（idx 不变）时找 slot：register 内部已处理，这里只补名字
            for (int k = 0; k < atomic_load(&s_count); k++) {
                if (atomic_load(&s_slots[k].site) == site) { idx = k; break; }
            }
            if (!s_slots[idx].name) s_slots[idx].name = e->name;
        }
        xrc_log(@"[brk] %s slot reg=%d site=%p(insn=%08X patched=%d) replay=%p",
                e->name, ok, (void *)site, insn, patched, (void *)replay);
    }
    // 配对标记 ①：自动演奏站点（ap_*）由本 dylib 处理；旧 dylib 无此表 → 注入脚本拒配。
    xrc_log(@"[brk] autoplay-eve v1 ready (v2.12 mark=arc-consume/hold-held + lock/finale-gate(1=放行) + chain-guard; autoplay=%d)", (int)xrc_judge_autoplay());
    // 配对标记 ②：链进度覆盖桩（chain_prog，7.0 新增「链」系统的查表点）由本 dylib 处理；
    // 旧 dylib 命中该站点会重放原指令 → 崩因依旧，注入脚本据此拒配。此桩**不设开关、恒生效**。
    xrc_log(@"[brk] chain-guard v1 ready (chain_prog -> 100, always-on)");
    // v2.12 开关组（原 unlockAll 一拆四；策略/plist 驱动）
    xrc_log(@"[brk] switches: own=%d fv=%d do=%d gate=%d (slots=%d)",
            (int)atomic_load(&s_unlock_own), (int)atomic_load(&s_unlock_fv),
            (int)atomic_load(&s_unlock_do),  (int)atomic_load(&s_gate_open),
            atomic_load(&s_count));
    xrc_brk_capture_enable(true);
}

void xrc_brk_setup_early(void) {
    // 在 %ctor 里调用：安装处理器 + 立即注册全部桩点。
    // 2026-09-15 时序教训：cb 校验在 didFinishLaunching 前 ~0.5s 就有后台线程命中，
    // 当时注册还挂在 didFinishLaunching（doBootstrap），分发器空表 → 链给默认处理器
    // → EXC_BREAKPOINT 秒崩。注册与处理器安装必须同刻。
    xrc_brk_install();   // 幂等
    uint64_t mb = atomic_load(&s_main_base);
    if (mb) xrc_brk_setup(mb);
}

uint32_t xrc_brk_hits(int slot_index) {
    if (slot_index < 0 || slot_index >= atomic_load(&s_count)) return 0;
    return atomic_load(&s_slots[slot_index].hits);
}

int xrc_brk_slot_count(void) { return atomic_load(&s_count); }

const char *xrc_brk_slot_name(int slot_index) {
    if (slot_index < 0 || slot_index >= atomic_load(&s_count)) return "?";
    return s_slots[slot_index].name ? s_slots[slot_index].name : "?";
}

uint64_t xrc_brk_last_hit_us(int slot_index) {
    if (slot_index < 0 || slot_index >= atomic_load(&s_count)) return 0;
    return atomic_load(&s_slots[slot_index].last_us);
}

#endif  // XRC_HAS_BRK_HOOK
