// XRCPracticePanel.m — ArcCreate 同构练习面板实现。
// 交互对齐 external/ArcCreate Assets/Scripts/Gameplay/Audio/Practice/：
//   PracticeTimeline（点击/拖动 = seek + 循环区间可视化）
//   PracticeMenu（From/To/On-Off + 速度滑杆）
//   PracticeTimingControl（±5s 跳转，时长 = 5000 × speed）
// 布局为底部半透明卡片，不遮挡判定线（ArcCreate 同为底部时间轴条）。

#import "XRCPracticePanel.h"
#import "XRCFloatButton.h"
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
@property (nonatomic, copy) void (^onRangeSelected)(uint32_t from_ms, uint32_t to_ms);
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
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStartX = p.x;
        self.rangeDragging = NO;
    }
    // 水平位移超过阈值 = 选区模式（ArcCreate 的时间轴拖动=seek，这里
    // 单指拖动用于 seek，双指/长按起手不动时切选区——简化为：拖动 = seek，
    // 长按后拖动 = 选区间）
    if (g.state == UIGestureRecognizerStateChanged) {
        if (!self.rangeDragging && fabs(p.x - _dragStartX) > 24 && g.numberOfTouches > 1) {
            self.rangeDragging = YES;
        }
        if (self.rangeDragging) {
            uint32_t a = [self msAtX:_dragStartX];
            uint32_t b = [self msAtX:p.x];
            if (a > b) { uint32_t t = a; a = b; b = t; }
            if (self.onRangeSelected) self.onRangeSelected(a, b);
        } else {
            if (self.onScrub) self.onScrub([self msAtX:p.x], NO);
        }
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (!self.rangeDragging && self.onScrub) self.onScrub([self msAtX:p.x], YES);
        self.rangeDragging = NO;
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
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) uint32_t pendingFrom;   // 第一次点 From 的暂存（ArcCreate 语义：直接取当前）
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
    CGFloat h = 148;
    CGFloat margin = 8;
    self.frame = CGRectMake(margin, w.bounds.size.height - h - margin - 34, w.bounds.size.width - margin * 2, h);
    self.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self buildIfNeeded];
    [w addSubview:self];
    [w bringSubviewToFront:self];

    // 面板打开 = 冻结时间域（视觉/谱面暂停；音频继续由 seek 语义处理）
    xrc_clock_freeze_inc();

    [self refresh];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)hide {
    [self.timer invalidate];
    self.timer = nil;
    xrc_clock_freeze_dec();
    [self removeFromSuperview];
}

- (void)tick {
    [self refresh];
}

