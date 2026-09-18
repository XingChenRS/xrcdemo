// XRCPracticePanel.m — ArcCreate 同构练习面板实现。
// 交互对齐 external/ArcCreate Assets/Scripts/Gameplay/Audio/Practice/：
//   PracticeTimeline（点击/拖动 = seek + 循环区间可视化）
//   PracticeMenu（From/To/On-Off + 速度滑杆）
//   PracticeTimingControl（±5s 跳转，时长 = 5000 × speed）
// 布局为底部半透明卡片，不遮挡判定线（ArcCreate 同为底部时间轴条）。

#import "XRCPracticePanel.h"
#import "XRCFloatButton.h"
#import "WHToast/WHToast.h"
#import "XRCLog.h"
#include "XRCConfig.h"
#include "XRCGameplay.h"
#include "XRCClock.h"
#include "XRCPlayer.h"
#include "XRCJudge.h"
#include "XRCProbe.h"
#include "XRCProfile.h"
#include "XRCDump.h"
#include "XRCNet.h"
#include "XRCHook.h"

// ---------------- 时间轴视图（PracticeTimeline 同构） ----------------
@interface XRCTimelineView : UIView
@property (nonatomic, copy) void (^onScrub)(uint32_t ms, BOOL finished);
@property (nonatomic, assign) uint32_t lengthMs;
@property (nonatomic, assign) uint32_t positionMs;
@property (nonatomic, assign) uint32_t loopFromMs;
@property (nonatomic, assign) uint32_t loopToMs;
@property (nonatomic, assign) BOOL loopVisible;
@property (nonatomic, assign) BOOL rangeDragging;
@end

@implementation XRCTimelineView {
    UITapGestureRecognizer *_tap;
    UIPanGestureRecognizer *_pan;
    CGFloat _dragStartX;
    CGPoint _lastPoint;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        self.layer.cornerRadius = 6;
        self.layer.masksToBounds = YES;
        _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        [self addGestureRecognizer:_tap];
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:_pan];
    }
    return self;
}

- (uint32_t)msAtX:(CGFloat)x {
    CGFloat w = self.bounds.size.width;
    if (w <= 0 || self.lengthMs == 0) return 0;
    CGFloat t = MAX(0.0, MIN(1.0, x / w));
    return (uint32_t)(t * self.lengthMs);
}

- (void)onTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    if (self.onScrub) self.onScrub([self msAtX:p.x], YES);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    // 2026-09-10: drag = pure seek preview, execute on release. Two-finger
    // range selection removed (user: precision too low). Loop range is set
    // exclusively via the Set From / Set To buttons.
    if (g.state == UIGestureRecognizerStateChanged) {
        self.positionMs = [self msAtX:p.x];
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.onScrub) self.onScrub([self msAtX:p.x], YES);
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    if (self.lengthMs == 0) return;

    // 循环区间高亮（PracticeTimeline 的 repeatFrom/repeatTo 着色同构）
    if (self.loopVisible && self.loopToMs > self.loopFromMs) {
        CGFloat x0 = w * ((CGFloat)self.loopFromMs / self.lengthMs);
        CGFloat x1 = w * ((CGFloat)self.loopToMs / self.lengthMs);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:0.35].CGColor);
        CGContextFillRect(ctx, CGRectMake(x0, 0, x1 - x0, h));
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.5 green:0.85 blue:1.0 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeRect(ctx, CGRectMake(x0, 0.75, x1 - x0, h - 1.5));
    }

    // 中心线（波形占位——xrc 无波形数据，用中线示意）
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.45 alpha:0.8].CGColor);
    CGContextSetLineWidth(ctx, 1);
    CGContextMoveToPoint(ctx, 0, h / 2);
    CGContextAddLineToPoint(ctx, w, h / 2);
    CGContextStrokePath(ctx);

    // 当前进度指针（PracticeTimeline 的 _CurrentSample 同构）
    if (self.lengthMs > 0) {
        CGFloat px = w * ((CGFloat)self.positionMs / self.lengthMs);
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillRect(ctx, CGRectMake(px - 1, 0, 2, h));
    }
}

