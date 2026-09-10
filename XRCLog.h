// XRCLog.h — 统一日志（xrc_log）+ 跨模块 UI 共享声明（Tweak.x / 面板 / 探针）。
// 游戏逻辑声明在各 XRC*.h；本文件只保留 UI 与日志层。
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>

void xrc_log(NSString *fmt, ...);

@class XRCFloatButton;
extern XRCFloatButton *button;
@class XRCMenuBridge;
