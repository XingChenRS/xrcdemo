// XRCOMLog.m — OnlineManager 探针 + applog 强发实现。
//
// 阅读顺序建议：s_find_vptr → xrc_om_find → xrc_om_probe / xrc_om_force_applog。
// 所有偏移登记在 XRCProfile.h 的「OnlineManager 探针」段，出处见那里。
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "XRCOMLog.h"
#include "XRCProfile.h"
#include "XRCRuntime.h"
#include "XRCHook.h"
#import "XRCLog.h"

#if __has_include(<ptrauth.h>)
#  include <ptrauth.h>
#endif

// ---------------------------------------------------------------- 通用小工具
static uint64_t s_strip(uint64_t p) {
    if (!p) return 0;
#if __has_feature(ptrauth_calls)
    return (uint64_t)ptrauth_strip((void *)p, ptrauth_key_asia);
#else
    return p;
#endif
}

// 读 8 字节；地址不可读时返回 0（不做异常处理 —— 只在内核已确认可写的区域上用）。
static uint64_t s_rd64(uint64_t addr) {
    if (!addr) return 0;
    return *(const volatile uint64_t *)addr;
}

// ---------------------------------------------------------------- 单例定位
// vptr = image_base + XRC_OM_VTABLE_OFF（vtable 的地址点，= _ZTV + 0x10）。
static uint64_t s_find_vptr(void) {
    return g_xrc.image_base + XRC_OM_VTABLE_OFF;
}

// 在可写、不可执行区域里找 8 字节对齐的 vptr 值。
// 分块 vm_read（4MB）以压低峰值内存；未映射页 vm_read 会返回错误而不是崩溃。
uint64_t xrc_om_find(void) {
    uint64_t want[2] = { s_find_vptr(), s_find_vptr() - 0x10 };
    vm_address_t addr = 0;
    vm_size_t size = 0;
    natural_t depth = 0;

    while (1) {
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &addr, &size, &depth,
                                                (vm_region_info_t)&info, &cnt);
        if (kr != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }

        vm_address_t base = addr;
        vm_size_t len = size;
        addr += size;

        if (!(info.protection & VM_PROT_READ) || !(info.protection & VM_PROT_WRITE) ||
            (info.protection & VM_PROT_EXECUTE) || len < 8)
            continue;

        const vm_size_t chunk = 4u << 20;
        for (vm_size_t off = 0; off + 8 <= len; off += chunk) {
            vm_size_t want_len = len - off;
            if (want_len > chunk) want_len = chunk;

            vm_offset_t buf = 0;
            mach_msg_type_number_t got = 0;
            kr = vm_read(mach_task_self(), base + off, want_len, &buf, &got);
            if (kr != KERN_SUCCESS || !buf) continue;

            const uint64_t *p = (const uint64_t *)buf;
            size_t n = got / 8;
            for (size_t i = 0; i < n; i++) {
                if (p[i] == want[0] || p[i] == want[1]) {
                    uint64_t found = base + off + (uint64_t)i * 8;
                    vm_deallocate(mach_task_self(), buf, got);
                    return found;
                }
            }
            vm_deallocate(mach_task_self(), buf, got);
        }
    }
    return 0;
}

// ---------------------------------------------------------------- 对象读取
// libc++ std::string（24B）：byte23 的 bit0 = 短串标志。
static void s_fmt_string(uint64_t s, char *out, size_t outsz) {
    out[0] = 0;
    if (!s) return;
    uint8_t flag = *(const volatile uint8_t *)(s + 23);
    const char *data;
    size_t n;
    if (flag & 1) {                 // 短串：内容内联
        data = (const char *)s;
        n = (size_t)(flag >> 1);
    } else {                        // 长串：ptr + size
        data = (const char *)s_strip(s_rd64(s));
        n = (size_t)s_rd64(s + 8);
    }
    if (!data || n == 0 || n > 4096) { snprintf(out, outsz, "<len=%zu>", n); return; }
    size_t k = 0;
    for (size_t i = 0; i < n && k + 1 < outsz; i++) {
        unsigned char c = (unsigned char)data[i];
        out[k++] = (c >= 32 && c < 127) ? (char)c : '.';
    }
    out[k] = 0;
}

// 若 (begin,end) 像 vector<string>：元素 24B、两端都在可写区、begin<=end。
static bool s_looks_like_vec(uint64_t begin, uint64_t end) {
    if (!begin || !end || end < begin) return false;
    if ((end - begin) % 24 != 0) return false;
    if (end - begin > (16u << 20)) return false;   // 上限 16MB，防误判
    return true;
}

// ---------------------------------------------------------------- 段错误兜底
// 探针要照 begin/end 去读堆上的字符串、强发要调一个参数约定未完全验证的函数，
// 两者都可能踩到未映射地址。这套 guard 让任何一次这样的踩空只丢一次调用，
// 不把进程带走（窗口外恢复原处理器，不吞别人的崩溃）。
static sigjmp_buf       s_jb;
static _Atomic(bool)    s_guard_armed = false;
static _Atomic(int)     s_guard_hits  = 0;