- (void)setPositionMs:(uint32_t)positionMs {
    _positionMs = positionMs;
    [self setNeedsDisplay];
}
- (void)setLoopFromMs:(uint32_t)from to:(uint32_t)to visible:(BOOL)visible {
    _loopFromMs = from; _loopToMs = to; _loopVisible = visible;
    [self setNeedsDisplay];
}
- (void)setLengthMs:(uint32_t)lengthMs {
    _lengthMs = lengthMs;
    [self setNeedsDisplay];
}
@end

// ---------------- 面板主体（PracticeMenu 同构） ----------------
@interface XRCPracticePanel ()
@property (nonatomic, strong) XRCTimelineView *timeline;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UIButton *fromBtn;
@property (nonatomic, strong) UIButton *toBtn;
@property (nonatomic, strong) UIButton *onOffBtn;
@property (nonatomic, strong) UILabel *capsLabel;
@property (nonatomic, strong) UILabel *judgeHdr;
@property (nonatomic, strong) NSMutableArray<UITextField *> *judgeFields;
@property (nonatomic, assign) CGFloat contentHeight;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL pendingTo;   // Set From 后等待 Set To
@end

@implementation XRCPracticePanel

+ (instancetype)shared {
    static XRCPracticePanel *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[XRCPracticePanel alloc] initWithFrame:CGRectZero];
    });
    return s;
}

