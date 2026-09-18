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
    // ---- 私服接入（XRCNet）----
    BOOL      net_enabled;  // 是否改写 API 请求指向自有服务端
    NSString *net_base;     // 目标 base，如 http://192.168.1.10:8080
    NSString *net_match;    // 需改写的 host（逗号分隔）；空 = 内置默认
    // ---- 拥有/解锁链开关（功能账 §1）----
    BOOL      unlock_all;   // 开：拥有链三层 + 故事门强制返回真（可控内容门）
    // ---- cb 验证链开关（功能账 §3）----
    BOOL      cb_bypass;    // 开：cb 就绪恒真 + 全树校验/更新错码分发跳过
    // ---- 登录门守卫开关（功能账 §1.4）----
    BOOL      login_open;   // 开（默认）：解锁/领奖/联机不再要求"在线登录"（BRK 桩落穿）
    // ---- 自动演奏（功能账 §5）----
    BOOL      autoplay;     // 开（默认关）：一切判定强制 Pure（含漏扫 ts=-1 直调）
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