- (void)buildIfNeeded {
    if (self.subviews.count) return;
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.88];
    self.layer.cornerRadius = 10;
    self.layer.masksToBounds = YES;

    CGFloat W = self.bounds.size.width - 20;   // 内容宽
    CGFloat y = 8;

    // 时间轴（PracticeTimeline 同构）
    self.timeline = [[XRCTimelineView alloc] initWithFrame:CGRectMake(10, y, W, 34)];
    __weak typeof(self) weakSelf = self;
    self.timeline.onScrub = ^(uint32_t ms, BOOL finished) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        if (finished) {
            // 松手 = 执行 seek（deferred 到游戏循环；seek-replay 由配置决定）
#if XRC_HAS_TRANSITION
            if (xrc_cfg_seek_replay())
                xrc_gameplay_request(XRC_OP_SEEK_REPLAY, ms);
            else
                xrc_gameplay_request(XRC_OP_SEEK, ms);
#else
            xrc_gameplay_request(XRC_OP_SEEK, ms);
#endif
        }
    };
    self.timeline.onRangeSelected = ^(uint32_t a, uint32_t b) {
        // 拖选 = 直接设置循环区间（ArcCreate SetRepeatFrom/To 的拖动版）
        if (b > a + 1000) xrc_loop_set_range(a, b);
        [weakSelf refresh];
    };
    [self addSubview:self.timeline];

    y += 40;
    // 时间显示 + 跳转（PracticeTimingControl：±5000×speed）
    self.timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, y, 110, 24)];
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.timeLabel.textColor = [UIColor whiteColor];
    [self addSubview:self.timeLabel];

    UIButton *back = [self makeButton:@"-5s" action:@selector(jumpBack)];
    back.frame = CGRectMake(W - 128, y, 56, 26);
    [self addSubview:back];
    UIButton *fwd = [self makeButton:@"+5s" action:@selector(jumpForward)];
    fwd.frame = CGRectMake(W - 66, y, 56, 26);
    [self addSubview:fwd];

    y += 32;
    // Repeat 行（PracticeMenu 的 From/To/On-Off）
    self.fromBtn = [self makeButton:@"Set From" action:@selector(setFrom)];
    self.fromBtn.frame = CGRectMake(10, y, 78, 30);
    [self addSubview:self.fromBtn];
    self.toBtn = [self makeButton:@"Set To" action:@selector(setTo)];
    self.toBtn.frame = CGRectMake(92, y, 78, 30);
    [self addSubview:self.toBtn];
    self.onOffBtn = [self makeButton:@"Repeat OFF" action:@selector(toggleRepeat)];
    self.onOffBtn.frame = CGRectMake(174, y, 110, 30);
    [self addSubview:self.onOffBtn];

    // 速度滑杆（SpeedSlider：0.01–2.0，snap 0.05）
    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, y + 4, W - 130, 28)];
    self.speedSlider.minimumValue = 0.05f;
    self.speedSlider.maximumValue = 2.0f;
    self.speedSlider.continuous = YES;
    [self.speedSlider addTarget:self action:@selector(speedChanged:) forControlEvents:UIControlEventValueChanged];
    self.speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(W - 116, y, 100, 28)];
    self.speedLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.speedLabel.textColor = [UIColor whiteColor];
    [self addSubview:self.speedLabel];
    [self addSubview:self.speedSlider];

    y += 34;
    UIButton *close = [self makeButton:@"Exit Practice" action:@selector(hide)];
    close.frame = CGRectMake(10, y, W, 30);
    [close setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self addSubview:close];
    y += 36;

    // 能力状态行（探针结论直显，替代盲试）
    self.capsLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, y, W, 16)];
    self.capsLabel.font = [UIFont systemFontOfSize:10];
    self.capsLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self addSubview:self.capsLabel];
}

// 能力门控：不可用功能禁用（避免崩溃/异常），日志同源可见。
- (void)applyCapabilityGating {
    BOOL replayOK = g_caps.replay_available;
    // 循环按钮：无转场能力则禁用（回放走转场）
    self.onOffBtn.enabled = replayOK;
    self.onOffBtn.alpha = replayOK ? 1.0 : 0.4;
    self.capsLabel.text = [NSString stringWithFormat:
        @"caps: stub=%d judge=%d gp=%d mtp=%d replay=%d",
        g_caps.stub_present, g_caps.judge_handler_live,
        g_caps.gp_hook_live, g_caps.mtp_hook_live, g_caps.replay_available];
    self.capsLabel.textColor = (g_caps.stub_present && g_caps.judge_handler_live)
        ? [UIColor colorWithWhite:0.7 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:0.6 blue:0.4 alpha:1.0];   // 改判未生效 → 橙色警示
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
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

    [self.onOffBtn setTitle:loopOn ? @"Repeat ON" : @"Repeat OFF" forState:UIControlStateNormal];
    self.onOffBtn.backgroundColor = loopOn ? [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1.0]
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
- (void)setFrom {
    uint32_t pos = xrc_player_position_ms();
    uint32_t from = pos > 2000 ? pos - 2000 : 0;
    uint32_t to = 0;
    xrc_loop_get_range(NULL, &to);
    if (to < from + 1000) to = from + 1000;
    xrc_loop_set_range(from, to);
    [self refresh];
}
- (void)setTo {
    uint32_t pos = xrc_player_position_ms();
    uint32_t from = 0;
    xrc_loop_get_range(&from, NULL);
    if (pos < from + 1000) pos = from + 1000;
    xrc_loop_set_range(from, pos);
    [self refresh];
}
- (void)toggleRepeat {
    if (xrc_loop_get_enabled()) {
        xrc_loop_set_range(0, 0);
    } else {
        uint32_t from = 0, to = 0;
        xrc_loop_get_range(&from, &to);
        if (to <= from) {   // 未设置过 → 默认当前→曲末
            from = xrc_player_position_ms();
            to = xrc_player_song_length_ms();
            if (to <= from + 1000) to = from + 1000;
        }
        xrc_loop_set_range(from, to);
    }
    [self refresh];
}

@end