- (UIWindow *)keyWindow {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (BOOL)isVisible { return self.superview != nil; }

- (void)show {
    UIWindow *w = [self keyWindow];
    if (!w) return;
    // 高度：先按内容测量（buildIfNeeded 返回内容底边），再加边距
    [self buildIfNeeded];
    CGFloat contentH = [self contentHeight];
    CGFloat h = contentH + 16;
    CGFloat margin = 12;
    CGFloat bottomInset = 0;
    if (@available(iOS 11.0, *)) bottomInset = w.safeAreaInsets.bottom;
    self.frame = CGRectMake(margin, w.bounds.size.height - h - margin - bottomInset, w.bounds.size.width - margin * 2, h);
    self.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    // 内容按最终宽度重排一次（宽度变化会影响换行）
    [self relayoutContent];
    [w addSubview:self];
    [w bringSubviewToFront:self];

    // 注意：**不冻结时间域**（xrc_clock_freeze_* 会让 gp.update 时钟停止，
    // 游戏逻辑卡死且退出面板无法恢复——真机教训 2026-09-10）。
    // 面板打开只是 UI 覆盖层，不改时间基准。

    [self refresh];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)hide {
    [self.timer invalidate];
    self.timer = nil;
    // 不触碰时间域（面板从不冻结——见 show 注释）
    [self removeFromSuperview];
}

// tick：仅刷新 UI（v9.0.0：自动换歌检测/清除全线下——retry 重建会重置曲长，
// 任何"自动判换歌"都会误伤；循环的清除只走「重置循环段落」按钮）。
- (void)tick {
    [self refresh];
}

- (void)buildIfNeeded {
    if (self.subviews.count) return;
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.88];
    self.layer.cornerRadius = 12;
    self.layer.masksToBounds = YES;

    // Unified metrics (2026-09-10 relayout): every position derives from pad/gap,
    // no magic numbers -> left/right columns can never overlap.
    const CGFloat pad = 12;
    const CGFloat gap = 8;
    const CGFloat blockGap = 12;
    const CGFloat rowH = 30;
    CGFloat W = self.bounds.size.width - pad * 2;
    if (W < 120) W = 336;                 // safe value before layout (show() re-lays out)
    CGFloat x0 = pad;
    CGFloat y = pad;

    // ---- title bar ----
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, W - 76, 20)];
    title.text = @"练习面板";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    [self addSubview:title];
    // v9.0.0：右上角 = 重置循环段落（清 A/B + 关循环；关闭面板改为单击悬浮球）
    UIButton *reset = [self makeButton:@"重置循环" action:@selector(resetLoop)];
    reset.frame = CGRectMake(x0 + W - 84, y - 3, 84, 26);
    [reset setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self addSubview:reset];
    y += 20 + blockGap;

    // ---- timeline (PracticeTimeline equivalent) ----
    self.timeline = [[XRCTimelineView alloc] initWithFrame:CGRectMake(x0, y, W, 36)];
    __weak typeof(self) weakSelf = self;
    self.timeline.onScrub = ^(uint32_t ms, BOOL finished) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        if (finished) {
            // 松手 = deferred seek（在游戏循环内执行）。v9.0.0 起 SEEK 与
            // SEEK_REPLAY 走同一实现（seek 平移）；统一用 SEEK。
            xrc_gameplay_request(XRC_OP_SEEK, ms);
        }
    };
    [self addSubview:self.timeline];
    y += 36 + gap;

    // ---- time row: elapsed/length + -5s/+5s (JumpDuration = 5000 x speed) ----
    self.timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, 130, rowH)];
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.timeLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    [self addSubview:self.timeLabel];
    UIButton *back = [self makeButton:@"-5s" action:@selector(jumpBack)];
    back.frame = CGRectMake(x0 + W - 124, y, 58, 28);
    [self addSubview:back];
    UIButton *fwd = [self makeButton:@"+5s" action:@selector(jumpForward)];
    fwd.frame = CGRectMake(x0 + W - 58, y, 58, 28);
    [self addSubview:fwd];
    y += rowH + blockGap;

    // ---- two-column grid: left = loop + speed, right = judgement 2x2 ----
    CGFloat colW = (W - gap) / 2.0f;
    CGFloat rx = x0 + colW + gap;

    self.fromBtn = [self makeButton:@"起点" action:@selector(setFrom)];
    self.fromBtn.frame = CGRectMake(x0, y, colW / 2 - 4, rowH);
    [self addSubview:self.fromBtn];
    self.toBtn = [self makeButton:@"终点" action:@selector(setTo)];
    self.toBtn.frame = CGRectMake(x0 + colW / 2 + 4, y, colW / 2 - 4, rowH);
    [self addSubview:self.toBtn];
    self.onOffBtn = [self makeButton:@"循环 关" action:@selector(toggleRepeat)];
    self.onOffBtn.frame = CGRectMake(x0, y + rowH + gap, colW, rowH);
    [self addSubview:self.onOffBtn];

    CGFloat speedY = y + 2 * (rowH + gap);
    self.speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(x0, speedY, 56, rowH)];
    self.speedLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.speedLabel.textColor = [UIColor whiteColor];
    [self addSubview:self.speedLabel];
    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(x0 + 60, speedY, colW - 60, rowH)];
    self.speedSlider.minimumValue = 0.05f;
    self.speedSlider.maximumValue = 2.0f;
    self.speedSlider.continuous = YES;
    [self.speedSlider addTarget:self action:@selector(speedChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.speedSlider];

    self.judgeHdr = [[UILabel alloc] initWithFrame:CGRectMake(rx, y, colW, 14)];
    self.judgeHdr.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.judgeHdr.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.judgeHdr.adjustsFontSizeToFitWidth = YES;
    self.judgeHdr.minimumScaleFactor = 0.75;
    self.judgeHdr.numberOfLines = 1;
    [self addSubview:self.judgeHdr];

    int vals[4];
    xrc_judge_get_windows(&vals[0], &vals[1], &vals[2], &vals[3]);
    const char *tags[4] = {"Max", "Pure", "Far", "Lost"};
    self.judgeFields = [NSMutableArray array];
    CGFloat cellW = (colW - gap) / 2.0f;
    for (int i = 0; i < 4; i++) {
        CGFloat cx = rx + (i % 2) * (cellW + gap);
        CGFloat cy = y + 18 + (i / 2) * (rowH + gap);
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(cx, cy, cellW, 12)];
        lbl.text = @(tags[i]);
        lbl.font = [UIFont systemFontOfSize:9];
        lbl.textColor = [UIColor grayColor];
        [self addSubview:lbl];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(cx, cy + 13, cellW, 26)];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        tf.textAlignment = NSTextAlignmentCenter;
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%d", vals[i]];
        tf.tag = 4100 + i;
        tf.delegate = (id<UITextFieldDelegate>)self;
        [self addSubview:tf];
        [self.judgeFields addObject:tf];
    }

    CGFloat leftBottom  = y + 3 * (rowH + gap) - gap;
    CGFloat rightBottom = y + 18 + 2 * (rowH + gap) - gap + 13;
    y = MAX(leftBottom, rightBottom) + blockGap;

    // ---- 私服接入（XRCNet）：开关 + 目标 base ----
    // 只改 API 请求的 scheme/host/port，path/query 原样保留；不碰 TLS。
    // 换域后域名不在 pin 表里 → TrustKit DomainNotPinned → 放行，无需绕 pin。
    UIButton *netBtn = [self makeButton:@"私服 关" action:@selector(toggleNet)];
    netBtn.frame = CGRectMake(x0, y, 112, rowH);
    netBtn.tag = 4200;
    netBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [netBtn setTitleColor:[UIColor systemTealColor] forState:UIControlStateNormal];
    [self addSubview:netBtn];
    UITextField *netField = [[UITextField alloc] initWithFrame:
                                 CGRectMake(x0 + 118, y, W - 118, rowH)];
    netField.borderStyle = UITextBorderStyleRoundedRect;
    netField.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    netField.placeholder = @"http://192.168.110.253:8080";
    netField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    netField.autocorrectionType = UITextAutocorrectionTypeNo;
    netField.keyboardType = UIKeyboardTypeURL;
    netField.returnKeyType = UIReturnKeyDone;
    netField.tag = 4201;
    netField.delegate = (id<UITextFieldDelegate>)self;
    {
        xrc_config_t c; xrc_config_load(&c);
        netField.text = c.net_base ?: @"";
    }
    [self addSubview:netField];
    y += rowH + gap;

    // ---- 拥有/解锁链 + cb 验证链开关（功能账 §1/§3）----
    // 直连 BRK 桩 handler（xrc_brk_set_*），即时生效；plist 键 unlockAll/cbBypass 启动时同源。
    UIButton *unlockBtn = [self makeButton:@"解锁 关" action:@selector(toggleUnlockAll)];
    unlockBtn.frame = CGRectMake(x0, y, (W - 8) / 2, rowH);
    unlockBtn.tag = 4210;
    unlockBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [unlockBtn setTitleColor:[UIColor systemPinkColor] forState:UIControlStateNormal];
    [self addSubview:unlockBtn];
    UIButton *cbBtn = [self makeButton:@"cb校验 关" action:@selector(toggleCbBypass)];
    cbBtn.frame = CGRectMake(x0 + (W - 8) / 2 + 8, y, (W - 8) / 2, rowH);
    cbBtn.tag = 4211;
    cbBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [cbBtn setTitleColor:[UIColor systemPinkColor] forState:UIControlStateNormal];
    [self addSubview:cbBtn];
    y += rowH + gap;

    // ---- 登录门守卫开关（功能账 §1.4）----
    // BRK no-replay 桩的运行时开关：开=解锁/领奖/联机不再弹"必须在线登录"。
    UIButton *loginBtn = [self makeButton:@"登录门 开" action:@selector(toggleLoginOpen)];
    loginBtn.frame = CGRectMake(x0, y, W, rowH);
    loginBtn.tag = 4212;
    loginBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [loginBtn setTitleColor:[UIColor systemPinkColor] forState:UIControlStateNormal];
    [self addSubview:loginBtn];
    y += rowH + gap;

    // ---- tips（拖拽=跳转；循环 = 设起点→设终点→开循环；到终点自动重建回起点）----
    UILabel *tips = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, W, 14)];
    tips.text = @"拖时间轴=跳转 ｜ 循环: 设起点→设终点→开循环(到终点回到起点; Retry 后也回到起点)";
    tips.font = [UIFont systemFontOfSize:10];
    tips.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    tips.adjustsFontSizeToFitWidth = YES;
    tips.minimumScaleFactor = 0.8;
    [self addSubview:tips];
    y += 14 + gap;

    self.capsLabel = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, W - 96, 14)];
    self.capsLabel.font = [UIFont systemFontOfSize:10];
    self.capsLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self addSubview:self.capsLabel];
    // 内存转储（进程内自读，不经调试器）：诊断用，结果落 Documents/xrcdemo-net/mem/
    UIButton *dumpBtn = [self makeButton:@"转储内存" action:@selector(dumpMemory)];
    dumpBtn.frame = CGRectMake(x0 + W - 92, y - 5, 92, 24);
    dumpBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [self addSubview:dumpBtn];
    y += 14 + 2;

    self.contentHeight = y;
}

