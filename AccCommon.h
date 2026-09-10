// AccCommon.h — 跨模块 UI/引导共享声明（Tweak.x 与菜单）。
// 游戏逻辑声明在各 XRC*.h；本文件只保留 UI 与日志层。
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>

void acc_flog(NSString *fmt, ...);

@class XRCFloatButton;
extern XRCFloatButton *button;
@class AccMenuController;