static void s_guard_handler(int sig) {
    if (atomic_load(&s_guard_armed)) {
        atomic_fetch_add(&s_guard_hits, 1);
        siglongjmp(s_jb, sig);
    }
    // 不在保护窗口内：恢复默认行为，让系统按常规处理（不吞别人的崩溃）
    signal(sig, SIG_DFL);
    raise(sig);
}

static void s_guard_enter(struct sigaction *o_segv, struct sigaction *o_bus) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = s_guard_handler;
    sigemptyset(&sa.sa_mask);
    // 不开 SA_NODEFER：处理期间屏蔽同类信号，避免"处理中再故障"自身递归；
    // siglongjmp(savemask=1) 会恢复掩码。
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, o_segv);
    sigaction(SIGBUS,  &sa, o_bus);
    // **不碰 SIGTRAP**：那一份归 XRCHook 的 BRK 分发器。顶掉它 = BRK 桩失去
    // "捕获明文 + PC 重定向到重放跳板"的能力，调用点会停在 BRK 上（实测崩）。
    atomic_store(&s_guard_hits, 0);
    atomic_store(&s_guard_armed, true);
}

static void s_guard_leave(struct sigaction *o_segv, struct sigaction *o_bus) {
    atomic_store(&s_guard_armed, false);
    sigaction(SIGSEGV, o_segv, NULL);
    sigaction(SIGBUS,  o_bus,  NULL);
}

void xrc_om_probe(void) {
    uint64_t obj = xrc_om_find();
    if (!obj) {
        xrc_log(@"[om] NOT FOUND (vptr=%llx) —— 单例未定位",
                (unsigned long long)s_find_vptr());
        return;
    }
    uint64_t vptr = s_strip(s_rd64(obj));
    uint64_t vt_off = vptr ? (vptr - g_xrc.image_base) : 0;
    xrc_log(@"[om] obj=%llx vptr=%llx (off=%llx)",
            (unsigned long long)obj, (unsigned long long)vptr,
            (unsigned long long)vt_off);

    uint64_t acc   = s_rd64(obj + XRC_OM_OFF_ACC_COUNT);
    uint64_t vbeg  = s_strip(s_rd64(obj + XRC_OM_OFF_VEC_BEGIN));
    uint64_t vend  = s_strip(s_rd64(obj + XRC_OM_OFF_VEC_END));
    uint64_t vcap  = s_rd64(obj + XRC_OM_OFF_VEC_CAP);
    uint64_t pbeg  = s_strip(s_rd64(obj + XRC_APPLOG_BUF_BEGIN_OFF));
    uint64_t pend  = s_strip(s_rd64(obj + XRC_APPLOG_BUF_END_OFF));
    uint64_t uid   = s_rd64(obj + XRC_OM_OFF_USER_ID);
    uint64_t fifty = s_rd64(obj + XRC_OM_OFF_FIFTY);

    xrc_log(@"[om] +f0(acc)=%llu +f8(vec begin)=%llx +100(end)=%llx +108(cap)=%llu",
            (unsigned long long)acc, (unsigned long long)vbeg,
            (unsigned long long)vend, (unsigned long long)vcap);
    xrc_log(@"[om] +128(payload begin)=%llx +130(end)=%llx  len=%lld",
            (unsigned long long)pbeg, (unsigned long long)pend,
            (long long)((pend > pbeg) ? (pend - pbeg) : 0));
    xrc_log(@"[om] +140(user_id)=%llu +148(?)=%llu",
            (unsigned long long)uid, (unsigned long long)fifty);

    struct sigaction o1, o2;
    s_guard_enter(&o1, &o2);
    int jumped = 0;
    if ((jumped = sigsetjmp(s_jb, 1)) == 0) {
        if (s_looks_like_vec(vbeg, vend)) {
            size_t count = (size_t)((vend - vbeg) / 24);
            xrc_log(@"[om] vector<string> at %llx: %zu 条",
                    (unsigned long long)vbeg, count);
            size_t show = count > 64 ? 64 : count;
            char buf[256];
            for (size_t i = 0; i < show; i++) {
                s_fmt_string(vbeg + i * 24, buf, sizeof(buf));
                xrc_log(@"[om]   [%zu] %s", i, buf);
            }
            if (count > show) xrc_log(@"[om]   ...（其余 %zu 条省略）", count - show);
        } else {
            xrc_log(@"[om] +f8/+100 不像 vector<string>（差=%lld，除 24 余 %lld）",
                    (long long)((vend > vbeg) ? (vend - vbeg) : -1),
                    (long long)(((vend > vbeg) ? (vend - vbeg) : 0) % 24));
        }

        // 载荷若已是合法区间，直接打头几个字节（正常情况下这里应当是空的）
        if (pbeg && pend > pbeg && (pend - pbeg) < (1u << 20)) {
            size_t n = (size_t)(pend - pbeg);
            size_t show = n > 64 ? 64 : n;
            char hex[3 * 64 + 1];
            for (size_t i = 0; i < show; i++)
                snprintf(hex + i * 3, 4, "%02x ", *(const uint8_t *)(pbeg + i));
            xrc_log(@"[om] payload head: %s", hex);
        }
    }
    s_guard_leave(&o1, &o2);
    if (jumped) xrc_log(@"[om] probe: 读 %d 类信号中断（已恢复）", jumped);
}