- (void)relayoutContent {
    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];
    self.timeline = nil; self.timeLabel = nil; self.speedLabel = nil;
    self.speedSlider = nil; self.fromBtn = nil; self.toBtn = nil;
    self.onOffBtn = nil; self.capsLabel = nil; self.judgeHdr = nil;
    self.judgeFields = nil;
    [self buildIfNeeded];
}

// 能力门控：不可用功能禁用（避免崩溃/异常），日志同源可见。
- (void)applyCapabilityGating {
    BOOL replayOK = g_caps.replay_available;   // 槽 178 存在（seek-replay 依赖）
    // 循环按钮：无转场能力则禁用（回放走转场）
    self.onOffBtn.enabled = replayOK;
    self.onOffBtn.alpha = replayOK ? 1.0 : 0.4;
    // 改判：桩激活才可编辑
    BOOL judgeOK = g_caps.stub_present && g_caps.judge_handler_live;
    for (UITextField *tf in self.judgeFields) {
        tf.enabled = judgeOK;
        tf.alpha = judgeOK ? 1.0 : 0.5;
    }
    // 诊断分级：明确区分"没桩 / 旧跳板 / handler 未装"三种失败（2026-09-10 教训：
    // 含糊的 "binary not patched" 无法定位是主程序没打桩还是打了旧桩）。
    if (judgeOK) {
        self.judgeHdr.text = @"Judgement window +/-ms (Max/Pure/Far/Lost)";
    } else if (!g_caps.stub_present) {
        self.judgeHdr.text = @"Judgement: main binary NOT patched (dylib-only?)";
    } else if (!g_caps.stub_v2) {
        self.judgeHdr.text = @"Judgement: stale v1 stub — regenerate (inject.py --stub)";
    } else {
        self.judgeHdr.text = @"Judgement: handler not installed (check log)";
    }
    self.capsLabel.text = [NSString stringWithFormat:
        @"caps: stub=%d v2=%d judge=%d gp=%d mtp=%d replay=%d",
        g_caps.stub_present, g_caps.stub_v2, g_caps.judge_handler_live,
        g_caps.gp_hook_live, g_caps.mtp_hook_live, g_caps.replay_available];
    self.capsLabel.textColor = judgeOK
        ? [UIColor colorWithWhite:0.7 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:0.6 blue:0.4 alpha:1.0];
}

