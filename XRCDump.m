// XRCDump.m — 进程内内存转储实现。
//
// 为什么不用调试器：debugserver 附加需要 task_for_pid 权限，在这个环境里反复把
// 目标进程带崩（三次真机确认）。而本代码跑在目标进程内部，读自己的地址空间不
// 需要任何特权，也不会把进程弄崩。
//
// 只转储**可写**区域（VM_PROT_WRITE）——累积的对局数据、堆对象都在这里；
// 只读段（__TEXT、共享缓存）对这个用途没有价值，且体积巨大。
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/vm_region.h>
#include <stdatomic.h>
#include <string.h>

#include "XRCDump.h"
#import "XRCLog.h"

static _Atomic(bool) s_running = false;
static _Atomic(int)  s_done = 0;
static _Atomic(int)  s_total = 0;
static _Atomic(unsigned long long) s_bytes = 0;

// 单个区域上限 64MB（异常大的映射多为图形缓冲，对分析无益）
#define XRC_DUMP_REGION_MAX (64ULL << 20)
// 总量上限 256MB —— 够覆盖堆上的对局数据，又不至于写爆设备存储
#define XRC_DUMP_TOTAL_MAX  (256ULL << 20)

bool xrc_dump_running(void) { return atomic_load(&s_running); }
int  xrc_dump_regions_done(void) { return atomic_load(&s_done); }
int  xrc_dump_regions_total(void) { return atomic_load(&s_total); }
unsigned long long xrc_dump_bytes_written(void) { return atomic_load(&s_bytes); }

static NSString *s_dump_dir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"xrcdemo-net/mem"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static void s_dump_worker(void) {
    NSString *dir = s_dump_dir();
    NSMutableString *index = [NSMutableString string];

    vm_address_t addr = 0;
    vm_size_t size = 0;
    natural_t depth = 0;
    unsigned long long total = 0;
    int idx = 0, written = 0;

    // 第一遍：数出符合条件的区域总数，供进度展示
    {
        vm_address_t a = 0;
        while (1) {
            vm_size_t sz = 0;
            vm_region_submap_info_data_64_t info;
            mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
            kern_return_t kr = vm_region_recurse_64(mach_task_self(), &a, &sz, &depth,
                                                    (vm_region_info_t)&info, &cnt);
            if (kr != KERN_SUCCESS) break;
            if (info.is_submap) { depth++; continue; }
            if ((info.protection & VM_PROT_WRITE) && (info.protection & VM_PROT_READ) &&
                !(info.protection & VM_PROT_EXECUTE) && sz > 0 && sz <= XRC_DUMP_REGION_MAX)
                atomic_fetch_add(&s_total, 1);
            a += sz;
        }
    }
    xrc_log(@"[dump] %d candidate regions, starting (dir=%@)",
            atomic_load(&s_total), dir);

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
            (info.protection & VM_PROT_EXECUTE) || len == 0 || len > XRC_DUMP_REGION_MAX)
            continue;
        if (total >= XRC_DUMP_TOTAL_MAX) {
            xrc_log(@"[dump] total cap reached, stopping");
            break;
        }

        // mach_vm_read_overwrite：未映射页返回错误而不是崩溃
        vm_offset_t buf = 0;
        mach_msg_type_number_t got = 0;
        kr = mach_vm_read(mach_task_self(), base, len, &buf, &got);
        if (kr != KERN_SUCCESS || !buf) {
            atomic_fetch_add(&s_done, 1);
            continue;
        }

        NSString *name = [NSString stringWithFormat:@"%03d-%012llx.bin", idx, (unsigned long long)base];
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSData *d = [NSData dataWithBytesNoCopy:(void *)buf length:got freeWhenDone:NO];
        BOOL ok = [d writeToFile:path atomically:NO];
        mach_vm_deallocate(mach_task_self(), buf, got);

        if (ok) {
            [index appendFormat:@"%012llx %8x %@\n", (unsigned long long)base, got, name];
            total += got;
            atomic_store(&s_bytes, total);
            written++;
        }
        idx++;
        atomic_fetch_add(&s_done, 1);
    }

    NSString *idxPath = [dir stringByAppendingPathComponent:@"index.txt"];
    [index writeToFile:idxPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    xrc_log(@"[dump] done: %d regions, %.1f MB -> %@", written, total / 1048576.0, dir);
    atomic_store(&s_running, false);
}

void xrc_dump_start(void) {
    bool expect = false;
    if (!atomic_compare_exchange_strong(&s_running, &expect, true)) {
        xrc_log(@"[dump] already running (%d/%d)", xrc_dump_regions_done(), xrc_dump_regions_total());
        return;
    }
    atomic_store(&s_done, 0);
    atomic_store(&s_total, 0);
    atomic_store(&s_bytes, 0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ s_dump_worker(); });
}
