// XRCHook.h — BRK 桩：SIGTRAP 分发 + 重放跳板（实验形态，见 XRCProfile.h 注释）
//
// 与 trampoline v2 的区别：不改函数入口结构，只把**任意一条**指令原地换成
// `BRK #0`（4 字节，长度不变）。dylib 的 SIGTRAP 处理器接住陷阱，跑完自有逻辑
// 后把 ucontext 的 PC 指向"重放跳板"（原指令 + B 回 site+4）。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 安装 SIGTRAP 处理器。幂等；尽早调用（%ctor 内），别等 doBootstrap——
// 桩点在注入时已写死，走不到处理器就会被前一个 SIGTRAP 处理器（Crashlytics
// / Swift 运行时）接管。
void xrc_brk_install(void);

// 注册桩点。site/replay 为运行时地址。handler 可空；若给出，在 PC 重定向**之前**
// 调用，且必须 async-signal-safe（本模块内部只用原子计数）。
// 返回 false = 表满或参数非法。
bool xrc_brk_register(uint64_t site_va, uint64_t replay_va,
                      void (*handler)(void *uctx));

// 按本版本 profile 装配全部桩点（安装处理器 + 注册）。
void xrc_brk_setup(uint64_t image_base);

// 统计（异步写入，主线程读；供定时器落日志）
uint32_t    xrc_brk_hits(int slot_index);
int         xrc_brk_slot_count(void);
const char *xrc_brk_slot_name(int slot_index);
uint64_t    xrc_brk_last_hit_us(int slot_index);   // mach_absolute_time 微秒

// ---- applog 明文捕获 ----
// 处理器在 applog 桩点处按 OnlineManager+0x128/+0x130 抓取**加密前**的明文到内部
// 缓冲（async-signal-safe：只做 memcpy + 原子写）。主线程用 take() 取走再落盘。
void     xrc_brk_capture_enable(bool on);
uint32_t xrc_brk_capture_seq(void);                 // 捕获序号（每次命中 +1）
// 有新捕获时拷进 buf（最多 cap 字节）返回实际长度；无新数据返回 0。
size_t   xrc_brk_capture_take(void *buf, size_t cap);
