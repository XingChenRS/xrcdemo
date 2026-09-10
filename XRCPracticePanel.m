// XRCPracticePanel.m — ArcCreate 同构练习面板实现。
// 交互对齐 external/ArcCreate Assets/Scripts/Gameplay/Audio/Practice/：
//   PracticeTimeline（点击/拖动 = seek + 循环区间可视化）
//   PracticeMenu（From/To/On-Off + 速度滑杆）
//   PracticeTimingControl（±5s 跳转，时长 = 5000 × speed）
// 布局为底部半透明卡片，不遮挡判定线（ArcCreate 同为底部时间轴条）。

#import "XRCPracticePanel.h"
#import "XRCFloatButton.h"
#import "WHToast/WHToast.h"
#import "AccCommon.h"
#include "XRCConfig.h"
#include "XRCGameplay.h"
#include "XRCClock.h"
#include "XRCPlayer.h"
#include "XRCJudge.h"
#include "XRCProbe.h"
#include "XRCProfile.h"

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
@property (nonatomic, strong) UIButton *retryResumeBtn;
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
    UIButton *close = [self makeButton:@"退出" action:@selector(hide)];
    close.frame = CGRectMake(x0 + W - 70, y - 3, 70, 26);
    [close setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self addSubview:close];
    y += 20 + blockGap;

    // ---- timeline (PracticeTimeline equivalent) ----
    self.timeline = [[XRCTimelineView alloc] initWithFrame:CGRectMake(x0, y, W, 36)];
    __weak typeof(self) weakSelf = self;
    self.timeline.onScrub = ^(uint32_t ms, BOOL finished) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        if (finished) {
            // Release = seek (deferred into the game loop). replay decision 2026-09-10:
            // seek-shift IS the replay path (already-judged notes do not respawn).
            if (xrc_cfg_seek_replay())
                xrc_gameplay_request(XRC_OP_SEEK_REPLAY, ms);
            else
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

    // ---- tips（拖拽=跳转；循环 = 设起点→设终点→开循环；到终点自动重建回起点）----
    UILabel *tips = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, W, 14)];
    tips.text = @"拖时间轴=跳转 ｜ 循环: 设起点 → 播放到终点 → 设终点 → 开循环";
    tips.font = [UIFont systemFontOfSize:10];
    tips.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    tips.adjustsFontSizeToFitWidth = YES;
    tips.minimumScaleFactor = 0.8;
    [self addSubview:tips];
    y += 14 + gap;

    // ---- reset-on-retry toggle（勾选后：游戏内 retry 自动跳回练习起点）----
    self.retryResumeBtn = [self makeButton:@"重开回起点 关" action:@selector(toggleRetryResume)];
    self.retryResumeBtn.frame = CGRectMake(x0, y, W, rowH);
    [self addSubview:self.retryResumeBtn];
    y += rowH + blockGap;

    self.capsLabel = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, W, 14)];
    self.capsLabel.font = [UIFont systemFontOfSize:10];
    self.capsLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self addSubview:self.capsLabel];
    y += 14 + 2;

    self.contentHeight = y;
}

- (void)relayoutContent {
    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];
    self.timeline = nil; self.timeLabel = nil; self.speedLabel = nil;
    self.speedSlider = nil; self.fromBtn = nil; self.toBtn = nil;
    self.onOffBtn = nil; self.capsLabel = nil; self.judgeHdr = nil;
    self.judgeFields = nil; self.retryResumeBtn = nil;
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
    if (tf.tag >= 4100 && tf.tag <= 4103) [self commitJudge];
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
    BOOL resumeArmed = (xrc_gameplay_get_resume_ms() != 0);
    [self.retryResumeBtn setTitle:(resumeArmed ? @"重开回起点 开" : @"重开回起点 关")
                          forState:UIControlStateNormal];
    self.retryResumeBtn.backgroundColor = resumeArmed
        ? [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1.0]
        : [UIColor colorWithWhite:0.25 alpha:1.0];
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

- (void)toggleRetryResume {
    if (xrc_gameplay_get_resume_ms() != 0) {
        xrc_gameplay_set_resume_ms(0);   // 解除
        [WHToast showMessage:@"重开回起点：关" duration:0.8 finishHandler:^{}];
    } else {
        // capture 目标点 = 优先：已设循环的 A；否则当前播放位置
        uint32_t a = 0, b = 0;
        xrc_loop_get_range(&a, &b);
        uint32_t target = (b > a + 1000) ? a : xrc_player_position_ms();
        xrc_gameplay_set_resume_ms(target);
        uint32_t cs = target / 1000;
        [WHToast showMessage:[NSString stringWithFormat:
            @"重开回起点：开，回到 %02u:%02u", cs/60, cs%60]
                    duration:1.2 finishHandler:^{}];
    }
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
