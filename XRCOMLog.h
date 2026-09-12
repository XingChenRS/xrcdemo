// XRCOMLog.h — OnlineManager 探针 + applog 强发。
//
// 动机：applog（OnlineManager 槽 72 = sub_100623AEC）在真机上从未触发过，
// 静态也找不到调用方（全二进制只有 vtable 一处 data 引用 → 纯虚分派）。
// 于是换两条互补的路：
//   1. 探针：按 vtable 指针定位 OnlineManager 单例，把它身上的累加器 / 载荷
//      字段（+0xf0/+0xf8/+0x100/+0x108/+0x128/+0x130…）读出来落日志
//      —— 回答"累加器有没有在涨、阈值是多少"。
//   2. 强发：直接取 vtable[72] 调用，绕过触发条件硬造一次 applog
//      —— 回答"这个函数到底干什么、载荷长什么样"。
//      函数入口的 BRK 桩会照常命中，因此明文捕获同样生效。
//
// 两条都只依赖 dylib（不碰主程序、不需要重签名主二进制）。强发带段错误兜底，
// 失败只丢一次调用，不会把进程带走。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 扫可写内存按 vtable 指针定位 OnlineManager 单例（0 = 未找到）。
uint64_t xrc_om_find(void);

// 打印单例的累加器 / 载荷字段；若疑似 vector<string> 则逐条打印内容。
// 安全、幂等，可随时调用（面板按钮 / PROBE 标志文件）。
void xrc_om_probe(void);

// 强制调用 vtable 槽 72（applog 发送）。返回是否"调用返回了"（不含崩溃兜底）。
// 失败会在日志里说明；进程不受影响。
bool xrc_om_force_applog(void);
