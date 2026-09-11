// XRCDump.h — 进程内内存转储（不依赖任何调试器）
//
// 动机：debugserver 附加需要 task_for_pid 权限，反复把目标进程弄崩；而我们在
// 进程内部，读自己的内存是天然合法的。用 mach_vm_region 枚举 + mach_vm_read_overwrite
// 读取（后者对未映射页返回错误而不是崩溃，比 memcpy 安全）。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 后台线程转储可写内存（堆/栈/匿名映射 —— 累积数据所在处）。
// 幂等：已在跑时直接返回。结果写 Documents/xrcdemo-net/mem/。
void xrc_dump_start(void);

bool xrc_dump_running(void);
int  xrc_dump_regions_done(void);
int  xrc_dump_regions_total(void);
unsigned long long xrc_dump_bytes_written(void);