// 改判四档提交（缩放 = 总和 / 270）
- (void)commitJudge {
    int v[4];
    for (int i = 0; i < 4 && i < (int)self.judgeFields.count; i++)
        v[i] = MAX(1, [self.judgeFields[i].text intValue]);
    // 夹取：递增关系
    if (v[1] <= v[0]) v[1] = v[0] + 1;
    if (v[2] <= v[1]) v[2] = v[1] + 1;
    if (v[3] <= v[2]) v[3] = v[2] + 1;
    for (int i = 0; i < 4 && i < (int)self.judgeFields.count; i++)
        self.judgeFields[i].text = [NSString stringWithFormat:@"%d", v[i]];
    xrc_judge_set_windows(v[0], v[1], v[2], v[3]);
    float scale = (v[0] + v[1] + v[2] + v[3]) / 270.0f;
    xrc_judge_set_scale(scale);
    xrc_config_t cfg; xrc_config_load(&cfg);
    cfg.judge_max_ms = v[0]; cfg.judge_pure_ms = v[1];
    cfg.judge_far_ms = v[2]; cfg.judge_lost_ms = v[3];
    xrc_config_save(&cfg);
    if (cfg.toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"Judge +/-%d/%d/%d/%d (x%.2f)",
                              v[0], v[1], v[2], v[3], scale]
                    duration:0.8 finishHandler:^{}];
    }
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf.tag >= 4100 && tf.tag <= 4103) { [self commitJudge]; return; }
    if (tf.tag == 4201) { [self commitNet]; return; }
}

