// XRCRuntime.m — 运行时锚点发现。
// 机制：注入器在 __DATA 零填充区写 xrc_info blob（magic XRC1）。
// dyld 不 rebase 零填充区（不在 rebase 列表），blob 里的静态偏移原样保留；
// dylib 用 image_base 手动重定位。容错：编译期 profile 偏移 fallback。

#import <Foundation/Foundation.h>
#import "AccCommon.h"    // acc_flog
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include "XRCRuntime.h"
#include "XRCProfile.h"
#include "xrc_abi.h"

xrc_runtime_t g_xrc = {0};

// 读主程序 __DATA 段的运行时 vm 范围（扫描边界，防止读到 perm=0 页）。
// 注意：dyld 不改内存里的 load commands——segment vmaddr 仍是未 slide 的
// 静态值，必须手动加 (base - 静态基址 0x100000000)。
static bool s_data_segment_range(uint64_t image_base, uint64_t *start, uint64_t *end) {
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)image_base;
    if (hdr->magic != MH_MAGIC_64) return false;
    const uint64_t slide = image_base - 0x100000000ULL;
    const struct load_command *lc = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__DATA") == 0) {
                *start = seg->vmaddr + slide;
                *end = seg->vmaddr + slide + seg->vmsize;
                return true;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return false;
}

// 在 [start, end) 扫描 magic（8 字节对齐）。接受 v1/v2 blob（字段前缀兼容）。
static const struct xrc_info *s_scan_info(uint64_t start, uint64_t end) {
    for (uint64_t a = start; a + sizeof(struct xrc_info) <= end; a += 8) {
        const struct xrc_info *info = (const struct xrc_info *)a;
        if (info->magic == XRC_MAGIC && info->version >= 1 && info->version <= XRC_INFO_VERSION)
            return info;
    }
    return NULL;
}

xrc_runtime_t xrc_runtime_discover(void) {
    extern uint64_t xrc_image_base(void);
    uint64_t base = xrc_image_base();
    xrc_runtime_t r = {0};
    r.image_base = base;
    if (!base) return r;

    uint64_t data_start = 0, data_end = 0;
    if (!s_data_segment_range(base, &data_start, &data_end)) {
        acc_flog(@"runtime discover: __DATA segment not found");
        return r;
    }

    // 诊断日志（下次真机日志直接暴露布局事实）
    acc_flog(@"runtime discover: base=%llx DATA=[%llx,%llx) expect=%llx",
             base, data_start, data_end, base + XRC_INFO_OFF);

    // 扫描范围限定 __DATA 段内（预期位置前后截断到段边界）
    uint64_t expect = base + XRC_INFO_OFF;
    uint64_t scan_start = expect > data_start + (1u << 20) ? expect - (1u << 20) : data_start;
    uint64_t scan_end   = expect + (1u << 20);
    if (scan_end > data_end) scan_end = data_end;
    if (expect >= data_start && expect + 16 <= data_end) {
        const uint8_t *p = (const uint8_t *)expect;
        acc_flog(@"runtime discover: expect 16B = %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
                 p[0],p[1],p[2],p[3], p[4],p[5],p[6],p[7],
                 p[8],p[9],p[10],p[11], p[12],p[13],p[14],p[15]);
    }
    const struct xrc_info *info = s_scan_info(scan_start, scan_end);
    if (info) {
        r.found = true;
        r.judge_entry = base + info->judge_entry_off;
        r.judge_slot  = base + info->judge_slot_off;
        r.gp_vtable   = base + info->gp_vtable_off;
        r.gp_update   = base + info->gp_update_off;
        r.mtp_vtable  = base + info->mtp_vtable_off;
        r.mtp_getpos  = base + info->mtp_getpos_off;
        acc_flog(@"runtime info found: judge=%llx slot=%llx gpvt=%llx gpup=%llx mtpvt=%llx mtpgp=%llx",
                 r.judge_entry, r.judge_slot, r.gp_vtable, r.gp_update,
                 r.mtp_vtable, r.mtp_getpos);
        return r;
    }

    // fallback：编译期 profile 偏移
    acc_flog(@"runtime info NOT found — falling back to compile-time profile");
    r.judge_entry = base + XRC_JUDGE_STUB_ENTRY_OFF;
    r.judge_slot  = base + XRC_JUDGE_SLOT_OFF;
    r.gp_vtable   = base + XRC_OFF_GP_VTABLE;
    r.gp_update   = base + XRC_OFF_GP_UPDATE_FN;
    r.mtp_vtable  = base + XRC_OFF_MTP_VTABLE;
    r.mtp_getpos  = base + XRC_OFF_MTP_GETPOS;
    return r;
}
