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
                uint64_t rp = atomic_load(&s_slots[i].replay);
                __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)rp);
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
    int i = atomic_load(&s_count);
    if (i >= XRC_BRK_MAX_SLOTS) return false;
    atomic_store(&s_slots[i].site, site_va);
    atomic_store(&s_slots[i].replay, replay_va);
    s_slots[i].handler = handler;
    atomic_store(&s_slots[i].hits, 0);
    atomic_store(&s_slots[i].last_us, 0);
    atomic_store(&s_count, i + 1);
    return true;
}

void xrc_brk_setup(uint64_t image_base) {
    xrc_brk_install();
    if (!image_base) { xrc_log(@"[brk] no image base, skipping registration"); return; }
    uint64_t site   = image_base + XRC_BRK_APPLOG_SITE_OFF;
    uint64_t replay = image_base + XRC_BRK_APPLOG_REPLAY_OFF;
    // 注入校验：site 处必须是 BRK #0，否则说明二进制没打桩 / 版本不符
    uint32_t insn = *(volatile uint32_t *)site;
    bool patched = (insn == 0xD4200000u);
    bool ok = xrc_brk_register(site, replay, s_applog_capture);
    xrc_brk_capture_enable(true);
    if (ok) {
        int idx = atomic_load(&s_count) - 1;
        s_slots[idx].name = "applog_send";
    }
    xrc_log(@"[brk] applog slot reg=%d site=%p(insn=%08X patched=%d) replay=%p",
            ok, (void *)site, insn, patched, (void *)replay);
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
