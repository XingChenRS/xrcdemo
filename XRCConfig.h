// XRCConfig.h — 配置 plist 读写 + judge 参数。
#pragma once

#import <Foundation/Foundation.h>

typedef struct {
    float     speeds[16];   // speed_keys 的值拷贝（不复用 plist 内对象，避免悬垂）
    NSInteger speed_count;
    NSInteger rate_index;
    BOOL      button_enabled;
    BOOL      toast;
    int       judge_max_ms;
    int       judge_pure_ms;
    int       judge_far_ms;
    int       judge_lost_ms;
} xrc_config_t;

NSString *xrc_config_path(void);
void xrc_config_load(xrc_config_t *out);
void xrc_config_save(const xrc_config_t *c);

// 从 plist 原样读/写单键（菜单热更新用）。
NSMutableDictionary *xrc_config_dict(void);
void xrc_config_write_dict(NSDictionary *d);

void xrc_config_normalize_judge(xrc_config_t *c);

// 练习面板速度滑杆：写回当前 rateIndex 对应的预设键（与悬浮球长按切速同源）。
void xrc_config_set_current_speed(float v);
