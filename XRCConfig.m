// XRCConfig.m — 配置 plist 读写 + judge 参数。
// 6.13 Tweak.x 的 config 段迁入；judge 归一化保持原语义。

#import "XRCConfig.h"

static NSString *s_legacy_pref_path(void) {
    // 历史 jailbreak preference 路径；侧载下仅作迁移源。
    return [NSString stringWithFormat:@"%@/Library/Preferences/moe.low.arc.xrcdemo.plist", NSHomeDirectory()];
}

NSString *xrc_config_path(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:@"xrcdemo.plist"];
}

static void s_migrate_legacy_if_needed(void) {
    NSString *cfg = xrc_config_path();
    if (!cfg || [[NSFileManager defaultManager] fileExistsAtPath:cfg]) return;
    NSMutableDictionary *old = [[NSMutableDictionary alloc] initWithContentsOfFile:s_legacy_pref_path()];
    if (!old || old.count == 0) return;
    [old writeToFile:cfg atomically:YES];
}

static void s_ensure_defaults(NSMutableDictionary *p) {
    if (!p[@"speedKeys"] || ![p[@"speedKeys"] count]) {
        p[@"speedKeys"] = [@[@"speed-1", @"speed-2", @"speed-3", @"speed-4", @"speed-5"] mutableCopy];
        p[@"speed-1"] = @1.00;
        p[@"speed-2"] = @0.80;
        p[@"speed-3"] = @0.60;
        p[@"speed-4"] = @1.25;
        p[@"speed-5"] = @1.50;
    }
    if (!p[@"buttonEnabled"]) p[@"buttonEnabled"] = @YES;
    if (!p[@"toast"])         p[@"toast"]         = @YES;
    if (!p[@"rateIndex"])     p[@"rateIndex"]     = @0;
    if (!p[@"judgeMaxMs"] && p[@"judgeWindowScale"]) {
        float sc = [p[@"judgeWindowScale"] floatValue];
        if (sc < 0.25f) sc = 0.25f;
        if (sc > 4.0f) sc = 4.0f;
        p[@"judgeMaxMs"]  = @((int)lround(25.0f * sc));
        p[@"judgePureMs"] = @((int)lround(50.0f * sc));
        p[@"judgeFarMs"]  = @((int)lround(100.0f * sc));
        p[@"judgeLostMs"] = @((int)lround(120.0f * sc));
    }
    if (!p[@"judgeMaxMs"])  p[@"judgeMaxMs"]  = @25;
    if (!p[@"judgePureMs"]) p[@"judgePureMs"] = @50;
    if (!p[@"judgeFarMs"])  p[@"judgeFarMs"]  = @100;
    if (!p[@"judgeLostMs"]) p[@"judgeLostMs"] = @120;
    // 私服接入：默认关闭；地址预填联调用的本机服务端（可改）
    if (!p[@"netEnabled"]) p[@"netEnabled"] = @NO;
    if (!p[@"netBase"])    p[@"netBase"]    = @"http://192.168.110.253:8080";
    if (!p[@"netMatch"])   p[@"netMatch"]   = @"";
    // 拥有/解锁链开关：默认关闭（打开前先确认已了解风险——服务端成绩校验仍会拒）
    if (!p[@"unlockAll"])  p[@"unlockAll"]  = @NO;
    // cb 验证链开关：默认关闭（开 = 改谱面/cb 自由化）
    if (!p[@"cbBypass"])   p[@"cbBypass"]   = @NO;
}

NSMutableDictionary *xrc_config_dict(void) {
    s_migrate_legacy_if_needed();
    NSString *path = xrc_config_path();
    NSMutableDictionary *p = path ? [[NSMutableDictionary alloc] initWithContentsOfFile:path] : nil;
    if (!p) p = [NSMutableDictionary new];
    s_ensure_defaults(p);
    return p;
}

void xrc_config_write_dict(NSDictionary *d) {
    NSString *path = xrc_config_path();
    if (!path) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:path atomically:YES];
}

void xrc_config_set_current_speed(float v) {
    NSMutableDictionary *p = xrc_config_dict();
    NSArray *keys = p[@"speedKeys"];
    NSInteger idx = [p[@"rateIndex"] integerValue];
    if (!keys || idx < 0 || idx >= (NSInteger)keys.count) return;
    p[keys[idx]] = @(v);
    xrc_config_write_dict(p);
}

void xrc_config_normalize_judge(xrc_config_t *c) {
    if (c->judge_max_ms < 1) c->judge_max_ms = 1;
    if (c->judge_max_ms > 2000) c->judge_max_ms = 2000;
    if (c->judge_pure_ms <= c->judge_max_ms) c->judge_pure_ms = c->judge_max_ms + 1;
    if (c->judge_pure_ms > 2000) c->judge_pure_ms = 2000;
    if (c->judge_far_ms <= c->judge_pure_ms) c->judge_far_ms = c->judge_pure_ms + 1;
    if (c->judge_far_ms > 2000) c->judge_far_ms = 2000;
    if (c->judge_lost_ms <= c->judge_far_ms) c->judge_lost_ms = c->judge_far_ms + 1;
    if (c->judge_lost_ms > 2000) c->judge_lost_ms = 2000;
}

void xrc_config_load(xrc_config_t *out) {
    if (!out) return;
    NSMutableDictionary *prefs = xrc_config_dict();
    out->toast          = [prefs[@"toast"] boolValue];
    out->button_enabled = [prefs[@"buttonEnabled"] boolValue];
    NSArray *speed_keys = prefs[@"speedKeys"];
    out->speed_count    = speed_keys.count;
    for (NSInteger i = 0; i < out->speed_count && i < 16; i++)
        out->speeds[i] = [prefs[speed_keys[i]] floatValue];
    out->rate_index     = [prefs[@"rateIndex"] integerValue];
    if (out->rate_index >= out->speed_count) out->rate_index = 0;
    out->judge_max_ms   = [prefs[@"judgeMaxMs"] intValue];
    out->judge_pure_ms  = [prefs[@"judgePureMs"] intValue];
    out->judge_far_ms   = [prefs[@"judgeFarMs"] intValue];
    out->judge_lost_ms  = [prefs[@"judgeLostMs"] intValue];
    xrc_config_normalize_judge(out);
    out->net_enabled    = [prefs[@"netEnabled"] boolValue];
    out->net_base       = [prefs[@"netBase"] length] ? prefs[@"netBase"] : nil;
    out->net_match      = [prefs[@"netMatch"] length] ? prefs[@"netMatch"] : nil;
    out->unlock_all     = [prefs[@"unlockAll"] boolValue];
    out->cb_bypass      = [prefs[@"cbBypass"] boolValue];
}

void xrc_config_save(const xrc_config_t *c) {
    if (!c) return;
    NSMutableDictionary *p = xrc_config_dict();
    p[@"toast"]         = @(c->toast);
    p[@"buttonEnabled"] = @(c->button_enabled);
    p[@"rateIndex"]     = @(c->rate_index);
    p[@"judgeMaxMs"]    = @(c->judge_max_ms);
    p[@"judgePureMs"]   = @(c->judge_pure_ms);
    p[@"judgeFarMs"]    = @(c->judge_far_ms);
    p[@"judgeLostMs"]   = @(c->judge_lost_ms);
    p[@"netEnabled"]    = @(c->net_enabled);
    p[@"netBase"]       = c->net_base ?: @"";
    p[@"netMatch"]      = c->net_match ?: @"";
    p[@"unlockAll"]     = @(c->unlock_all);
    p[@"cbBypass"]      = @(c->cb_bypass);
    xrc_config_write_dict(p);
}
