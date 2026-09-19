// XRCNet.h — 私服接入：把游戏 API 请求改指向自有服务端 + 全量请求日志。
//
// 设计依据（2026-09-12 真机 dump 分析）：
//   · 游戏 API base = https://arcapi-v4.lowiro.com/coordinatedballetclock/42/<endpoint>
//     host 与端点之间还有一层 codename + 版本号，且该 codename 不存在于静态二进制。
//   · 游戏网络栈走 NSURLConnection（HttpAsynConnection 封装），不是 NSURLSession。
//   · pin 表按域名查询；换到自有域名后不在表内 → DomainNotPinned → 放行。
//
// 因此最小可行方案：**在 NSURLConnection 建连前改写 URL 的 scheme/host/port，
// 保留 path 与 query**。服务端因此能看到完整原始路径（含 codename），
// 对调试最有利；同时不碰任何 TLS/pin 逻辑。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 安装 hook（URL 改写 + 请求日志）。幂等。
void xrc_net_install(void);

// 运行期配置入口（面板/配置读取后调用）
void xrc_net_set_enabled(bool on);
void xrc_net_set_base(const char *base);     // 如 "http://192.168.1.10:8080"；空 = 不改写
void xrc_net_set_match(const char *hosts);   // 逗号分隔的需要改写的 host；空 = 用默认

bool   xrc_net_enabled(void);
// 统计
unsigned long long xrc_net_requests(void);
unsigned long long xrc_net_rewritten(void);
uint32_t xrc_net_redirects(void);   // 被改写的 302 跟跳次数（v2.12）
uint32_t xrc_net_dl_created(void);  // cocos 下载栈：建任务次数（v2.14）
uint32_t xrc_net_dl_done(void);     // cocos 下载栈：完结次数（v2.14）