// ---------------------------------------------------------------- 强发槽 72
// 载荷暂存：把 [obj+0x128, +0x130) 指向我们自己的已知明文，再调槽 72。
// 目的是一次拿到「已知明文 → 密文」对（明文见日志，密文在 HTTP body 与 BRK
// 捕获里），用于反解种子 codec —— 这条正是 log_blob / chart= 用的那套。
// 用 malloc 而不是静态数组：万一函数按所有权释放这段缓冲，静态区会被 free 崩。
#define XRC_KPA_LEN 256
static uint8_t *s_kpa = NULL;

static const uint8_t *s_kpa_buf(size_t *out_len) {
    if (!s_kpa) {
        s_kpa = malloc(XRC_KPA_LEN);
        if (!s_kpa) return NULL;
        // 可辨识、可复现的已知明文（纯 ASCII，便于在日志/hex 里肉眼对照）
        static const char *tag = "XRC-KPA:";
        for (size_t i = 0; i < XRC_KPA_LEN; i++)
            s_kpa[i] = (uint8_t)tag[i % 8];
    }
    *out_len = XRC_KPA_LEN;
    return s_kpa;
}

bool xrc_om_force_applog(void) {
    uint64_t obj = xrc_om_find();
    if (!obj) {
        xrc_log(@"[om] force: 单例未定位，放弃");
        return false;
    }
    uint64_t vptr = s_strip(s_rd64(obj));
    if (!vptr) { xrc_log(@"[om] force: vptr 为空"); return false; }
    uint64_t fn = s_strip(s_rd64(vptr + 8 * XRC_OM_APPLOG_SLOT));
    if (!fn) { xrc_log(@"[om] force: 槽 72 为空"); return false; }

    // X1 = 请求表单容器。0x10062522c 处 `LDR X26,[X1],#8; CMP X26,[X1+8]`
    // 是"首元素 == 尾指针"的空容器判据 —— 这里照此摆一个空区间。
    static uint8_t form[0x200];
    memset(form, 0, sizeof(form));
    *(uint64_t *)form = (uint64_t)(form + 8);

    // X2 ≠ NULL。上一版传 NULL，函数对它做 `[X2+0x18]`（崩溃报告 vmRegionInfo
    // 写的就是 "0x18 is not in any region"）。给一块全零的合法可读缓冲即可让
    // 这次解引用不炸；它是不是"回调"、零值是否被接受，由调用结果来判断。
    static uint8_t cb[0x100];
    memset(cb, 0, sizeof(cb));

    // 暂存已知明文到载荷区间（先存旧值，函数若正常返回就还回去）
    size_t kpa_len = 0;
    const uint8_t *kpa = s_kpa_buf(&kpa_len);
    uint64_t old_beg = s_rd64(obj + XRC_APPLOG_BUF_BEGIN_OFF);
    uint64_t old_end = s_rd64(obj + XRC_APPLOG_BUF_END_OFF);
    if (kpa) {
        *(uint64_t *)(obj + XRC_APPLOG_BUF_BEGIN_OFF) = (uint64_t)kpa;
        *(uint64_t *)(obj + XRC_APPLOG_BUF_END_OFF)   = (uint64_t)(kpa + kpa_len);
        xrc_log(@"[om] force: 暂存已知明文 %zu 字节 @%p（原 %llx..%llx）",
                kpa_len, kpa, (unsigned long long)old_beg, (unsigned long long)old_end);
    }

    uint32_t seq_before = xrc_brk_capture_seq();
    xrc_log(@"[om] force: obj=%llx fn(slot72)=%llx form=%p cb=%p 即将调用",
            (unsigned long long)obj, (unsigned long long)fn, form, cb);

    struct sigaction o1, o2;
    s_guard_enter(&o1, &o2);

    int jumped = 0;
    if ((jumped = sigsetjmp(s_jb, 1)) == 0) {
        ((void (*)(void *, void *, void *))fn)((void *)obj, form, cb);
    }

    s_guard_leave(&o1, &o2);

    // 只在指针仍是我们写进去的那对时才还原（函数可能已改写或释放）
    if (kpa && s_rd64(obj + XRC_APPLOG_BUF_BEGIN_OFF) == (uint64_t)kpa) {
        *(uint64_t *)(obj + XRC_APPLOG_BUF_BEGIN_OFF) = old_beg;
        *(uint64_t *)(obj + XRC_APPLOG_BUF_END_OFF)   = old_end;
    }

    uint32_t seq_after = xrc_brk_capture_seq();
    if (jumped) {
        xrc_log(@"[om] force: 调用被信号 %d 中断（兜底 %d 次，已恢复，进程无恙）",
                jumped, atomic_load(&s_guard_hits));
        return false;
    }
    xrc_log(@"[om] force: 调用返回；BRK 捕获 seq %u -> %u（%s）",
            seq_before, seq_after,
            seq_after != seq_before ? "明文已捕获" : "桩未命中或载荷区间被判无效");
    return true;
}
