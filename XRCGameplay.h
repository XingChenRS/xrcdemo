// XRCGameplay.h — gp.update hook + 谱面钟 retime + seek + 转场重放。
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <limits.h>
#include <stdatomic.h>

// vtable swizzle（PAC 感知；6.13 验证过的实现迁入）。
// 返回槽号，INT_MIN 失败。out_orig 为剥离签名的原函数指针。
int xrc_swizzle_vtable(uint64_t vtable_addr, uint64_t orig_fn_off, void *new_fn, void **out_orig);

// 安装 gameplay vtable hook（换速 retime）。
void xrc_gameplay_install_hooks(uint64_t image_base);

// gp.update 替换实现（self = GameScene；7.0 五参，同 6.13）。
void xrc_gameplay_update(void *self, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);

// 当前 gameplay 实例（gp.update hook 缓存；Tweak.x 转场/循环用）。
extern _Atomic(void *) xrc_gp_instance;

// ---- deferred 操作状态机（UI 只登记，gp.update 循环内执行）----
// 原因：转场/seek 读旧场景内部状态（sub_10091BBB8(v3[116])），
// UI 回调里 self 可能已过期 → UAF 崩溃。游戏循环内 self 保证存活。
typedef enum {
    XRC_OP_NONE = 0,
    XRC_OP_SEEK,          // 音频 seek + 谱面钟平移（不转场）
    XRC_OP_SEEK_REPLAY,   // seek 后带进度转场重开（seek-replay）
    XRC_OP_LOOP_REWIND,   // A-B 循环回到 A（带转场）
} xrc_op_t;

// UI 登记（非阻塞）：返回是否受理（状态机忙时拒绝）。
bool xrc_gameplay_request(xrc_op_t op, uint32_t param_ms);

// 当前 pending 状态（UI 显示/防重入用）。
xrc_op_t xrc_gameplay_pending_op(void);

// seek：音频 seek + 谱面钟平移（6.13 已验证语义）。
// seek：音频 seek + 谱面钟平移。注意：新代码一律走 deferred 状态机
// （xrc_gameplay_request），此函数仅内部/兼容用。
void xrc_seek_ms(uint32_t ms);

// retry 监视（2026-09-10）：练习起点（ms）。任何 seek 都会设置它；
// 之后检测到"帧间时钟大幅回跳"（= 用户 retry / 自然倒带）时自动 seek 回该点，
// 一次性生效。设 0 解除。
void xrc_gameplay_set_resume_ms(uint32_t ms);
uint32_t xrc_gameplay_get_resume_ms(void);

// 读取谱面钟当前值（按 XRCProfile 的 clock 布局）。
int32_t xrc_chart_clock_ms(void *note_group);

// 转场直调（**已废弃路线**，仅 XRC_HAS_TRANSITION=1 编译；会 UAF 崩溃）。
// replay 现走 seek 平移：xrc_gameplay_request(XRC_OP_SEEK_REPLAY/LOOP_REWIND)。
bool xrc_transition_resume(void *gameplay, bool resume);
// A-B 循环状态：From/To（ms）与启用标志（ArcCreate 语义：To >= From+1000）。
bool xrc_loop_get_enabled(void);
void xrc_loop_set_range(uint32_t from_ms, uint32_t to_ms);
void xrc_loop_get_range(uint32_t *from_ms, uint32_t *to_ms);   // 任一可为 NULL
// gp.update 内部调用（7.0 转场版本才有实现）。
void xrc_loop_tick(void *gameplay, uint32_t pos_ms);
