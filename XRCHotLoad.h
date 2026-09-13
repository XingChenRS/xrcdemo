// XRCHotLoad.h — 热加载内层插件。
//
// 背景：越狱设备上 AMFI 已被绕过，`dlopen` 未签名的 dylib 是允许的（tweak 都这么加载）。
// 所以外层 dylib 注入一次之后再也不用动：改逻辑只改内层，从私服拉下来即可 ——
// 省掉的是**重注入 + 重签名 + 重装 app**这一整段，那才是真正耗时的部分。
//
// 流程：GET /__xrc/plugin.dylib → 写进 Documents/xrcdemo-net/ → dlopen
//       → dlsym("xrc_plugin_main") → 传入能力表调用。
// 任何一步失败都只记日志；外层内置行为不受影响。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 拉取并加载。返回 true = 插件已加载并成功返回。
// 同步执行（调用方通常在后台队列里调；主线程调用会阻塞约一个网络往返）。
bool xrc_hotload_run(void);

// 便利封装：把结果写进日志。image_base 由外层提供。
void xrc_hotload_run_logged(void);
