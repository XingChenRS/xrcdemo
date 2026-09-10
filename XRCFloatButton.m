// XRCFloatButton.m — 自绘悬浮窗实现。
// 手势：单击 onTap（开菜单）、长按 onLongPress（切速度）、拖拽移动。
// 图标：用户提供的悬浮球图片（80x80 JPEG，base64 内嵌，构建期零外部资源）。

#import "XRCFloatButton.h"

static const char kIconB64[] =
"/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBAUEBAYFBQUGBgYHCQ4JCQgICRINDQoOFRIWFhUSFBQXGiEcFxgfGRQUHScdHyIjJSUlFhwpLCgkKyEkJST/2wBDAQYGBgkICREJCREkGBQYJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCT/wAARCABQAFADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD6poopguIWmaESoZVAZkDDcAehIoAfXi37Rmu6/aW+i2Gi6pc6TDPdeXcXMMjR5ZkPlqSvO3IOffHpXtNcN8ZvCT+L/At9Z20O+8jxPAwGWDp8wx9SMfjXRhZqFWMmRNXi0j5Hu/Enjjw9fmK41/XrW4GeftsmGHqDnBFdz4N/aW8X+H5I4daMev2Q4bzQI7hR7OBg/wDAgfrWXY6lZ63ogttXilnikwyngtCw4IGenPpXJeIfCs+jql5bM9zp8o3JLtwyc4w47HPGa+glGFXSUV6f5Pc5E3HZn2f4E+Jfhz4iWRn0W8zPGMzWkw2Tw/7y+nuMj3rqq/PbSdWvdF1CDUdMu5rO9t23RzwttZT/AFHqDwa+rPg58dbXxwItE10xWevquFI+WK9A7p6N6r+I9B5OJwPKuelqu3Vf5o6IVb6SPXaKKK802Kmr6lDo2lXmpXJxBaQPPJ/uqpY/yr8/bn4jeIR41ufFNrqFxb6nLO0zTRtgjJzt91Awu08YGMV9hfH7xTpOjfDzV9Mu9Thtr/UbV47WDlpJTkZwByBjIyeOetfCDTAsT85yc8mvqMkp8lGVSS+J226L/g7+hyV3eVux9vfC74/6L4n8MpceJru10fUIRiVpm2RTj/nomenuvY+1dFf/ABl8BLp988PivTpHgjbKQyb5M442qOWP0r5Q8Oatp83hC3sIkie8IBbacugHGMduT+tRzz2UGpSE2Zgtp0Pk72yRxgHPc9/5V0V8iw7lzxbSetlaxhHGTSaa2/EwPFXjoXWsai+gwy6fY3E7SrGSC6k/e5HTJycDpnqa2fAXii+kikiu55LiBGBeJzkOhyGHNefam8balcmMjaZD06Guu+H0BaG8cgkEKoPbOSf6Vc4xUJRS2/zL7M2PEvhm2t7X+19IaRrQuVkidcGMjuOfu8/h9K52Cd4pEkjkeKWNg6SIxVkYcggjoQa77Sr57adbdyhtZnCypIoK4PBPtxXI+JtDk0HU3i8t1t5CWhZh1X0z3xmuZNvXqhs+hPh7+0rpsPhWdPGk0o1TT1AV4YtzX69AQBwHH8WcDv6ge5aXqVtrOm2upWTmS2u4lmiYggsjDIODyODXwBp9/Jp97bX8KRSTWsqzIkqBkcqc4YHgg4wRX3n4T8QWnirw3p2tWOBb3kCyqo/g45X6g5H4V5GPoQglUgt9+x0Upt6M8O/aQ+H/AIN/4mHinVvEd1aavcW2LWwJEi3DouFULjcqnAyc4BJPevmDwxoK65dyCeVoLWCMzTSKm4qoIHA7kkgV7p+0V8LrnSb+/wDF2r+KI7qK/udttaujibHURjnbsRc88D2ya8R8Oa4mi3FyjJJ9ku08qQgZYLuDAjPGQRX0uBivq8Hz8y29PJabL8zjruXvcqszofFHgy48BQwaxpl8Z4ZMKwkj2sAeRnBwR/I1S062uPGVvHLqV2ba0WZbeOOGPcXkIz3PAAP61a+IvxHtvE1qmn6fDMlsu3LzYDNtHAABOOeaxvCPiSDTRDbXrOtvFci53Iu45AxjHvxTnVbbSZyU1W9hzTXvfiJ4w8GSeGfKmSUzW0xKqzLtYMOx/wAa0fCenalaQW+ow3kI09mAm2zK2wcnDoDlc4OCQPrUPj3xnF4mkgt7RHS0gJO6QYLseM47ACtb4afCrXfiBPLFot/pqGDBcT3ISRV9RGMsR79M96nSMXKTSXVs6KDqOmvablqa4uNaZxaBobTo0zDl/Za3bTTrbWNCfQnkdZoy01u8hLcheme3Q8dMGptV0O/8K6zdeHdWRVurTBVlACzxH7rrjj6jsapI8tncLLE5SRDlWFcLqXS5Nuh0W7nEvFJaXDwzIUkjYqynsa+lP2U/FZuNO1XwtPJk2ji8tgf+ebnDgewbB/4HXivjyyMlvpusFV8y5QpO6LtUsD8vTvjg/StL4Fa+dB+KGiSFsRXjtYy88ESDC/8AjwWs8RTVSlKK6q69V/TQ4O0kfWvjLwD4d8fWcFp4hsBdx27mSIiRkZGIwcFSDyO1fL/7Rvw90vwLf2A0e20qy066i2x2ySSPcu6/fd92cryoGCOT0r6Q+KPxFg+Gnh2PVpLF7+aa5S2htkk2GRmyTzg9AD264FYXx3s9EvfhlquoatZ2IvobJjZtdKnmwysB8qE8hvp6Vx5Xi69CpDV8jbVun3fM1rQjJPufBcknzt8q9TxjFIH/ANlfyon/ANdJ/vH+dMr1nJ3ZmloaVheQGSNLqLdEGG4IQpYemcHB98V9k/Az4U+BbGKw8ceGtQ1O+klhdI/tMiDySww6MiqPmHI/X0r4lBr6V/ZC8aSWN3rWhXcjfY3hW8TJ4R1YIx56ZDLn/drPHSqVMO1F6r8V2CCUZansXxo+Gg8XaWuq6a6Q6xYHfEz8JKp4ZGPYHjnsRmvnQh3eW3uIXtru3cxzwSDDxOOoP+PevrWT4heEw/kT67piM3Gx7mPn8N1eYfFHwDpvi1X8Q+E7vTzqNug/1Uo23CDjy3xx7hu3Tp08nCVZwXJUTt0ZpOKeqPHJLFtQ8NarbB2aWILPHFngFeSwH04/GuI0q9fTtTsryI4e3uI5lPoVYH+leg+Hr6FdSZbmGSG5j3QSROvzwueMFe//ANeuIl0OdPE39hwqZJjeC2jCj7xLgLj8xXr0tXZ9H+ZzyPqn9oPw/d+JtF060smWC5tboXkE0mdhdQRtPp1zn2rx7VPA/i/xvPcXvirVoRKsT/ZbaJyyCQg4J7AZ6nk/SvrW6tIL2FoLmJJY26qwyK5i++HdjMS1pPJbn+6fmFeXgswjRgoPS3U6KlJydz8+NY0PUNJ1Ca1vLaSCZGIaNxgg/wBfqOKpC1mP/LMj6kCvvi++Fkt2AJTYXSjp58QbH5g1nr8HhECI9M0QBuDiFRn/AMdr0Pr2Glq3+P8AwDPlmfDAtZs42fqKu25uYITHH8ob72G+97GvuK3+EfldLbSYgeojgX/4kVrWHw6gsXEn2W1lkHQlFAH4AU45nQp6x/P/AIAOnN7nwP5FyRuEZx6gcVseHrLxWt7HJoVtqouM/K1nHJu/NRX3svhqXG3ZbKPTA/wqdPDsoGGnRR6KDUyzqFtvx/4AewZ4n/wrPU/FfhPStQ1Yx6b4wgj+e6iUAuAflWUDhjjGcdDnHpTPht8I/EEnxTh8Q+JLOzhgsYvPDW8oZJ7gDYpA6j+9yByBXvEPh+BP9ZI7+w4FaEFvFbLtiQIPbvXlzzBpSUOv4X7Gqpaq5//Z";

