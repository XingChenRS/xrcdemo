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
    // ---- 开关组（功能账 §1；v2.12 由原 unlockAll 一拆四）----
    BOOL      unlock_own;   // 拥有链三层（unlock_l1/l2/l3；服务器已全授予时在线冗余）
    BOOL      unlock_fv;    // FV 五曲 fast path → 五难度全解
    BOOL      unlock_do;    // DO(konzetsu) 分支 → 五难度全解
    BOOL      gate_open;    // 终章链门：1 = 放行（决定整表是否解锁）
    // ---- cb 验证链开关（功能账 §3）----
    BOOL      cb_bypass;    // 开：cb 就绪恒真 + 全树校验/更新错码分发跳过
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
