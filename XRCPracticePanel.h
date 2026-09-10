// XRCPracticePanel.h — ArcCreate 同构练习面板。
// 结构（对齐 external/ArcCreate Assets/Scripts/Gameplay/Audio/Practice/）：
//   波形时间轴（点击/拖动 = seek；循环区间高亮显示）
//   Repeat: From / To / On-Off（To >= From+1s 夹取）
//   Speed: 滑杆 0.01–2.0（snap 0.05，加快捷微调）
//   跳转: -5s/+5s（时长按速度缩放 5000*speed，同 ArcCreate JumpDuration）
//   退出练习
#pragma once

#import <UIKit/UIKit.h>

@interface XRCPracticePanel : UIView

+ (instancetype)shared;
- (void)show;
- (void)hide;
- (BOOL)isVisible;

// 面板显示时的每帧刷新（外部 0.1s 定时器驱动）。
- (void)tick;

@end