@implementation XRCFloatButton {
    UIImageView *_icon;
    CGPoint _panStart;
}

+ (instancetype)shared {
    static XRCFloatButton *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[XRCFloatButton alloc] initWithFrame:CGRectMake(8, 200, 56, 56)];
    });
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        NSData *data = [[NSData alloc] initWithBase64EncodedString:@(kIconB64)
                                                           options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *img = data ? [UIImage imageWithData:data] : nil;
        _icon = [[UIImageView alloc] initWithFrame:self.bounds];
        if (img) {
            _icon.image = img;
        } else {
            // 兜底：圆形色块 + 文字
            _icon.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
            _icon.layer.cornerRadius = self.bounds.size.width / 2;
            UILabel *lbl = [[UILabel alloc] initWithFrame:self.bounds];
            lbl.text = @"xrc";
            lbl.textColor = [UIColor whiteColor];
            lbl.font = [UIFont boldSystemFontOfSize:14];
            lbl.textAlignment = NSTextAlignmentCenter;
            [_icon addSubview:lbl];
        }
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.5;
        [self addGestureRecognizer:lp];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    if (self.onTap) self.onTap();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;
    CGPoint t = [pan translationInView:superview];
    CGPoint c = self.center;
    c.x += t.x;
    c.y += t.y;
    // 吸附边界
    CGRect b = superview.bounds;
    CGFloat half = self.bounds.size.width / 2;
    c.x = MAX(half, MIN(b.size.width - half, c.x));
    c.y = MAX(half + 60, MIN(b.size.height - half, c.y));
    self.center = c;
    [pan setTranslation:CGPointZero inView:superview];
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    [self removeFromSuperview];
    [window addSubview:self];
    [window bringSubviewToFront:self];
}

- (void)setHiddenState:(BOOL)hidden {
    self.hidden = hidden;
}

@end
