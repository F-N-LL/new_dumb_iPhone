// LightHome: covers the iOS home screen with a Light Phone style screen.
// Big clock and date on top, a short text list below. "Tools" opens the second list.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIApplication (SpringBoard)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
@end

@interface SBRootFolderView : UIView
@end

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)clickedMenuButton;
@end

@interface SpringBoard : UIApplication
- (void)_simulateHomeButtonPress;
@end

// Each row: title, then an app bundle id, a URL, or "tools"/"back" to switch lists.
static NSArray *HomeRows(void) {
    return @[
        @[@"Phone",      @"com.apple.mobilephone"],
        @[@"Messages",   @"com.apple.MobileSMS"],
        @[@"Camera",     @"com.apple.camera"],
        @[@"Directions", @"com.apple.Maps"],
        @[@"Music",      @"com.apple.Music"],
        @[@"Podcasts",   @"com.apple.podcasts"],
        @[@"Tools",      @"tools"],
    ];
}

static NSArray *ToolRows(void) {
    return @[
        @[@"Photos",     @"com.apple.mobileslideshow"],
        @[@"Alarm",      @"com.apple.mobiletimer"],
        @[@"Calendar",   @"com.apple.mobilecal"],
        @[@"Notes",      @"com.apple.mobilenotes"],
        @[@"Voice memo", @"com.apple.VoiceMemos"],
        @[@"Calculator", @"com.apple.calculator"],
        @[@"Web",        @"http://frogfind.com"],
        @[@"Settings",   @"com.apple.Preferences"],
        @[@"Back",       @"back"],
    ];
}

@interface LHHomeView : UIView
@property (nonatomic, strong) UILabel *clock;
@property (nonatomic, strong) UILabel *date;
@property (nonatomic, strong) UIView *list;
@property (nonatomic, strong) NSArray *rows;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation LHHomeView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _clock = [UILabel new];
        _clock.textColor = [UIColor whiteColor];
        _clock.font = [UIFont systemFontOfSize:72 weight:UIFontWeightUltraLight];
        [self addSubview:_clock];

        _date = [UILabel new];
        _date.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        _date.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        [self addSubview:_date];

        _list = [UIView new];
        [self addSubview:_list];

        [self showRows:HomeRows()];
        [self tick];
        _timer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    }
    return self;
}

- (void)tick {
    NSDate *now = [NSDate date];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:[NSLocale currentLocale]];
    _clock.text = [[f stringFromDate:now] stringByReplacingOccurrencesOfString:@" " withString:@""];
    f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEEdMMMM" options:0 locale:[NSLocale currentLocale]];
    _date.text = [f stringFromDate:now];
}

- (void)showRows:(NSArray *)rows {
    _rows = rows;
    for (UIView *v in _list.subviews) [v removeFromSuperview];
    [rows enumerateObjectsUsingBlock:^(NSArray *row, NSUInteger i, BOOL *stop) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightLight];
        [b setTitle:row[0] forState:UIControlStateNormal];
        BOOL nav = [row[1] isEqualToString:@"tools"] || [row[1] isEqualToString:@"back"];
        [b setTitleColor:(nav ? [UIColor colorWithWhite:0.55 alpha:1] : [UIColor whiteColor]) forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithWhite:0.3 alpha:1] forState:UIControlStateHighlighted];
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [_list addSubview:b];
    }];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, x = 28;
    _clock.frame = CGRectMake(x, 34, w - 2 * x, 84);
    _date.frame = CGRectMake(x + 3, 116, w - 2 * x, 20);
    CGFloat top = 160, rowH = MIN(42, (h - top - 16) / MAX(_rows.count, 1));
    _list.frame = CGRectMake(x, top, w - 2 * x, rowH * _rows.count);
    for (UIButton *b in _list.subviews) b.frame = CGRectMake(0, b.tag * rowH, w - 2 * x, rowH);
}

- (void)tap:(UIButton *)b {
    NSString *target = _rows[b.tag][1];
    if ([target isEqualToString:@"tools"]) { [self showRows:ToolRows()]; return; }
    if ([target isEqualToString:@"back"]) { [self showRows:HomeRows()]; return; }
    if ([target hasPrefix:@"http"]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:target]];
    } else {
        [[UIApplication sharedApplication] launchApplicationWithIdentifier:target suspended:NO];
    }
    // Next time you come home, start from the main list.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self showRows:HomeRows()];
    });
}

@end

static char kHomeKey;
static __weak LHHomeView *sHome;

// The 4S home button is broken: a quick double press on volume down acts as Home.
static void GoHome(void) {
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(_simulateHomeButtonPress)]) [sb _simulateHomeButtonPress];
    else [[%c(SBUIController) sharedInstance] clickedMenuButton];
    [sHome showRows:HomeRows()];
}

static BOOL IsDoublePress(void) {
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL dbl = now - last < 0.4;
    last = dbl ? 0 : now;
    return dbl;
}

%hook VolumeControl   // iOS 7-9
- (void)decreaseVolume {
    if (IsDoublePress()) GoHome();
    else %orig;
}
%end

%hook SBVolumeControl // iOS 10+
- (void)decreaseVolume {
    if (IsDoublePress()) GoHome();
    else %orig;
}
%end

%hook SBRootFolderView
- (void)layoutSubviews {
    %orig;
    LHHomeView *home = objc_getAssociatedObject(self, &kHomeKey);
    if (!home) {
        home = [[LHHomeView alloc] initWithFrame:self.bounds];
        objc_setAssociatedObject(self, &kHomeKey, home, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:home];
    }
    sHome = home;
    home.frame = self.bounds;
    [self bringSubviewToFront:home];
}
%end