// 私服开关：改写开启后，API 请求会打到自有服务端（path/query 原样保留）
- (void)toggleNet {
    xrc_config_t c; xrc_config_load(&c);
    if (!c.net_enabled) {
        // 开之前必须先有 base，否则改了也没处可去
        UITextField *f = (UITextField *)[self viewWithTag:4201];
        NSString *base = [f.text stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
        if (!base.length) {
            [WHToast showMessage:@"请先填服务端地址（如 http://192.168.110.253:8080）"
                        duration:1.6 finishHandler:^{}];
            return;
        }
        c.net_base = base;
    }
    c.net_enabled = !c.net_enabled;
    xrc_config_save(&c);
    xrc_net_set_base(c.net_base ? c.net_base.UTF8String : NULL);
    xrc_net_set_enabled(c.net_enabled);
    [WHToast showMessage:c.net_enabled
        ? [NSString stringWithFormat:@"私服 开 → %@", c.net_base]
        : @"私服 关（走官方域）" duration:1.4 finishHandler:^{}];
    [self refresh];
}

// 拥有/解锁链开关（功能账 §1）：拥有链三层 + 故事门 + 内部计数条件判定 全部恒真
- (void)toggleUnlockAll {
    xrc_config_t c; xrc_config_load(&c);
    c.unlock_all = !c.unlock_all;
    xrc_config_save(&c);
    xrc_brk_set_unlock_all(c.unlock_all);
    [WHToast showMessage:c.unlock_all ? @"解锁全开（拥有链+故事门+条件判定 恒真）"
                                      : @"解锁恢复原判定" duration:1.4 finishHandler:^{}];
    [self refresh];
}

// cb 验证链开关（功能账 §3）：就绪恒真 + 全树校验/更新错码分发 跳过
- (void)toggleCbBypass {
    xrc_config_t c; xrc_config_load(&c);
    c.cb_bypass = !c.cb_bypass;
    xrc_config_save(&c);
    xrc_brk_set_cb_bypass(c.cb_bypass);
    [WHToast showMessage:c.cb_bypass ? @"cb 校验已跳过（改谱面/cb 自由化）"
                                     : @"cb 校验恢复" duration:1.4 finishHandler:^{}];
    [self refresh];
}

// 登录门守卫开关（功能账 §1.4）：开=解锁/领奖/联机不弹"必须在线登录"；关=复刻原行为
- (void)toggleLoginOpen {
    xrc_config_t c; xrc_config_load(&c);
    c.login_open = !c.login_open;
    xrc_config_save(&c);
    xrc_brk_set_login_open(c.login_open);
    [WHToast showMessage:c.login_open ? @"登录门已放开（解锁/领奖/联机不再拦截）"
                                      : @"登录门恢复原判定" duration:1.4 finishHandler:^{}];
    [self refresh];
}

// 保存地址（不自动开启；开关单独控制）
- (void)commitNet {
    UITextField *f = (UITextField *)[self viewWithTag:4201];
    NSString *base = [f.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
    xrc_config_t c; xrc_config_load(&c);
    c.net_base = base.length ? base : nil;
    xrc_config_save(&c);
    xrc_net_set_base(c.net_base ? c.net_base.UTF8String : NULL);
    if (c.toast) {
        [WHToast showMessage:[NSString stringWithFormat:@"服务端地址: %@",
                              base.length ? base : @"(空)"]
                    duration:1.0 finishHandler:^{}];
    }
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    b.layer.cornerRadius = 6;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refresh {
    uint32_t len = xrc_player_song_length_ms();
    uint32_t pos = xrc_player_position_ms();
    if (len == 0) len = MAX(pos, 1000);
    self.timeline.lengthMs = len;
    self.timeline.positionMs = pos;

    uint32_t from = 0, to = 0;
    BOOL loopOn = xrc_loop_get_enabled();
    xrc_loop_get_range(&from, &to);
    [self.timeline setLoopFromMs:from to:to visible:loopOn];

    uint32_t cs = pos / 1000, ts = len / 1000;
    self.timeLabel.text = [NSString stringWithFormat:@"%02u:%02u / %02u:%02u", cs/60, cs%60, ts/60, ts%60];

    float rate = (float)xrc_clock_get_rate();
    self.speedLabel.text = [NSString stringWithFormat:@"%.2fx", rate];
    if (fabs(self.speedSlider.value - rate) > 0.001f) self.speedSlider.value = rate;

    BOOL rangeOk = (to > from + 1000);
    self.onOffBtn.enabled = rangeOk || loopOn;
    self.onOffBtn.alpha = (rangeOk || loopOn) ? 1.0 : 0.4;
    [self.onOffBtn setTitle:(loopOn ? @"循环 开" : @"循环 关") forState:UIControlStateNormal];
    self.onOffBtn.backgroundColor = loopOn ? [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1.0]
                                           : [UIColor colorWithWhite:0.25 alpha:1.0];
    uint32_t fs = from / 1000, ts2 = to / 1000;
    [self.fromBtn setTitle:(from > 0 ? [NSString stringWithFormat:@"起点 %02u:%02u", fs/60, fs%60]
                                     : @"起点")
                  forState:UIControlStateNormal];
    [self.toBtn setTitle:(rangeOk ? [NSString stringWithFormat:@"终点 %02u:%02u", ts2/60, ts2%60]
                                  : (self.pendingTo ? @"终点(播放中)" : @"终点"))
                forState:UIControlStateNormal];

    // 私服开关状态 + 请求计数（计数上涨说明确有请求经过改写层）
    UIButton *nb = (UIButton *)[self viewWithTag:4200];
    if (nb) {
        BOOL on = xrc_net_enabled();
        unsigned long long req = xrc_net_requests(), rw = xrc_net_rewritten();
        [nb setTitle:[NSString stringWithFormat:@"私服 %@ %llu/%llu",
                      on ? @"开" : @"关", rw, req]
            forState:UIControlStateNormal];
        nb.backgroundColor = on ? [UIColor colorWithRed:0.1 green:0.5 blue:0.5 alpha:1.0]
                                : [UIColor colorWithWhite:0.25 alpha:1.0];
        [nb setTitleColor:on ? [UIColor whiteColor] : [UIColor systemTealColor]
                 forState:UIControlStateNormal];
    }

    // 解锁 / cb 开关状态（读运行时开关原子——策略热载翻的也会反映在这里）
    UIButton *ub = (UIButton *)[self viewWithTag:4210];
    if (ub) {
        BOOL on = xrc_brk_unlock_all();
        [ub setTitle:(on ? @"解锁 开" : @"解锁 关") forState:UIControlStateNormal];
        ub.backgroundColor = on ? [UIColor colorWithRed:0.6 green:0.1 blue:0.3 alpha:1.0]
                                : [UIColor colorWithWhite:0.25 alpha:1.0];
        [ub setTitleColor:on ? [UIColor whiteColor] : [UIColor systemPinkColor]
                 forState:UIControlStateNormal];
    }
    UIButton *cbb = (UIButton *)[self viewWithTag:4211];
    if (cbb) {
        BOOL on = xrc_brk_cb_bypass();
        [cbb setTitle:(on ? @"cb校验 开" : @"cb校验 关") forState:UIControlStateNormal];
        cbb.backgroundColor = on ? [UIColor colorWithRed:0.6 green:0.1 blue:0.3 alpha:1.0]
                                 : [UIColor colorWithWhite:0.25 alpha:1.0];
        [cbb setTitleColor:on ? [UIColor whiteColor] : [UIColor systemPinkColor]
                 forState:UIControlStateNormal];
    }
    UIButton *lgb = (UIButton *)[self viewWithTag:4212];
    if (lgb) {
        BOOL on = xrc_brk_login_open();
        [lgb setTitle:(on ? @"登录门 开（解锁/领奖/联机免登录拦截）" : @"登录门 关（原判定）")
             forState:UIControlStateNormal];
        lgb.backgroundColor = on ? [UIColor colorWithRed:0.6 green:0.1 blue:0.3 alpha:1.0]
                                 : [UIColor colorWithWhite:0.25 alpha:1.0];
        [lgb setTitleColor:on ? [UIColor whiteColor] : [UIColor systemPinkColor]
                 forState:UIControlStateNormal];
    }
    [self applyCapabilityGating];
}

// ---- SpeedSlider 语义：0.01 下限、2.0 上限、snap 0.05 ----
- (void)speedChanged:(UISlider *)s {
    float snap = roundf(s.value / 0.05f) * 0.05f;
    if (snap < 0.05f) snap = 0.05f;
    xrc_clock_set_rate((double)snap);
    self.speedLabel.text = [NSString stringWithFormat:@"%.2fx", snap];

    // 面板里的速度改动写回配置（当前预设槽，与悬浮球切速同源）
    xrc_config_set_current_speed(snap);
}

// ---- PracticeTimingControl：JumpDuration = 5000 × speed ----
- (void)jumpBack {
    uint32_t pos = xrc_player_position_ms();
    uint32_t dur = (uint32_t)(5000 * xrc_clock_get_rate());
    uint32_t target = pos > dur ? pos - dur : 0;
    xrc_gameplay_request(XRC_OP_SEEK, target);
}
- (void)jumpForward {
    uint32_t pos = xrc_player_position_ms();
    uint32_t dur = (uint32_t)(5000 * xrc_clock_get_rate());
    uint32_t len = xrc_player_song_length_ms();
    uint32_t target = pos + dur;
    if (len && target > len) target = len;
    xrc_gameplay_request(XRC_OP_SEEK, target);
}

// ---- Repeat From/To/On-Off（PracticeMenu 语义 + To >= From+1000 夹取） ----
// 循环起点 = 当前播放位置（2026-09-10 语义重排；旧版是"当前位置前 2 秒"）。
// 设起点后清掉旧终点，进入"待设终点"状态。
- (void)setFrom {
    uint32_t pos = xrc_player_position_ms();
    xrc_loop_set_enabled(false);            // 改区间先关循环
    xrc_loop_set_range(pos, 0);
    self.pendingTo = YES;
    uint32_t cs = pos / 1000;
    [WHToast showMessage:[NSString stringWithFormat:@"起点 %02u:%02u，播放到终点再按 终点",
                          cs/60, cs%60]
                duration:1.4 finishHandler:^{}];
    [self refresh];
}

- (void)setTo {
    uint32_t from = 0, oldTo = 0;
    xrc_loop_get_range(&from, &oldTo);
    BOOL hasFrom = self.pendingTo || (oldTo > from + 1000) || (from > 0);
    if (!hasFrom) {
        [WHToast showMessage:@"请先播放到起点位置按 起点" duration:1.4 finishHandler:^{}];
        return;
    }
    uint32_t pos = xrc_player_position_ms();
    if (pos < from + 1000) {
        [WHToast showMessage:@"终点需在起点 1 秒之后" duration:1.4 finishHandler:^{}];
        return;
    }
    xrc_loop_set_enabled(false);
    xrc_loop_set_range(from, pos);
    self.pendingTo = NO;
    uint32_t fs = from / 1000, ts = pos / 1000;
    [WHToast showMessage:[NSString stringWithFormat:@"循环区间 %02u:%02u - %02u:%02u，可开循环",
                          fs/60, fs%60, ts/60, ts%60]
                duration:1.4 finishHandler:^{}];
    [self refresh];
}

// 内存转储（进程内自读，不经调试器）。诊断用：结果落 Documents/xrcdemo-net/mem/
- (void)dumpMemory {
    if (xrc_dump_running()) {
        [WHToast showMessage:[NSString stringWithFormat:@"转储进行中 %d/%d",
                              xrc_dump_regions_done(), xrc_dump_regions_total()]
                    duration:1.2 finishHandler:^{}];
        return;
    }
    xrc_dump_start();
    [WHToast showMessage:@"开始转储内存（后台）" duration:1.5 finishHandler:^{}];
}

// 重置循环段落（v9.0.0）：清 A/B 与启用标志。唯一的手动清除入口。
- (void)resetLoop {
    xrc_loop_reset_all();
    self.pendingTo = NO;
    [WHToast showMessage:@"循环段落已重置" duration:1.0 finishHandler:^{}];
    [self refresh];
}

- (void)toggleRepeat {
    if (xrc_loop_get_enabled()) {
        xrc_loop_set_enabled(false);
    } else {
        uint32_t from = 0, to = 0;
        xrc_loop_get_range(&from, &to);
        if (to <= from + 1000) {
            [WHToast showMessage:@"请先设置循环起点和终点" duration:1.4 finishHandler:^{}];
            return;
        }
        xrc_loop_set_enabled(true);
    }
    [self refresh];
}

@end
