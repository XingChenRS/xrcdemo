// XRCProbe.m — 运行时能力探针实现。
// 每条检查都读**运行时真实内存**（已 patch 的入口字节、vtable 槽、slot），
// 逐项打日志。这样"桩没打上/hook 没装上/转场锚点缺"都会在启动日志显式暴露。

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import "AccCommon.h"
#include "XRCProbe.h"
#include "XRCRuntime.h"
#include "XRCProfile.h"
#include "XRCGameplay.h"
#include "XRCJudge.h"

#if __has_include(<ptrauth.h>)
#  include <ptrauth.h>
#endif

xrc_caps_t g_caps = {0};

// 我方 trampoline 在入口处的 patch 编码（ADRP/ADD/BR X16）：
// 具体指令随 slide 变化，但"4 条指令特征"稳定：ADRP(0x90..) / ADD(0x91..) / BR X16(0xD61F0200)。
// 入口原本是 SUB SP,#0x30 (0xD10103FF + 变体)，被 patch 后必然不同。
static bool s_entry_patched(uint64_t entry_va) {
    if (!entry_va) return false;
    const uint32_t *w = (const uint32_t *)entry_va;
    uint32_t w0 = w[0], w1 = w[1], w2 = w[2];
    bool is_adrp = (w0 & 0x9F000000) == 0x90000000;
    bool is_add  = (w1 & 0xFF800000) == 0x91000000;
    bool is_br16 = (w2 & 0xFFFFFC1F) == 0xD61F0000 && ((w2 >> 5) & 0x1F) == 16;
    return is_adrp && is_add && is_br16;
}

// 读 vtable 槽并剥离 PAC。
static uint64_t s_vt_slot(uint64_t vtable_va, int slot) {
    if (!vtable_va) return 0;
    uint64_t raw = *(const uint64_t *)(vtable_va + 8 * slot);
#if __has_feature(ptrauth_calls)
    return (uint64_t)ptrauth_strip((void *)raw, ptrauth_key_asia);
#else
    return raw;
#endif
}

void xrc_probe_run(void) {
    memset(&g_caps, 0, sizeof(g_caps));

    // 1. 桩点存在性：入口字节特征（内联组件是否真的在）
    uint64_t entry = g_xrc.found ? g_xrc.judge_entry
                                 : (g_xrc.image_base + XRC_JUDGE_STUB_ENTRY_OFF);
    g_caps.stub_present = s_entry_patched(entry);
    acc_flog(@"[probe] stub_present=%d (entry=%llx w0=%08x)",
             g_caps.stub_present, entry,
             entry ? *(const uint32_t *)entry : 0);

    // 1b. trampoline v2 特征：v2 布局 [ADRP,ADD,LDR,CBZ,MOV X3,X6,BR,...]，
    //     判定字 = 偏移 16（word 4）== 0xAA0603E3。v1 该位置是 BR。
    {
        extern uint64_t xrc_image_base(void);
        const uint32_t *tr = (const uint32_t *)(xrc_image_base() + 0x146800CULL);
        g_caps.stub_v2 = (tr[4] == 0xAA0603E3u);
        acc_flog(@"[probe] trampoline v2=%d (tramp[4]=%08x)", g_caps.stub_v2, tr[4]);
    }

    // 2. 改判 handler 是否活：slot v2 {handler, orig, reserved}。
    //    handler == 我方注册指针且 orig == 判定核入口（native 直通时跳回原函数）。
    if (g_xrc.judge_slot) {
        const void *handler = *(const void *const *)g_xrc.judge_slot;
        uint64_t orig = *(const uint64_t *)(g_xrc.judge_slot + 8);
        g_caps.judge_handler_live = xrc_judge_is_active() && g_caps.stub_v2;
        acc_flog(@"[probe] judge slot=%llx handler_slot=%p orig_slot=%llx active=%d",
                 g_xrc.judge_slot, handler, orig, g_caps.judge_handler_live);
    } else {
        acc_flog(@"[probe] judge slot anchor missing (stub not injected?)");
    }

    // 3. gp.update vtable hook 是否装上：vtable[103] 应指向我方函数。
    uint64_t gp_slot = s_vt_slot(g_xrc.gp_vtable, 103);
    g_caps.gp_hook_live = (gp_slot != 0) && (gp_slot != g_xrc.gp_update);
    acc_flog(@"[probe] gp vtable=%llx slot103=%llx expect_orig=%llx hook_live=%d",
             g_xrc.gp_vtable, gp_slot, g_xrc.gp_update, g_caps.gp_hook_live);

    // 4. MTP getpos hook（槽 7）
    uint64_t mtp_slot = s_vt_slot(g_xrc.mtp_vtable, 7);
    g_caps.mtp_hook_live = (mtp_slot != 0) && (mtp_slot != g_xrc.mtp_getpos);
    acc_flog(@"[probe] mtp vtable=%llx slot7=%llx expect_orig=%llx hook_live=%d",
             g_xrc.mtp_vtable, mtp_slot, g_xrc.mtp_getpos, g_caps.mtp_hook_live);

    // 5. 转场可用性：槽 178 非空
    uint64_t trans = s_vt_slot(g_xrc.gp_vtable, XRC_TRANSITION_VTABLE_SLOT);
    g_caps.replay_available = (trans != 0);
    acc_flog(@"[probe] transition slot178=%llx replay_available=%d",
             trans, g_caps.replay_available);

    acc_flog(@"[probe] summary: stub=%d judge=%d gp=%d mtp=%d replay=%d",
             g_caps.stub_present, g_caps.judge_handler_live,
             g_caps.gp_hook_live, g_caps.mtp_hook_live, g_caps.replay_available);
}
