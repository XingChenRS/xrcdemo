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

// 早期装配：在 %ctor 里调用（安装处理器 + 立即注册，主程序基址经 dyld 自取）。
// 注册与处理器安装必须同刻——启动极早期就命中的桩（如 cb 校验）等不到 didFinishLaunching。
void xrc_brk_setup_early(void);

// ---- 开关组（功能账 §1；v2.12 由原 unlockAll 一拆四）----
// 置真后对应桩的 handler 强制 `x0=` 直返（直返语义见 XRCHook.m 注释）；
// 置假恢复原行为（重放跳板）。async-signal-safe：处理器只做原子读。
//   own  → unlock_l1/l2/l3（拥有链）
//   fv   → lock_fv（FV 五曲 fast path → 五难度全解）
//   do   → lock_do（DO/konzetsu 分支）
//   gate → fv_gate（终章链门；1 = 放行，决定整表是否解锁）
void xrc_brk_set_unlock_own(bool on);
void xrc_brk_set_unlock_fv(bool on);
void xrc_brk_set_unlock_do(bool on);
void xrc_brk_set_gate_open(bool on);
bool xrc_brk_unlock_own(void);
bool xrc_brk_unlock_fv(void);
bool xrc_brk_unlock_do(void);
bool xrc_brk_gate_open(void);

// ---- cb 验证链开关（功能账 §3）----
// 置真后 cb_ready 恒真、cb_verify/cb_dispatch 整体跳过（改谱面/cb 自由化）。
void xrc_brk_set_cb_bypass(bool on);
bool xrc_brk_cb_bypass(void);

// 统计（异步写入，主线程读；供定时器落日志）
uint32_t    xrc_brk_hits(int slot_index);
int         xrc_brk_slot_count(void);
const char *xrc_brk_slot_name(int slot_index);
uint64_t    xrc_brk_last_hit_us(int slot_index);   // mach_absolute_time 微秒

// 自动演奏诊断计数（v2.1）：mark/skip/窗口强判(音符号,弧子音符)/引擎 tick(Pure,Lost)。
void        xrc_brk_ap_stats(uint32_t out[6]);

// 曲目锁态覆盖命中计数（v2.6：FV fast path / DO 分支入口直返全解锁的次数）。
uint32_t    xrc_brk_lock_hits(void);

// ---- applog 明文捕获 ----
// 处理器在 applog 桩点处按 OnlineManager+0x128/+0x130 抓取**加密前**的明文到内部
// 缓冲（async-signal-safe：只做 memcpy + 原子写）。主线程用 take() 取走再落盘。
void     xrc_brk_capture_enable(bool on);
uint32_t xrc_brk_capture_seq(void);                 // 捕获序号（每次命中 +1）
// 有新捕获时拷进 buf（最多 cap 字节）返回实际长度；无新数据返回 0。
size_t   xrc_brk_capture_take(void *buf, size_t cap);

// ---- log_blob 密文捕获（第二个桩点：载荷加密出口，SP+0x290 的 std::string）----
// 与上面那份**分开缓冲**：入口抓的是明文，出口抓的是密文，两次命中相隔极近，
// 共用一个缓冲会互相覆盖。主线程分别 take() 落盘。
uint32_t xrc_brk_blob_seq(void);
size_t   xrc_brk_blob_take(void *buf, size_t cap);
uint64_t xrc_brk_blob_sp(void);     // 该次捕获对应的 SP（离线换算帧内绝对地址用）
