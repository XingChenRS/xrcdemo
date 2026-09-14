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

#include "XRCHook.h"
#include "XRCProfile.h"
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

// ---------------- 拥有/解锁链开关（功能账 §1）----------------
// 四个"谓词桩"（层1/2/3 + 故事门）共用：开关真 → x0=1、PC=LR 直返（函数体不执行，
// 栈帧未建立，LR 直返安全）；开关假 → 不动 PC，由分发器送回重放跳板 = 原行为。
static _Atomic(bool) s_unlock_all = false;

void xrc_brk_set_unlock_all(bool on) { atomic_store(&s_unlock_all, on); }
bool xrc_brk_unlock_all(void)        { return atomic_load(&s_unlock_all); }

static void s_unlock_force_true(void *vctx) {
    if (!atomic_load(&s_unlock_all)) return;
    ucontext_t *uc = (ucontext_t *)vctx;
    if (!uc || !uc->uc_mcontext) return;
    __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    ss->__x[0] = 1;
    __darwin_arm_thread_state64_set_pc_fptr(*ss,
        (void *)__darwin_arm_thread_state64_get_lr(*ss));
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
                    __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)rp);
                }
                return;
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
    s_installed = true;
    xrc_log(@"[brk] SIGTRAP handler installed (prev=%p)", (void *)s_prev.sa_sigaction);
}

bool xrc_brk_register(uint64_t site_va, uint64_t replay_va, void (*handler)(void *)) {
    if (!site_va || !replay_va) return false;
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

// 桩表（site/replay/handler 同源 XRCProfile.h；加桩 = 这里加一行 + inject.py 同步）
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
    { "story_gate",  XRC_BRK_STORY_SITE_OFF,      XRC_BRK_STORY_REPLAY_OFF,      s_unlock_force_true },
    { "cb_ready",    XRC_BRK_CB_READY_SITE_OFF,   XRC_BRK_CB_READY_REPLAY_OFF,   s_cb_ready_true },
    { "cb_verify",   XRC_BRK_CB_VERIFY_SITE_OFF,  XRC_BRK_CB_VERIFY_REPLAY_OFF,  s_cb_skip_void },
    { "cb_dispatch", XRC_BRK_CB_DISPATCH_SITE_OFF, XRC_BRK_CB_DISPATCH_REPLAY_OFF, s_cb_skip_void },
};

void xrc_brk_setup(uint64_t image_base) {
    xrc_brk_install();
    if (!image_base) { xrc_log(@"[brk] no image base, skipping registration"); return; }
    for (size_t i = 0; i < sizeof(k_brk_entries) / sizeof(k_brk_entries[0]); i++) {
        const xrc_brk_entry_t *e = &k_brk_entries[i];
        uint64_t site   = image_base + e->site_off;
        uint64_t replay = image_base + e->replay_off;
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
    xrc_brk_capture_enable(true);
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
