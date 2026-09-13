#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

@interface UIScrollView (UIScroller)
@property (nonatomic,readonly) UIPanGestureRecognizer *panGestureRecognizer;
- (void)startUIScroller;
- (void)stopUIScroller;
- (void)brakeUIScroller;
- (void)autoScroll;
- (void)handleStopTouch:(UILongPressGestureRecognizer *)gesture;
- (void)stopAutoDisableTimer;
- (void)autoDisableScrolling;
- (void)startAutoNative;
- (void)stopAutoNative;
- (void)setupAutoDisableTimer;
- (void)attachStopTouchGesture;
- (void)detachStopTouchGesture;
- (void)forceLayoutVisibleCells;
- (void)applyKeepAwakeIfEnabled;
- (void)restoreKeepAwake;
@end

@interface UIWindow (UIScroller)
- (void)handleMenuLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleCornerLongPress:(UILongPressGestureRecognizer *)gesture;
@end

// CADisplayLink 的 target 会被 link 强引用；用一个只弱引用 self 的 proxy 打破循环，
// 否则 self -> associatedObject(link) -> proxy -> self 形成 retain cycle 无法释放。
@interface UIScrollerTickProxy : NSObject
@property (nonatomic, weak) UIScrollView *scrollView;
- (void)tick:(CADisplayLink *)link;
@end
@implementation UIScrollerTickProxy
- (void)tick:(CADisplayLink *)link {
    [self.scrollView autoScroll];
}
@end

// per-instance 状态存在 associated object 上，避免全局单例导致的：
//   1) NSTimer 强引用 UIScrollView 造成的对象泄漏
//   2) 多个 scroll view 共用一个 timer 互相串扰
//   3) didMoveToWindow 反复 addGestureRecognizer 造成手势累积
static const void *kScrollTimerKey      = &kScrollTimerKey;
static const void *kAutoDisableTimerKey = &kAutoDisableTimerKey;
static const void *kStopGestureKey       = &kStopGestureKey;
static const void *kMenuAddedKey        = &kMenuAddedKey;
static const void *kVerticalDownKey     = &kVerticalDownKey;
static const void *kDragVelocityKey     = &kDragVelocityKey;
static const void *kScrollStartKey      = &kScrollStartKey;
static const void *kScrollBaseOffsetKey = &kScrollBaseOffsetKey;
static const void *kScrollTravelKey     = &kScrollTravelKey;
static const void *kLastTickKey         = &kLastTickKey;
static const void *kBrakingKey          = &kBrakingKey;
static const void *kBrakeStartKey       = &kBrakeStartKey;
static const void *kTouchStartKey       = &kTouchStartKey;
static const void *kHandoffKey          = &kHandoffKey;
static const void *kHandoffOffsetKey    = &kHandoffOffsetKey;
static const void *kHandoffTimeKey      = &kHandoffTimeKey;
static const void *kIdleTimerSetKey     = &kIdleTimerSetKey;
static const void *kIdleTimerPrevKey    = &kIdleTimerPrevKey;
static const void *kContentSizeKey      = &kContentSizeKey;
static const void *kExpectedOffsetKey   = &kExpectedOffsetKey;
static const void *kExpectedSetKey      = &kExpectedSetKey;
static const void *kEdgeWaitKey         = &kEdgeWaitKey;
static const void *kEdgeWaitSizeKey     = &kEdgeWaitSizeKey;
// ── 自动档：原生续滚（挂系统自己的滚动动画，不自己写 offset）──
static const void *kAutoActiveKey       = &kAutoActiveKey;
static const void *kCornerGestureKey    = &kCornerGestureKey;
static const void *kAutoV0Key           = &kAutoV0Key;
static const void *kAutoStartTimeKey    = &kAutoStartTimeKey;
static const void *kAutoLastYKey        = &kAutoLastYKey;
static const void *kAutoLastTKey        = &kAutoLastTKey;
static const void *kAutoStallKey        = &kAutoStallKey;
static const void *kOrigFactorKey       = &kOrigFactorKey;
// 私有 API（_verticalVelocity）维持无效时置 YES：本进程内自动档退回我们自己的驱动
static BOOL nativeSustainBroken = NO;
// 常亮兜底重断言的帧计数（每 60 帧写一次 idleTimerDisabled）
static int uscAwakeTick = 0;

int scrollSpeedType = 4;    // 0:慢速 1:标准 2:较快 3:快速 4:自动（跟随滑动力道，默认）
int autoDisableMinutes = 0; // 0: Disabled, >0: Minutes until auto-disable
BOOL keepScreenAwake = NO;  // 自动滚动期间禁止息屏（默认关，菜单里可开）
int autoForceMultiplier = 100; // 自动档力道倍率（%）：100=1×，菜单可选 0.5/1/1.5/2
int cornerGestureSide = 0;  // 角落手势位置：0=左下 1=右下（可按 App 禁用，见 cornerDisabledKey）
int gearSpeedAdjust = 0;    // 固定挡速度微调（pt/s）：菜单 ±100 细调基准档位

// 速度档位名（菜单显示用）
static NSString *speedName(int type) {
    switch (type) {
        case 1:  return @"标准";
        case 2:  return @"较快";
        case 3:  return @"快速";
        case 4:  return @"自动（跟随滑动力道）";
        default: return @"慢速"; // 0
    }
}

// ── 固定挡（慢速/标准/较快/快速）：起步速度收敛到稳态速度的时间常数（秒）──
// 接管瞬间速度 = 交接实测速度 V（= 手上力道），随后按 e^(-t/tau) 平滑收到档位速度。
// 1.2s 比原来的 0.45s 舒缓得多：既不会在起步瞬间急刹（"顿一下"），又能较快进入稳定阅读速度。
static const CFTimeInterval kGearEaseTau = 1.2;
// 固定挡档位速度（pt/s）
static const float kGearSpeed[4] = { 80.0f, 160.0f, 240.0f, 320.0f };
// ── 自动档（松手即自动滚，速度跟随力道，一直滚到用户手动停）──
// 巡航速度安全上限（pt/s）：只是防止异常数值导致飞天；正常甩动到不了这个量级，实际速度 = 力道。
static const float kAutoCruiseMax = 3000.0f;
// 收尾衰减时间常数（秒）：起步速度 = 交接瞬间的真实速度，之后按 e^(-t/tau) 极缓慢地收，
// 8s ≈ 10 秒后还有一半速度，既有"一直滚"的持久感，又不会像匀速那样机械。
static const CFTimeInterval kAutoDecayTau = 8.0;
// 实测交接速度的合理上限（pt/s）：超过就认为观察窗口被 App 自己的 offset 变动污染了，
// 回退用松手速度。否则会拿到离谱的速度直接冲到内容边界（表现为"瞬间到顶部"）。
static const float kAutoVelocitySanity = 4000.0f;
// 停止阈值（pt/s）：衰减到该速度以下结束驱动（已慢到看不出在动）。[CADisplayLink 回退驱动用]
static const float kAutoStopSpeed = 20.0f;
// ── 原生续滚（pxcex 同款算法，常量取自其 dylib 反汇编）──
// 单位关键知识：UIScrollView 私有 ivar _verticalVelocity 的单位是 pt/ms
// （0.1~1.0 pt/ms ≈ 100~1000 pt/s，正是普通甩动的收尾速度段）。
// 收尾区间下限：|v| < 0.1 pt/ms（<100pt/s）不再钉系数，交还系统自然滑停。
static const double kAutoNativeStopV = 0.1;
// 衰减系数原厂值参考（dylib 常量 0x3FEFE00000000000）：系统每帧乘数 = factor/2 ≈ 0.996。
// 实际恢复用的原值在第一次钉住时从 ivar 里实测保存（见 hook 内 kOrigFactorKey）。
// 钉住值 = (double)(float)(PinBase + |v|*PinEps)，pxcex 反汇编逐字对应：
// 0.999999404 是 float 1.0 以下最近的值；eps 项让钉值随速度微增（纯装饰，量级 1e-7）。
// ≈1 => 系统几乎不减速，以"进入收尾区间那一刻自己的速度"近乎匀速滑下去。
static const double kAutoNativePinBase = 0.9999994039535522;
static const double kAutoNativePinEps  = 5.364418e-07;
// 续滚巡航上限（pt/ms）：再快就写入超出甩动正常量级的速度，列表来不及物化单元格会空白。
// 1.0 pt/ms = 1000pt/s = pxcex 反汇编里收尾区间的上限，重甩到这个量级后就从 1000 缓收。
static const double kAutoNativeCruiseMaxV = 1.0;

// 关键差异（血泪教训）：不能用 KVC（setValue:forKey:）写这两个私有 ivar ——
// UIScrollView 的私有 setter 会拦截/钳制写入，表现为"自动档没作用"或"急刹"。
// pxcex 用 class_getInstanceVariable + ivar_getOffset 直捣内存，我们也逐字节等价地这么干。
//
// 性能：ivar 定义在 UIScrollView 上，实例布局固定 => 偏移只解析一次并缓存，
// 之后每帧直接"对象地址 + 偏移"，省掉两次 class_getInstanceVariable/ivar_getOffset。
static ptrdiff_t uscVelOffset = -1;
static ptrdiff_t uscFacOffset = -1;
static void uscResolveOffsets(void) {
    Ivar v = class_getInstanceVariable([UIScrollView class], "_verticalVelocity");
    Ivar f = class_getInstanceVariable([UIScrollView class], "_decelerationFactor");
    uscVelOffset = v ? ivar_getOffset(v) : -1;
    uscFacOffset = f ? ivar_getOffset(f) : -1;
}
static inline double *usc_velPtr(id obj) {
    if (uscVelOffset < 0) uscResolveOffsets();
    if (uscVelOffset < 0) return NULL;
    return (double *)((char *)(__bridge void *)obj + uscVelOffset);
}
static inline double *usc_facPtr(id obj) {
    if (uscFacOffset < 0) uscResolveOffsets();
    if (uscFacOffset < 0) return NULL;
    return (double *)((char *)(__bridge void *)obj + uscFacOffset);
}

// 贴边等待时长（秒）：现在只用于固定挡/回退的 CADisplayLink 驱动路径
// （滚到尽头再等一会儿唤起加载更多）。自动档的原生续滚已按用户要求去掉贴边行为
// —— 顶到内容尽头就一直贴着，直到用户触摸停止或定时自动关（pxcex 行为）。
static const CFTimeInterval kEdgeWaitTimeout = 1.0;
// 贴边即停：offset 连续这么久没动就交还系统（秒）。
// 用户确认不要"顶着等"：滚不动就立刻停。留 0.3s 只是为了排除单帧卡顿/取整导致的误判，
// 0.3s 之外没有可感知的顶边时间。注意它和固定挡回退路径的 kEdgeWaitTimeout 是两回事。
static const CFTimeInterval kEdgeStallTime = 0.3;

// 自动档的甩动触发阈值（pt/s）：故意比固定挡的 700 低很多——
// 轻轻一甩也会自动延续，且滚动速度完全跟随力道（甩得快滚得快、甩得慢滚得慢，pxcex 行为）。
// 拉低后不必担心误触：微信下拉面板/滚轮/回弹区仍由各自的守卫拦住。
// 200pt/s ≈ 每秒划过 1/4 屏高：比原来 300 更灵敏，随手轻甩就能触发自动滚动。
// 再往下调要小心：太低的慢速拖动也会被接管，就没法"手动慢慢滑"了。
static const float kAutoTriggerAuto = 200.0f;
// 刹车时长（秒）：停止时做匀减速（像摩擦制动）滑到 0，而不是瞬间定住。
// 0.35s 既刹得住又不会显得生硬；想要更干脆就调小。
static const CFTimeInterval kBrakeDuration = 0.35;
// 接管阈值：松手速度达到该值(pt/s)才进入自动滚动；低于它不接管，留给用户自然手动滑。
// 没有它的话每一次甩动都会被劫持，用户就没法连续快速地手动滑了。
static const float kAutoTriggerVelocity = 700.0f;
// "按住即停"需要按住的时长（秒）：设成 0 会让连续快速甩动时每一次触屏都触发刹车，
// 干扰手动滑。0.25s 足以过滤掉甩动（甩动从触屏到抬手一般 <0.15s），又不会觉得迟钝。
static const NSTimeInterval kStopTouchDuration = 0.25;
// ── 菜单手势：左下角长按（与三指长按并存，哪个顺手用哪个）──
// 触发扇形半径（pt）：圆心 = 屏幕左下角点。56pt ≈ 指甲盖大的角尖区域，
// 不会被列表滑动摸到；与 tab 栏最左端按钮的重叠场景由菜单里的"禁用角落手势"按 App 关掉。
static const CGFloat kMenuCornerRadius = 56.0f;
// 按住时长（秒）：比"按住即停"的 0.25s 长 —— 自动滚动中按角落先触发即停，
// 继续按满 0.6s 再弹菜单，一次按住两件事互不抢。
static const NSTimeInterval kMenuCornerHold = 0.6;
// 接管还要求内容真的够滚（可滚距离下限 pt）：像微信下拉小程序面板这种一屏放得下的视图，
// 没有可滚的距离，接管只会打断它自己的回弹/动画，看起来就是卡住
static const float kMinScrollableTravel = 120.0f;

// per-app 禁用 key（原版用全局 key，UI 写 "Disable for this app" 但实际禁用所有 app）
static NSString *disabledKey() {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [NSString stringWithFormat:@"uiscroller_disabled_%@", bid];
}

// 左下角长按菜单手势的 per-app 禁用 key：部分 App 底部角落有自己的长按功能
// （拖拽排序、清除角标等），这种 App 在菜单里关掉角落手势即可 —— 三指长按仍可弹菜单。
static NSString *cornerDisabledKey() {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [NSString stringWithFormat:@"uiscroller_corner_disabled_%@", bid];
}

// 判断 scroll view 是否在 WKWebView/UIWebView 内部（往 WKScrollView 上挂 tap 会让网页输入框点不动）
static BOOL scrollViewInsideWebView(UIScrollView *sv) {
    static Class wkClass = nil;
    static Class uiClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        wkClass = NSClassFromString(@"WKWebView");
        uiClass = NSClassFromString(@"UIWebView");
    });
    if (!wkClass && !uiClass) return NO;
    for (UIView *v = sv.superview; v; v = v.superview) {
        if ((wkClass && [v isKindOfClass:wkClass]) || (uiClass && [v isKindOfClass:uiClass])) return YES;
    }
    return NO;
}

// 判断 scroll view 是否在 UIDatePicker / UIPickerView 内部（接管后滚轮会一直转，无法选时间）
static BOOL scrollViewInsidePicker(UIScrollView *sv) {
    static Class dpClass = nil;
    static Class pkClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dpClass = NSClassFromString(@"UIDatePicker");
        pkClass = NSClassFromString(@"UIPickerView");
    });
    if (!dpClass && !pkClass) return NO;
    for (UIView *v = sv.superview; v; v = v.superview) {
        if ((dpClass && [v isKindOfClass:dpClass]) || (pkClass && [v isKindOfClass:pkClass])) return YES;
    }
    return NO;
}

id topViewController() {
    UIWindow *keyWindow = nil;
    NSArray *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    UIViewController *rootController = keyWindow.rootViewController;
    UIViewController *topController = rootController;
    while (topController.presentedViewController) topController = topController.presentedViewController;
    if ([topController isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)topController).selectedViewController;
        if (selected) topController = selected;
    }
    if ([topController isKindOfClass:[UINavigationController class]]) {
        UIViewController *visibleController = ((UINavigationController *)topController).visibleViewController;
        if (visibleController) topController = visibleController;
    }
    if (topController != rootController) return topController;
    else return rootController;
}

// ── 自动停止倒计时胶囊 ──
// 顶部居中毛玻璃胶囊：滚动期间全程半透明显示 mm:ss（不打扰阅读），
// 最后 10 秒变实 + 变色（≤10 琥珀、≤5 红）+ 每秒轻微脉冲。
// 关键：userInteractionEnabled = NO，绝不挡 App 自己的触摸。
static UIView  *hudCapsule  = nil;
static UILabel *hudTimeLabel = nil;
static UIView  *hudDot      = nil;

static UIView *hudEnsureCapsule(void) {
    if (hudCapsule && hudCapsule.superview) return hudCapsule;
    UIWindow *host = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowLevel == UIWindowLevelNormal && !w.hidden) { host = w; break; }
    }
    if (!host) return nil;
    if (!hudCapsule) {
        hudCapsule = [[UIView alloc] initWithFrame:CGRectZero];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        blur.frame = hudCapsule.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.userInteractionEnabled = NO;
        [hudCapsule addSubview:blur];

        hudDot = [[UIView alloc] initWithFrame:CGRectZero];
        hudDot.backgroundColor = [UIColor systemGreenColor];
        hudDot.layer.cornerRadius = 4.0;
        [hudCapsule addSubview:hudDot];

        hudTimeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        hudTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        hudTimeLabel.textColor = [UIColor labelColor];
        [hudCapsule addSubview:hudTimeLabel];

        hudCapsule.layer.cornerRadius = 16.0;
        hudCapsule.layer.masksToBounds = YES;
        hudCapsule.userInteractionEnabled = NO; // 不挡触摸
    }
    [host addSubview:hudCapsule];
    return hudCapsule;
}

static void updateCountdownHUD(int seconds) {
    if (seconds <= 0) { hudCapsule.hidden = YES; return; }
    UIView *cap = hudEnsureCapsule();
    if (!cap) return;
    hudTimeLabel.text = [NSString stringWithFormat:@"自动停止 %02d:%02d", seconds / 60, seconds % 60];
    [hudTimeLabel sizeToFit];
    CGFloat w = CGRectGetWidth(hudTimeLabel.bounds) + 38.0; // dot 8 + 间距 + 左右 padding
    CGFloat h = 32.0;
    UIView *host = cap.superview;
    CGFloat top = 26.0;
    if (@available(iOS 11.0, *)) top = host.safeAreaInsets.top + 6.0;
    cap.frame = CGRectMake((CGRectGetWidth(host.bounds) - w) / 2.0, top, w, h);
    cap.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    hudDot.frame = CGRectMake(12.0, (h - 8.0) / 2.0, 8.0, 8.0);
    hudTimeLabel.frame = CGRectMake(26.0, (h - CGRectGetHeight(hudTimeLabel.bounds)) / 2.0,
                                    CGRectGetWidth(hudTimeLabel.bounds), CGRectGetHeight(hudTimeLabel.bounds));

    // 状态：≤10 秒变实+琥珀，≤5 秒变红，其余半透明绿点
    BOOL urgent   = seconds <= 10;
    BOOL critical = seconds <= 5;
    cap.alpha = urgent ? 1.0 : 0.55;
    UIColor *accent = critical ? [UIColor systemRedColor] : (urgent ? [UIColor systemOrangeColor] : [UIColor systemGreenColor]);
    hudDot.backgroundColor = accent;
    hudTimeLabel.textColor = urgent ? accent : [UIColor labelColor];
    if (urgent) {
        // 每秒一次轻微脉冲，余量感知
        [UIView animateWithDuration:0.14 animations:^{ cap.transform = CGAffineTransformMakeScale(1.06, 1.06); }
                         completion:^(BOOL f){ [UIView animateWithDuration:0.14 animations:^{ cap.transform = CGAffineTransformIdentity; }]; }];
    }
    cap.hidden = NO;
}

static void hideCountdownHUD(void) {
    hudCapsule.hidden = YES;
}

// 防重入：菜单/面板同时只允许一个实例存在
static BOOL menuBusy = NO;

// ── 自定义控制面板（替代 UIAlertController 菜单）──
// 底部半屏卡片：毛玻璃背景 + 顶部圆角 + 分段控件/滑杆/开关，点卡片外即关。
// 不走 presentViewController —— 顺手绕开了弹窗异步导致的菜单卡死类问题。
static UIView            *controlBackdrop = nil;
static UIView            *controlPanel    = nil;
static UILabel           *cpSummaryLabel  = nil;
static UILabel           *cpAdjustValue   = nil;
static UILabel           *cpAutoStopValue = nil;
static UIButton          *cpDisableAppBtn = nil;

static NSString *cpSummaryText(void) {
    NSString *corner = [[NSUserDefaults standardUserDefaults] boolForKey:cornerDisabledKey()] ? @"角落关"
                       : (cornerGestureSide == 0 ? @"左下" : @"右下");
    return [NSString stringWithFormat:@"%@ · %.1f× · %@", speedName(scrollSpeedType), autoForceMultiplier / 100.0, corner];
}

static void cpRefreshSummary(void) {
    if (cpSummaryLabel) cpSummaryLabel.text = cpSummaryText();
}

// 角落手势开关：同步写 per-app 偏好 + 翻转所有已挂窗口识别器的 enabled
// （enabled=NO 才是真禁用，handler 里 early-return 挡不住触摸被 cancel）
static void cpSetCornerEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:(!enabled) forKey:cornerDisabledKey()];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UILongPressGestureRecognizer *g = objc_getAssociatedObject(w, kCornerGestureKey);
        if (g) g.enabled = enabled;
    }
}

static void closeControlPanel(void) {
    if (!controlBackdrop) return;
    UIView *backdrop = controlBackdrop, *panel = controlPanel;
    controlBackdrop = nil; controlPanel = nil;
    [UIView animateWithDuration:0.22 animations:^{
        backdrop.alpha = 0;
        panel.transform = CGAffineTransformMakeTranslation(0, CGRectGetHeight(panel.bounds));
    } completion:^(BOOL finished) {
        [backdrop removeFromSuperview];
        [panel removeFromSuperview];
        // 面板已销毁，静态控件引用一并置空，防止悬垂指针
        cpSummaryLabel = nil; cpAdjustValue = nil; cpAutoStopValue = nil; cpDisableAppBtn = nil;
        menuBusy = NO;
    }];
}

static UILabel *cpSectionLabel(NSString *text) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11.0];
    l.textColor = [UIColor secondaryLabelColor];
    return l;
}

static void editAutoStopMinutes(void) {
    UIAlertController *inputAlert = [UIAlertController alertControllerWithTitle:@"设置自动停止时间"
                                                                        message:@"输入分钟数（0 表示关闭）"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.placeholder = @"分钟";
        textField.text = [NSString stringWithFormat:@"%d", autoDisableMinutes];
    }];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        int minutes = [inputAlert.textFields.firstObject.text intValue];
        if (minutes < 0) minutes = 0;
        if (minutes > 180) minutes = 180;
        autoDisableMinutes = minutes;
        if (cpAutoStopValue) cpAutoStopValue.text = minutes == 0 ? @"关闭" : [NSString stringWithFormat:@"%d 分钟", minutes];
    }];
    [inputAlert addAction:confirm];
    [inputAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:inputAlert animated:YES completion:nil];
}

// ── 面板事件分发：UIControl target-action 需要一个常驻对象接住回调，用单例 proxy ──
@interface USControlPanelProxy : NSObject
- (void)cp_speedChanged:(UISegmentedControl *)seg;
- (void)cp_multChanged:(UISegmentedControl *)seg;
- (void)cp_cornerChanged:(UISegmentedControl *)seg;
- (void)cp_sliderChanged:(UISlider *)slider;
- (void)cp_awakeChanged:(UISwitch *)sw;
- (void)cp_editStop;
- (void)cp_toggleDisableApp;
- (void)cp_close;
@end

@implementation USControlPanelProxy
- (void)cp_speedChanged:(UISegmentedControl *)seg {
    scrollSpeedType = (int)seg.selectedSegmentIndex;
    cpRefreshSummary();
}
- (void)cp_multChanged:(UISegmentedControl *)seg {
    autoForceMultiplier = 50 + (int)seg.selectedSegmentIndex * 50; // 0.5×/1×/1.5×/2×
    cpRefreshSummary();
}
- (void)cp_cornerChanged:(UISegmentedControl *)seg {
    if (seg.selectedSegmentIndex == 2) {
        cpSetCornerEnabled(NO);
    } else {
        cornerGestureSide = (int)seg.selectedSegmentIndex;
        cpSetCornerEnabled(YES); // 切位置顺手把"关"状态解开
    }
    cpRefreshSummary();
}
- (void)cp_sliderChanged:(UISlider *)slider {
    int snapped = (int)lroundf(slider.value / 20.0f) * 20; // 20 pt/s 步进，避免拖出零碎值
    if (snapped > 100) snapped = 100;
    if (snapped < -100) snapped = -100;
    gearSpeedAdjust = snapped;
    if (cpAdjustValue) cpAdjustValue.text = [NSString stringWithFormat:@"%+d pt/s", snapped];
}
- (void)cp_awakeChanged:(UISwitch *)sw {
    keepScreenAwake = sw.on;
    // 关闭时正在进行的滚动会在 stop 路径里自动还原息屏策略（restoreKeepAwake）
}
- (void)cp_editStop {
    editAutoStopMinutes();
}
- (void)cp_toggleDisableApp {
    BOOL nowDisabled = ![[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
    [[NSUserDefaults standardUserDefaults] setBool:nowDisabled forKey:disabledKey()];
    if (cpDisableAppBtn) [cpDisableAppBtn setTitle:(nowDisabled ? @"已禁用此应用（点按启用）" : @"禁用此应用") forState:UIControlStateNormal];
}
- (void)cp_close {
    closeControlPanel();
}
@end

static USControlPanelProxy *cpTargetProxy(void) {
    static USControlPanelProxy *proxy = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ proxy = [[USControlPanelProxy alloc] init]; });
    return proxy;
}

void openSimpleMenu() {
    if (menuBusy || controlBackdrop) return;
    UIViewController *presenter = topViewController();
    if (!presenter) return;
    if ([presenter isKindOfClass:[UIAlertController class]]) return; // 已有系统弹窗在最上层
    if (presenter.presentedViewController) return;                   // 正在展示别的弹窗

    UIWindow *host = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && w.windowLevel == UIWindowLevelNormal) { host = w; break; }
    }
    if (!host) return;
    menuBusy = YES;

    // 背景：轻遮罩，点击即关
    controlBackdrop = [[UIView alloc] initWithFrame:host.bounds];
    controlBackdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    controlBackdrop.alpha = 0;
    // 点击遮罩关闭的手势在末尾统一挂（target = cpTargetProxy，走 cp_close 带动画关闭）

    // 面板：底部半屏卡片
    controlPanel = [[UIView alloc] initWithFrame:CGRectZero];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [controlPanel addSubview:blur];
    controlPanel.layer.cornerRadius = 20.0;
    controlPanel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    controlPanel.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6.0;
    stack.layoutMargins = UIEdgeInsetsMake(4, 16, 16, 16);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    // 抓手
    UIView *grabberWrap = [[UIView alloc] init];
    grabberWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [grabberWrap.heightAnchor constraintEqualToConstant:14].active = YES;
    UIView *grab = [[UIView alloc] initWithFrame:CGRectMake(0, 5, 36, 4)];
    grab.backgroundColor = [UIColor systemGray3Color];
    grab.layer.cornerRadius = 2.0;
    grab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [grabberWrap addSubview:grab];
    [stack addArrangedSubview:grabberWrap];

    // 标题 + 状态摘要
    UIStackView *headRow = [[UIStackView alloc] init];
    headRow.axis = UILayoutConstraintAxisHorizontal;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"UIScroller v3"; // 临时版本标记，确认真机装上了新 deb 再恢复
    title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    cpSummaryLabel = [[UILabel alloc] init];
    cpSummaryLabel.font = [UIFont systemFontOfSize:11.0];
    cpSummaryLabel.textColor = [UIColor secondaryLabelColor];
    cpSummaryLabel.textAlignment = NSTextAlignmentRight;
    cpSummaryLabel.text = cpSummaryText();
    [headRow addArrangedSubview:title];
    [headRow addArrangedSubview:cpSummaryLabel];
    [stack addArrangedSubview:headRow];

    // 速度档位
    [stack addArrangedSubview:cpSectionLabel(@"速度档位")];
    UISegmentedControl *speedSeg = [[UISegmentedControl alloc] initWithItems:@[@"慢速", @"标准", @"较快", @"快速", @"自动"]];
    speedSeg.selectedSegmentIndex = (scrollSpeedType >= 0 && scrollSpeedType <= 4) ? scrollSpeedType : 4;
    [stack addArrangedSubview:speedSeg];

    // 速度微调
    [stack addArrangedSubview:cpSectionLabel(@"速度微调（固定挡生效）")];
    UIStackView *sliderRow = [[UIStackView alloc] init];
    sliderRow.axis = UILayoutConstraintAxisHorizontal;
    sliderRow.spacing = 10;
    sliderRow.alignment = UIStackViewAlignmentCenter;
    UISlider *slider = [[UISlider alloc] init];
    slider.minimumValue = -100; slider.maximumValue = 100;
    slider.value = gearSpeedAdjust;
    cpAdjustValue = [[UILabel alloc] init];
    cpAdjustValue.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    cpAdjustValue.textColor = [UIColor systemGreenColor];
    cpAdjustValue.text = [NSString stringWithFormat:@"%+d pt/s", gearSpeedAdjust];
    [cpAdjustValue.widthAnchor constraintEqualToConstant:62].active = YES;
    cpAdjustValue.textAlignment = NSTextAlignmentRight;
    [sliderRow addArrangedSubview:slider];
    [sliderRow addArrangedSubview:cpAdjustValue];
    [stack addArrangedSubview:sliderRow];

    // 力道倍率
    [stack addArrangedSubview:cpSectionLabel(@"力道倍率（自动档）")];
    UISegmentedControl *multSeg = [[UISegmentedControl alloc] initWithItems:@[@"0.5×", @"1×", @"1.5×", @"2×"]];
    multSeg.selectedSegmentIndex = (autoForceMultiplier - 50) / 50; // 50->0 100->1 150->2 200->3
    if (multSeg.selectedSegmentIndex < 0 || multSeg.selectedSegmentIndex > 3) multSeg.selectedSegmentIndex = 1;
    [stack addArrangedSubview:multSeg];

    // 屏幕常亮
    UIStackView *awakeRow = [[UIStackView alloc] init];
    awakeRow.axis = UILayoutConstraintAxisHorizontal;
    awakeRow.alignment = UIStackViewAlignmentCenter;
    UILabel *awakeLabel = [[UILabel alloc] init];
    awakeLabel.text = @"屏幕常亮";
    awakeLabel.font = [UIFont systemFontOfSize:13.0];
    awakeLabel.textColor = [UIColor labelColor];
    UISwitch *awakeSwitch = [[UISwitch alloc] init];
    awakeSwitch.on = keepScreenAwake;
    awakeSwitch.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [awakeRow addArrangedSubview:awakeLabel];
    [awakeRow addArrangedSubview:awakeSwitch];
    [stack addArrangedSubview:awakeRow];

    // 自动停止
    UIStackView *stopRow = [[UIStackView alloc] init];
    stopRow.axis = UILayoutConstraintAxisHorizontal;
    stopRow.alignment = UIStackViewAlignmentCenter;
    UILabel *stopLabel = [[UILabel alloc] init];
    stopLabel.text = @"自动停止";
    stopLabel.font = [UIFont systemFontOfSize:13.0];
    stopLabel.textColor = [UIColor labelColor];
    cpAutoStopValue = [[UILabel alloc] init];
    cpAutoStopValue.font = [UIFont systemFontOfSize:12.0];
    cpAutoStopValue.textColor = [UIColor secondaryLabelColor];
    cpAutoStopValue.text = autoDisableMinutes == 0 ? @"关闭" : [NSString stringWithFormat:@"%d 分钟", autoDisableMinutes];
    cpAutoStopValue.textAlignment = NSTextAlignmentRight;
    UIButton *editStop = [UIButton buttonWithType:UIButtonTypeSystem];
    [editStop setTitle:@"编辑" forState:UIControlStateNormal];
    editStop.titleLabel.font = [UIFont systemFontOfSize:13.0];
    [stopRow addArrangedSubview:stopLabel];
    [stopRow addArrangedSubview:cpAutoStopValue];
    [stopRow addArrangedSubview:editStop];
    [stack addArrangedSubview:stopRow];

    // 角落手势（左下/右下/关 三段）
    UIStackView *cornerRow = [[UIStackView alloc] init];
    cornerRow.axis = UILayoutConstraintAxisHorizontal;
    cornerRow.alignment = UIStackViewAlignmentCenter;
    UILabel *cornerLabel = [[UILabel alloc] init];
    cornerLabel.text = @"角落手势";
    cornerLabel.font = [UIFont systemFontOfSize:13.0];
    cornerLabel.textColor = [UIColor labelColor];
    BOOL cornerOff = [[NSUserDefaults standardUserDefaults] boolForKey:cornerDisabledKey()];
    UISegmentedControl *cornerSeg = [[UISegmentedControl alloc] initWithItems:@[@"左下", @"右下", @"关"]];
    cornerSeg.selectedSegmentIndex = cornerOff ? 2 : cornerGestureSide;
    [cornerSeg.widthAnchor constraintEqualToConstant:150].active = YES;
    [cornerRow addArrangedSubview:cornerLabel];
    [cornerRow addArrangedSubview:cornerSeg];
    [stack addArrangedSubview:cornerRow];

    // 禁用此应用（红色整行按钮）
    BOOL isDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
    cpDisableAppBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cpDisableAppBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    cpDisableAppBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    [cpDisableAppBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [cpDisableAppBtn setTitle:(isDisabled ? @"已禁用此应用（点按启用）" : @"禁用此应用") forState:UIControlStateNormal];
    [cpDisableAppBtn.heightAnchor constraintEqualToConstant:34].active = YES;
    [stack addArrangedSubview:cpDisableAppBtn];

    // 布局：彻底放弃手动测量，改用 Auto Layout 内容驱动高度。
    // 之前两版手动测量在真机上总翻车，导致面板整屏炸裂；这次让 stack 的 intrinsic
    // content 高度通过约束链自己决定 panel 高度，并用 transform 动画上滑/下滑。
    [stack setContentHuggingPriority:999 forAxis:UILayoutConstraintAxisVertical]; // 让内容决定高度，但允许 90% 上限覆盖

    controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    blur.translatesAutoresizingMaskIntoConstraints = NO;

    [host addSubview:controlBackdrop];
    [host addSubview:controlPanel];

    // blur 铺满 panel
    [controlPanel addSubview:blur];
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:controlPanel.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:controlPanel.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:controlPanel.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:controlPanel.trailingAnchor],
    ]];

    // stack 填满 contentView，底部留安全区
    [blur.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:blur.contentView.safeAreaLayoutGuide.bottomAnchor],
    ]];

    // 面板宽度铺满 host，底部贴 host 底；高度由内容决定（顶部不钉），加 90% 屏高上限兜底
    [NSLayoutConstraint activateConstraints:@[
        [controlPanel.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [controlPanel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [controlPanel.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [controlPanel.heightAnchor constraintLessThanOrEqualToAnchor:host.heightAnchor multiplier:0.9],
    ]];

    // 立即 layout，让 Auto Layout 算出内容真实高度
    [controlPanel setNeedsLayout];
    [controlPanel layoutIfNeeded];

    // 抓手居中（此时 grabberWrap 已铺到 stack 实际宽度）
    grab.center = CGPointMake(CGRectGetWidth(grabberWrap.bounds) / 2.0, 7);

    // 初始位置：面板整体下移到刚好藏到屏幕下方，然后动画上滑
    controlPanel.transform = CGAffineTransformMakeTranslation(0, CGRectGetHeight(controlPanel.bounds));

    // 事件绑定：全部走单例 proxy 分发（见 USControlPanelProxy）
    USControlPanelProxy *proxy = cpTargetProxy();
    [speedSeg addTarget:proxy action:@selector(cp_speedChanged:) forControlEvents:UIControlEventValueChanged];
    [multSeg addTarget:proxy action:@selector(cp_multChanged:) forControlEvents:UIControlEventValueChanged];
    [cornerSeg addTarget:proxy action:@selector(cp_cornerChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:proxy action:@selector(cp_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [awakeSwitch addTarget:proxy action:@selector(cp_awakeChanged:) forControlEvents:UIControlEventValueChanged];
    [editStop addTarget:proxy action:@selector(cp_editStop) forControlEvents:UIControlEventTouchUpInside];
    [cpDisableAppBtn addTarget:proxy action:@selector(cp_toggleDisableApp) forControlEvents:UIControlEventTouchUpInside];

    // 背景点击关闭（用手势代理挂 selector 到 proxy）
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:cpTargetProxy() action:@selector(cp_close)];
    [controlBackdrop addGestureRecognizer:tap];

    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        controlBackdrop.alpha = 1;
        controlPanel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

%hook UIWindow

    - (void)becomeKeyWindow {
        %orig;
        if (objc_getAssociatedObject(self, kMenuAddedKey)) return; // 去重：每个 window 只加一次
        // 只给主窗口（normal level）加菜单手势，避开键盘/弹窗等高 level 窗口
        if (self.windowLevel != UIWindowLevelNormal) return;
        UILongPressGestureRecognizer *menuGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuLongPress:)];
        menuGestureRecognizer.numberOfTouchesRequired = 3;
        [self addGestureRecognizer:menuGestureRecognizer];
        // 左下角长按：单指按住 0.6s，比三指长按好按且几乎不会误触（见 handleCornerLongPress 内守卫）。
        // enabled 必须跟 per-app 开关同步：识别器只要 enabled 且识别成功就会 cancel 触摸，
        // 仅在 handler 里 early-return 挡不住"App 底部长按被摸死"的问题。
        UILongPressGestureRecognizer *cornerGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleCornerLongPress:)];
        cornerGesture.numberOfTouchesRequired = 1;
        cornerGesture.minimumPressDuration = kMenuCornerHold;
        cornerGesture.enabled = ![[NSUserDefaults standardUserDefaults] boolForKey:cornerDisabledKey()];
        [self addGestureRecognizer:cornerGesture];
        objc_setAssociatedObject(self, kCornerGestureKey, cornerGesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kMenuAddedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)handleMenuLongPress:(UILongPressGestureRecognizer *)gesture {
        // 长按手势在 Began/Changed/Ended 每个状态变化都会回调一次。
        // 不判断状态的话，点菜单按钮让 alert 消失的瞬间会被再次触发 -> 菜单反复弹出并卡住。
        if (gesture.state != UIGestureRecognizerStateBegan) return;
        openSimpleMenu();
    }

    %new
    - (void)handleCornerLongPress:(UILongPressGestureRecognizer *)gesture {
        if (gesture.state != UIGestureRecognizerStateBegan) return;
        // per-app 禁用：部分 App 底部角落有自己的长按功能（拖拽排序/清除角标等），
        // 在菜单里关掉角落手势即可 —— 触发频率低，每次读一次 NSUserDefaults 开销可忽略。
        if ([[NSUserDefaults standardUserDefaults] boolForKey:cornerDisabledKey()]) return;
        // 1) 落点必须在角落扇形内（圆心 = 屏幕下角点，半径 kMenuCornerRadius；左右可切）
        CGPoint p = [gesture locationInView:self];
        CGFloat dx = (cornerGestureSide == 1) ? (CGRectGetWidth(self.bounds) - p.x) : p.x;
        CGFloat dy = p.y - CGRectGetHeight(self.bounds);
        if (sqrt(dx * dx + dy * dy) > (CGFloat)kMenuCornerRadius) return;
        // 2) 震动反馈（长按没反馈容易不知道有没有用上劲）+ 弹菜单（内部有 menuBusy 防重入）
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [haptic impactOccurred];
        openSimpleMenu();
    }

%end

%hook UIScrollView

    - (void)didMoveToWindow {
        %orig;

        // 离开窗口（复用/移除）时停掉滚动，避免 timer 持有已离屏 scroll view 造成泄漏
        if (self.window == nil) {
            [self stopAutoNative];
            [self stopUIScroller];
            [self stopAutoDisableTimer];
            return;
        }

        // 按 App 禁用：连手势也不挂、并清掉残留。
        // 之前 isDisabled 只在 _scrollViewWillBeginDragging 里拦"是否启动滚动"，
        // 手势照挂不误 —— 这就是"设置里禁用了，输入框依然点不动"的原因。
        if ([[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()]) {
            [self detachStopTouchGesture];
            return;
        }
    }

    // 用户真正开始拖拽时：立刻结束我们的接管（含刹车中的）。
    // 否则我们每帧的绝对定位写入会把内容"锁死"，手指拖不动，就没法手动连续快速滑动。
    - (void)_scrollViewWillBeginDragging {
        %orig;
        [self stopAutoNative];   // 手指接管：停掉原生续滚
        [self stopUIScroller];
    }

    // 原版这里把 %orig 调了两次（第一次 if 里、第二次 return 里），原实现副作用会执行两次。改为只调一次。
    - (BOOL)_scrollViewWillEndDraggingWithDeceleration:(BOOL)arg1 {
        BOOL r = %orig;

        // ── 自动档：松手即自动滚，速度完全跟随力道（甩得快滚得快、甩得慢滚得慢）──
        // 接管后速度按 v0·e^(-t/tau) 纯衰减滑到停，没有稳态巡航段。
        if (scrollSpeedType == 4) {
            // 按 App 禁用：禁用状态下的自动档不接管
            if ([[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()]) {
                [self stopUIScroller];
                return r;
            }
            CGPoint velocity = [self.panGestureRecognizer velocityInView:self];
            // 自动档触发阈值单独放低（300）：轻甩也延续；固定挡仍用 700
            BOOL strongEnough = fabs(velocity.y) >= kAutoTriggerAuto && fabs(velocity.y) > fabs(velocity.x);
            if (!strongEnough) {
                // 甩动力度不够：留给系统自然减速
                [self stopUIScroller];
                return r;
            }
            CGFloat vSrc = velocity.y;
            // 安全检查（与固定挡共用同一套）：
            //  - 滚轮（UIDatePicker/UIPickerView）不接
            //  - 内容不够滚的一屏视图（微信下拉小程序面板）不接
            //  - 回弹/越界区（下拉刷新等）不接
            if (scrollViewInsidePicker(self)) { [self stopUIScroller]; return r; }
            // 分页滚动视图（banner / 图片浏览器）不接管：我们连续写 offset 会和它的分页吸附打架，
            // 下一帧被吸附回第 0 页 —— 就是"滚着滚着瞬间到顶部"
            if (self.isPagingEnabled) { [self stopUIScroller]; return r; }
            BOOL scrollable = (self.contentSize.height - CGRectGetHeight(self.bounds)) >= kMinScrollableTravel;
            if (!scrollable) { [self stopUIScroller]; return r; }
            UIEdgeInsets insets = self.adjustedContentInset;
            CGFloat minOffsetNow = -insets.top;
            CGFloat maxOffsetNow = MAX(minOffsetNow, self.contentSize.height + insets.bottom - CGRectGetHeight(self.bounds));
            CGPoint cur = self.contentOffset;
            if (cur.y < minOffsetNow || cur.y > maxOffsetNow) { [self stopUIScroller]; return r; }

            // velocity.y > 0 表示向下 -> 继续向下滚 -> verticalDown = NO（保持原语义）
            objc_setAssociatedObject(self, kVerticalDownKey, @(vSrc <= 0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kDragVelocityKey, @(fabs(vSrc)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kAutoV0Key, @(fabs(vSrc)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // 自动档：优先让系统自己的滚动动画续滚；私有方法不可用时退回我们的驱动
            if (nativeSustainBroken) [self startUIScroller];
            else [self startAutoNative];
            return r;
        }

        // ── 固定挡（慢速/标准/较快/快速）：沿用"松手速度采样 + 惯性收敛到稳态" ──
        if (!r && !arg1) {
            // 松手后不会有惯性减速（慢慢拖停）-> 不接管
            [self stopUIScroller];
            return r;
        }

        BOOL isDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
        CGPoint velocity = [self.panGestureRecognizer velocityInView:self];
        BOOL vertical = fabs(velocity.y) > fabs(velocity.x);
        // 只有"用力甩"才接管；轻中力度留给用户自然手动滑，否则没法连续快速滑动
        BOOL strongEnough = fabs(velocity.y) >= kAutoTriggerVelocity;
        // 不要接管 UIDatePicker / UIPickerView 的滚轮：它们内部 scroll view 松手会减速到停，
        // 我们按惯性接管后滚轮会一直转，没法精确选时间
        BOOL pickerLike = scrollViewInsidePicker(self);
        // 内容实际够不够滚：一屏就放得下的视图（微信下拉小程序面板等）不接管，
        // 否则会打断它自己的回弹/动画
        BOOL scrollable = (self.contentSize.height - CGRectGetHeight(self.bounds)) >= kMinScrollableTravel;
        // 回弹/越界区（顶部下拉、底部上拉）不接管：下拉刷新、微信聊天列表下拉呼出小程序面板
        // 这类手势都发生在这里（列表被拉到 minOffset 以上），接管会让面板"缓慢爬"而不是正常弹出
        UIEdgeInsets insets = self.adjustedContentInset;
        CGFloat minOffsetNow = -insets.top;
        CGFloat maxOffsetNow = MAX(minOffsetNow, self.contentSize.height + insets.bottom - CGRectGetHeight(self.bounds));
        CGPoint cur = self.contentOffset;
        BOOL inBounceZone = (cur.y < minOffsetNow) || (cur.y > maxOffsetNow);
        // 分页视图不接管（连续写 offset 与分页吸附冲突，会被弹回第一页）
        BOOL shouldTakeOver = !isDisabled && vertical && strongEnough && scrollable && !inBounceZone && !pickerLike && !self.isPagingEnabled;

        if (shouldTakeOver) {
            // velocity.y > 0 表示手指向下滑 -> 继续向下滚 -> verticalDown = NO（保持原语义）
            BOOL vDown = (velocity.y <= 0);
            objc_setAssociatedObject(self, kVerticalDownKey, @(vDown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // 松手瞬间的速度才是"甩动力度"，用它决定自动滚动的恒定速度
            objc_setAssociatedObject(self, kDragVelocityKey, @(fabs(velocity.y)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self startUIScroller];
        } else {
            // 不接管：清掉可能残留的会话，让 iOS 自然减速
            [self stopUIScroller];
        }
        return r;
    }

    // 只在"自动滚动进行中"挂停止手势（碰到就停）。平时不挂，
    // 避免在绝大多数非滚动场景下干扰 App 自身的点击（尤其是输入框）。
    %new
    - (void)attachStopTouchGesture {
        if (objc_getAssociatedObject(self, kStopGestureKey)) return;
        if ([[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()]) return;
        // UITextView 本身就是 UIScrollView 子类，额外手势会和它内部文本交互手势冲突 -> 点了没反应
        if ([self isKindOfClass:[UITextView class]]) return;
        // WKWebView 内部的 WKScrollView 挂手势会让网页输入框点不动
        if (scrollViewInsideWebView(self)) return;
        // UIDatePicker / UIPickerView 滚轮也不挂
        if (scrollViewInsidePicker(self)) return;

        // 用长按手势做"按住即停"：按时长 kStopTouchDuration 秒。
        // 之前设 0（一碰就停），结果连续快速甩动时每次触屏都触发刹车，起手就打架；
        // 延长后，甩动（触屏到抬手 <0.15s）根本到不了 Began，完全不干扰手动滑。
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleStopTouch:)];
        press.minimumPressDuration = kStopTouchDuration;
        press.numberOfTouchesRequired = 1;
        press.cancelsTouchesInView = NO;
        press.delaysTouchesBegan = NO;
        press.delaysTouchesEnded = NO;
        [self addGestureRecognizer:press];
        objc_setAssociatedObject(self, kStopGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)detachStopTouchGesture {
        UILongPressGestureRecognizer *press = objc_getAssociatedObject(self, kStopGestureKey);
        if (press) {
            [self removeGestureRecognizer:press];
            objc_setAssociatedObject(self, kStopGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    %new
    - (void)handleStopTouch:(UILongPressGestureRecognizer *)gesture {
        if (gesture.state == UIGestureRecognizerStateBegan) {
            // 记下落下位置，用于判断"是想停，还是想接着拖"（CGPoint 是结构体，要用 NSValue 装箱）
            objc_setAssociatedObject(self, kTouchStartKey, [NSValue valueWithCGPoint:[gesture locationInView:self]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // 原生续滚模式：先取消系统动画（写一次当前 offset 即可打断平滑滚动）
            if ([objc_getAssociatedObject(self, kAutoActiveKey) boolValue]) {
                [self setContentOffset:self.contentOffset animated:NO];
                [self stopAutoNative];
                return;
            }
            [self brakeUIScroller];
            return;
        }
        if (gesture.state == UIGestureRecognizerStateChanged) {
            // 手指一动（>5pt）= 用户想手动拖 -> 立即交还控制权，不等拖拽判定
            if (!objc_getAssociatedObject(self, kBrakingKey)) return;
            NSValue *startValue = objc_getAssociatedObject(self, kTouchStartKey);
            CGPoint start = startValue ? [startValue CGPointValue] : CGPointZero;
            CGPoint loc = [gesture locationInView:self];
            if (fabs(loc.x - start.x) > 5.0 || fabs(loc.y - start.y) > 5.0) {
                [self stopUIScroller];
            }
        }
    }

    // ── 自动档：原生续滚 ──
    // 思路（对齐 pxcex AutoScroll）：不自己每帧写 contentOffset，而是让 UIScrollView 自己的
    // 滚动动画继续跑 —— 我们在它的每帧回调里把速度续住。这样 cell 加载、懒加载、吸顶、
    // Telegram 的位置补偿等全部照常工作（对 App 来说就是"一次很长的减速"），兼容性最好。
    %new
    - (void)startAutoNative {
        // 屏幕常亮必须两条驱动路径都生效：原生续滚不走 startUIScroller，
        // 之前只在那里设置，微信里"力道滑动开了常亮照样锁屏"就是漏了这里
        [self applyKeepAwakeIfEnabled];
        // 记录续滚起点：贴边检测基准（offset + 时刻）配合 kAutoV0Key（松手实测速度）恒速续滚
        objc_setAssociatedObject(self, kAutoStartTimeKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kAutoLastYKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kAutoLastTKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kAutoActiveKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self attachStopTouchGesture];
        [self setupAutoDisableTimer];
    }

    %new
    - (void)stopAutoNative {
        objc_setAssociatedObject(self, kAutoActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 恢复被钉住的衰减系数，否则下一次手指拖拽几乎不减速（手感被破坏）。
        // 恢复也走直接内存（与写入路径一致），并兜底恢复原厂值。
        NSNumber *origFactor = objc_getAssociatedObject(self, kOrigFactorKey);
        if (origFactor) {
            objc_setAssociatedObject(self, kOrigFactorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            double *facPtr = usc_facPtr(self);
            if (facPtr) *facPtr = [origFactor doubleValue];
        }
        [self detachStopTouchGesture];
        [self stopAutoDisableTimer];
        [self restoreKeepAwake];
    }

    %new
    - (void)applyKeepAwakeIfEnabled {
        if (!keepScreenAwake) return;
        UIApplication *app = [UIApplication sharedApplication];
        // 先记下 App 原本的息屏策略，停止滚动时还原 —— 不能无脑设 NO，
        // 否则会把视频/导航类 App 本来就该常亮的状态给关掉。
        objc_setAssociatedObject(self, kIdleTimerPrevKey, @(app.idleTimerDisabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kIdleTimerSetKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        app.idleTimerDisabled = YES;
    }

    %new
    - (void)restoreKeepAwake {
        // 还原 App 原本的息屏策略（仅当我们改过时才还原）
        if ([objc_getAssociatedObject(self, kIdleTimerSetKey) boolValue]) {
            BOOL prev = [objc_getAssociatedObject(self, kIdleTimerPrevKey) boolValue];
            [UIApplication sharedApplication].idleTimerDisabled = prev;
            objc_setAssociatedObject(self, kIdleTimerSetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kIdleTimerPrevKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    %new
    - (void)setupAutoDisableTimer {
        if (autoDisableMinutes <= 0) return;
        [self stopAutoDisableTimer];
        __weak typeof(self) weakSelf = self;
        __block int remain = autoDisableMinutes * 60;
        NSTimer *ad = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer){
            __strong typeof(weakSelf) strongSelf = weakSelf;
            remain--;
            if (remain > 0) updateCountdownHUD(remain); // 胶囊全程可见，≤10s 变琥珀、≤5s 变红
            if (remain <= 0) {
                hideCountdownHUD();
                [timer invalidate];
                if (strongSelf) [strongSelf autoDisableScrolling];
            }
        }];
        objc_setAssociatedObject(self, kAutoDisableTimerKey, ad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 接管：开自己的 CADisplayLink 驱动（固定挡用；自动档优先走 startAutoNative）
    %new
    - (void)startUIScroller {
        [self stopUIScroller];
        // 接管瞬间的基准位置 / 时刻 / 累计位移：之后按我们自己的曲线绝对定位，
        // 不再基于 self.contentOffset 做累加，避免和 iOS 自带减速互相打断造成顿挫。
        objc_setAssociatedObject(self, kScrollStartKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kLastTickKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 首帧用默认 1/60s
        // 交接观察期：先让系统自带减速跑 1~2 帧，实测它真实的滚动速度再接手。
        // 手指速度（panGestureRecognizer）和系统内部投影速度并不相等，直接拿手指速度起步
        // 会在第一帧产生速度跳变 —— 就是"起步那一下衔接不自然"的根因。
        objc_setAssociatedObject(self, kHandoffKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kHandoffOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kHandoffTimeKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kContentSizeKey, @(self.contentSize.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kExpectedSetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 新会话：还没写过值，不做比对
        objc_setAssociatedObject(self, kEdgeWaitKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);    // 新会话：清空贴边等待状态

        __weak typeof(self) weakSelf = self;
        // 用 CADisplayLink 代替 0.01s NSTimer：跟随屏幕刷新率（60/120Hz），滚动更顺滑、更省电。
        // link 强引用 proxy，proxy 只弱引用 self -> 无 retain cycle。
        UIScrollerTickProxy *proxy = [[UIScrollerTickProxy alloc] init];
        proxy.scrollView = self;
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
        link.preferredFramesPerSecond = 0; // 0 = 跟随屏幕原生刷新率
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, kScrollTimerKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 挂上"点一下停止"的手势（只在滚动期间存在）
        [self attachStopTouchGesture];

        // 屏幕常亮（菜单开关，默认关）：程序化滚动不算用户操作，系统照常息屏锁屏，
        // 开着它才能在长时间自动滚动时保持亮屏。
        [self applyKeepAwakeIfEnabled];

        if (autoDisableMinutes > 0) {
            [self stopAutoDisableTimer];
            __block int remain = autoDisableMinutes * 60;
            // 1 秒一次（不是逐帧）刷新顶部倒计时胶囊
            NSTimer *ad = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer){
                __strong typeof(weakSelf) strongSelf = weakSelf;
                remain--;
                if (remain > 0) updateCountdownHUD(remain); // 胶囊全程可见，≤10s 变琥珀、≤5s 变红
                if (remain <= 0) {
                    hideCountdownHUD();
                    [timer invalidate];
                    if (strongSelf) [strongSelf autoDisableScrolling];
                }
            }];
            objc_setAssociatedObject(self, kAutoDisableTimerKey, ad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    %new
    - (void)stopUIScroller {
        id t = objc_getAssociatedObject(self, kScrollTimerKey);
        if (t) {
            [t invalidate];
            objc_setAssociatedObject(self, kScrollTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(self, kBrakingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 手动停了滚动就把"自动停止"计时器一并清掉，否则到点还会莫名弹提示
        [self stopAutoDisableTimer];
        // 还原 App 原本的息屏策略（仅当我们改过时才还原）
        [self restoreKeepAwake];
        [self detachStopTouchGesture];
    }

    // 用户主动停止时走这里：进入刹车态，速度匀减速滑到 0 再真正停。
    // 生命周期类停止（离屏 / 重新接管）仍用 stopUIScroller 立即停。
    %new
    - (void)brakeUIScroller {
        // 已经在刹车中再触发一次 -> 直接定住，保证"想停就一定能马上停"
        if (objc_getAssociatedObject(self, kBrakingKey)) { [self stopUIScroller]; return; }
        if (!objc_getAssociatedObject(self, kScrollTimerKey)) { [self stopUIScroller]; return; }
        objc_setAssociatedObject(self, kBrakingKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kBrakeStartKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)stopAutoDisableTimer {
        NSTimer *ad = objc_getAssociatedObject(self, kAutoDisableTimerKey);
        if (ad) {
            [ad invalidate];
            objc_setAssociatedObject(self, kAutoDisableTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            hideCountdownHUD(); // 计时器没了，倒计时提示也收掉
        }
    }

    %new
    - (void)forceLayoutVisibleCells {
        // 直接写 contentOffset 后，UITableView / UICollectionView 的可见单元格下一次布局会被
        // runloop 合并/推迟，要等手指碰一下触发 layoutSubviews 才补齐 —— 表现就是"界面空白、
        // 碰一下才出内容"。这里同步强制一次布局，让新位置上的单元格立刻被创建/定位。
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }

    %new
    - (void)autoScroll {
        // ── 交接观察期（仅自动档）──
        // 让系统自带减速先跑 1~2 帧，用"实测位移 / 实测时间"算出它真实的滚动速度再接手，
        // 起点和系统当时在跑的速度完全一致 -> 起步零跳变；该速度本身就是甩动力道算出来的。
        if ([objc_getAssociatedObject(self, kHandoffKey) intValue]) {
            CFTimeInterval nowT = CACurrentMediaTime();
            double lastOff = [objc_getAssociatedObject(self, kHandoffOffsetKey) doubleValue];
            double lastT = [objc_getAssociatedObject(self, kHandoffTimeKey) doubleValue];
            double curOff = self.contentOffset.y;
            double dtObs = nowT - lastT;
            if (dtObs < 0.008) return;                 // 采样间隔太短，等下一帧
            double vObs = fabs(curOff - lastOff) / dtObs;
            double vRelease = [objc_getAssociatedObject(self, kDragVelocityKey) doubleValue]; // 松手速度（备用）
            BOOL vDownRelease = [objc_getAssociatedObject(self, kVerticalDownKey) boolValue];  // 松手方向（备用）
            BOOL dirDown = (curOff - lastOff) > 0;
            // 观察窗口内 App 可能自己动过 offset（折叠/刷新/分页回弹），测出的速度会离谱甚至方向翻转。
            // 这三条件任一不满足就回退用松手速度 + 松手方向，避免"一脚油门冲到顶"。
            BOOL sane = (vObs >= kAutoTriggerAuto) && (vObs <= kAutoVelocitySanity) && (dirDown == vDownRelease);
            double vStart = sane ? vObs : vRelease;
            if (vStart < kAutoTriggerAuto) { [self stopUIScroller]; return; } // 系统没在减速 -> 放弃接管
            objc_setAssociatedObject(self, kDragVelocityKey, @(vStart), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(curOff), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kScrollStartKey, @(nowT), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kLastTickKey, @(nowT), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kVerticalDownKey, @(sane ? dirDown : vDownRelease), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kHandoffKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kContentSizeKey, @(self.contentSize.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return; // 本帧不动，从下一帧开始按我们的曲线推进
        }

        CGFloat v0 = [objc_getAssociatedObject(self, kDragVelocityKey) doubleValue]; // 接管初速度 pt/s
        CFTimeInterval started = [objc_getAssociatedObject(self, kScrollStartKey) doubleValue];
        CFTimeInterval t = CACurrentMediaTime() - started;

        float speed;
        if (scrollSpeedType == 4) {
            // 自动档：起步速度 = 交接瞬间实测速度（= 你的力道），之后极缓慢收速滚下去，
            // 一直滚到用户手动停（按住 0.25s）/ 轻触交还控制权 / 滚到内容尽头。
            speed = (float)(v0 * exp(-t / kAutoDecayTau));
            if (speed > kAutoCruiseMax) speed = kAutoCruiseMax;
            if (speed < kAutoStopSpeed) { [self stopUIScroller]; return; }
        } else {
            // 固定挡：稳态速度（pt/s）
            float steady = (scrollSpeedType >= 0 && scrollSpeedType <= 3) ? kGearSpeed[scrollSpeedType] : 160.0f;
            // 固定挡速度微调（菜单 ±100pt/s）：在基准档位上细调
            if (gearSpeedAdjust != 0) {
                steady += gearSpeedAdjust;
                if (steady < 10.0f) steady = 10.0f;
            }
            // 自定义惯性：起步速度 = 交接实测速度 v0（= 手上力道），之后按 e^(-t/1.2s)
            // 平滑收到档位速度。不夹到 steady：轻扫时（v0 < steady）需要让它平滑"升"上去，
            // 强行取 steady 反而会突跳。
            speed = steady + (float)((v0 - steady) * exp(-t / kGearEaseTau));
            if (speed < 0.0f) speed = 0.0f;
        }

        // 刹车：匀减速（线性降到 0），像摩擦制动一样滑停，而不是瞬间定住
        if ([objc_getAssociatedObject(self, kBrakingKey) boolValue]) {
            CFTimeInterval bt = CACurrentMediaTime() - [objc_getAssociatedObject(self, kBrakeStartKey) doubleValue];
            float k = 1.0f - (float)(bt / kBrakeDuration);
            if (k <= 0.0f) { [self stopUIScroller]; return; }
            speed *= k;
        }

        // 位移由我们自己累计并绝对定位，不基于 self.contentOffset 累加，
        // 避免与 iOS 减速相互打断而产生抖动。
        CADisplayLink *link = objc_getAssociatedObject(self, kScrollTimerKey);
        // 用"真实帧间隔"（相邻两次回调 timestamp 之差），而不是 link.duration 那个标称值：
        // 掉帧或负载波动时，位移量依然与真实流逝时间成正比，速度观感才稳定，不会一顿一顿。
        double prev = [objc_getAssociatedObject(self, kLastTickKey) doubleValue];
        double now = link ? link.timestamp : CACurrentMediaTime();
        double dt = (prev > 0.0) ? (now - prev) : (1.0 / 60.0);
        if (dt < 0.0) dt = 0.0;
        if (dt > 0.05) dt = 0.05; // 卡顿保护：长时间挂起后回到前台，避免一帧跳太远
        objc_setAssociatedObject(self, kLastTickKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 内容高度一变（增量加载/刷新/折叠）就以当前实际偏移重新起算：
        // 否则基准位置失效会让目标值越界，表现为"滚着滚着瞬间跳到顶/底"。
        CGFloat csNow = self.contentSize.height;
        CGFloat csPrev = [objc_getAssociatedObject(self, kContentSizeKey) doubleValue];
        if (csPrev > 0.0) {
            // 内容高度怎么变都只做"重新起算"：变高是懒加载，缩水是预估行高校准/折叠，
            // 都不该直接停（位置是否还有效交给后面的边界判断处理）
            if (fabs(csNow - csPrev) > 1.0) {
                objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kContentSizeKey, @(csNow), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        // App 自己也在改 offset（聊天记录加载历史后的位置补偿、列表刷新）-> 说明它在抢方向盘，
        // 我们继续写绝对位置只会互相打断（表现为跳一段再停住）-> 立刻退出接管
        if ([objc_getAssociatedObject(self, kExpectedSetKey) boolValue]) {
            double expected = [objc_getAssociatedObject(self, kExpectedOffsetKey) doubleValue];
            double dev = self.contentOffset.y - expected;
            // 大幅偏离 = App 真的抢方向盘（加载历史后的位置补偿等）-> 退出
            if (fabs(dev) > 25.0) { [self stopUIScroller]; return; }
            // 小幅偏离（吸顶/安全区变化/导航栏隐藏/像素对齐）：吸收掉重新起算，继续滚，不要停
            if (fabs(dev) > 1.5) {
                objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        double travel = [objc_getAssociatedObject(self, kScrollTravelKey) doubleValue] + (double)speed * dt;
        objc_setAssociatedObject(self, kScrollTravelKey, @(travel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        double base = [objc_getAssociatedObject(self, kScrollBaseOffsetKey) doubleValue];
        BOOL vDown = [objc_getAssociatedObject(self, kVerticalDownKey) boolValue];
        CGFloat targetY = (CGFloat)(vDown ? (base + travel) : (base - travel));

        // 越界判断：考虑 adjustedContentInset（iOS 11+ 安全区/导航栏/底部 home 指示条）
        UIEdgeInsets insets = self.adjustedContentInset;
        CGFloat minOffset = -insets.top;
        CGFloat maxOffset = MAX(minOffset, self.contentSize.height + insets.bottom - CGRectGetHeight(self.bounds));
        if (targetY >= maxOffset || targetY <= minOffset) {
            // 滚到当前内容尽头：不立刻停，先"贴边等待"，给 App 触发加载更多的时间。
            // 我们每帧写 offset 会触发 scrollViewDidScroll / willDisplay，App 的加载逻辑会被唤起。
            CFTimeInterval nowE = CACurrentMediaTime();
            id waitStart = objc_getAssociatedObject(self, kEdgeWaitKey);
            if (!waitStart) {
                objc_setAssociatedObject(self, kEdgeWaitKey, @(nowE), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kEdgeWaitSizeKey, @(self.contentSize.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                waitStart = @(nowE);
            }
            // 等到了新内容（内容变高）-> 重新起算继续滚
            if (self.contentSize.height - [objc_getAssociatedObject(self, kEdgeWaitSizeKey) doubleValue] > 1.0) {
                objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kContentSizeKey, @(self.contentSize.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kEdgeWaitKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kExpectedSetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return;
            }
            // 等太久还是没新内容 -> 认为真的到底/到顶了（轻震提示）
            if (nowE - [waitStart doubleValue] > kEdgeWaitTimeout) {
                [self stopUIScroller];
                UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [h impactOccurred];
                return;
            }
            // 保持贴在边界上（持续触发 App 的加载更多），本帧不再推进
            CGPoint edge = self.contentOffset;
            edge.y = (targetY >= maxOffset) ? maxOffset : minOffset;
            [self setContentOffset:edge animated:NO];
            [self forceLayoutVisibleCells];
            objc_setAssociatedObject(self, kExpectedOffsetKey, @(edge.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kExpectedSetKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        CGPoint offset = self.contentOffset;
        offset.y = targetY;
        [self setContentOffset:offset animated:NO];
        [self forceLayoutVisibleCells];
        // 记下"我们写进去的值"，下一帧用来判断 App 有没有偷偷改过 offset
        objc_setAssociatedObject(self, kExpectedOffsetKey, @(targetY), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kExpectedSetKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)autoDisableScrolling {
        [self stopAutoNative];      // 原生续滚也要停
        [self brakeUIScroller];
        [self stopAutoDisableTimer];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"UIScroller"
                                                                     message:@"自动滚动已自动停止"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *ok = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:ok];
        [topViewController() presentViewController:alert animated:YES completion:nil];
    }

%end

// 系统平滑滚动的每帧回调（UIScrollView 私有方法）。减速/平滑滚动期间每帧都会走到这里。
// 单独成组：只有在运行时确认这个方法存在时才 %init，否则 %orig 会指向空实现导致崩溃。
%group NativeSmoothScroll

%hook UIScrollView

    - (void)_smoothScrollWithUpdateTime:(double)time {
        %orig(time);
        if (![objc_getAssociatedObject(self, kAutoActiveKey) boolValue]) return;

        // ── 力道跟随恒速续滚：velocity 是驱动本体，必须写；factor 只是辅助 ──
        // 真机实测矩阵：只钉 factor（a4d7758）= velocity 照常自然衰减 = 完全没效果；
        // factor+velocity 每帧写死 ≈1.0pt/ms（40d3e05）= 能续住但速度钳死 ~1000pt/s，不跟力道；
        // velocity 续 e^(-t/8) 收尾曲线（8a8630c）= 跟力道但 5~18s 就收完，"滚一会自己慢慢停"。
        // 结论：_verticalVelocity 才是滚动驱动变量（写多大滚多快），factor≈1 只防动画提前结束。
        // 终版：恒速 = 松手实测力道（封顶 1.0pt/ms），一直滚到用户手动停 / 贴边超时 / 定时关。
        // 写入量级 ≤ 甩动本身的速度，App 本来就在消化这个量级，不空白。
        // 读写全部走直接内存（usc_velPtr / usc_facPtr），不走 KVC —— KVC 会被私有 setter 拦截。
        double *velPtr = usc_velPtr(self);
        double *facPtr = usc_facPtr(self);
        if (!velPtr || !facPtr) {
            // 私有 ivar 不存在（iOS 版本变了）-> 退回自有驱动
            nativeSustainBroken = YES;
            [self stopAutoNative];
            [self startUIScroller];
            return;
        }
        // 常亮兜底重断言：微信等 App 会自己把 idleTimerDisabled 改回 NO（iOS 16 上必现），
        // 所以每约 60 帧（≈1 秒）再写一次，比只在启动时设一次可靠得多，开销可忽略。
        if (keepScreenAwake) {
            if (++uscAwakeTick >= 60) {
                uscAwakeTick = 0;
                [UIApplication sharedApplication].idleTimerDisabled = YES;
            }
        }
        double raw = *velPtr;
        double v = fabs(raw);
        // 贴边即停：offset 连续 kEdgeStallTime 没动 = 滚不动了，速度归零交还系统自然滑停。
        // （用户确认不要"顶着等"：贴边等待已验证对 QQ/微信的懒加载无效。）
        CGFloat y = self.contentOffset.y;
        CGFloat lastY = [objc_getAssociatedObject(self, kAutoLastYKey) doubleValue];
        CFTimeInterval lastT = [objc_getAssociatedObject(self, kAutoLastTKey) doubleValue];
        CFTimeInterval now = CACurrentMediaTime();
        if (fabs(y - lastY) > 0.5) {
            objc_setAssociatedObject(self, kAutoLastYKey, @(y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kAutoLastTKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (lastT > 0.0 && now - lastT > kEdgeStallTime) {
            *velPtr = 0.0;
            [self stopAutoNative];
            // 到头提示：轻震一下，不用盯着看才知道自动滚动停了
            UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [h impactOccurred];
            return;
        }
        // 恒速目标：松手瞬间 pan 手势的实测速度（pt/s，接管入口存好），换算 pt/ms 并封顶
        double v0ptps = [objc_getAssociatedObject(self, kAutoV0Key) doubleValue];
        double target = MIN((v0ptps / 1000.0) * (autoForceMultiplier / 100.0), kAutoNativeCruiseMaxV);
        if (target < kAutoNativeStopV) {
            // 力道异常地小（<100pt/s）：交还系统自然滑停（stopAutoNative 会恢复系数）
            [self stopAutoNative];
            return;
        }
        if (v >= target) return;   // 系统速度仍在目标之上（刚松手的快段）：不干预，任其自然衰减
        // 系统自然衰减把速度掉到目标之下：续回目标速度，同时钉 factor 防动画提前结束
        if (!objc_getAssociatedObject(self, kOrigFactorKey)) {
            objc_setAssociatedObject(self, kOrigFactorKey,
                                     [NSNumber numberWithDouble:*facPtr],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        *facPtr = (double)(float)(kAutoNativePinBase + target * kAutoNativePinEps);
        *velPtr = (raw < 0.0) ? -target : target;
    }

%end

%end

%ctor {
    // 用户 App（/var/containers/Bundle/Application）+ 系统 App（/Applications/，如照片、Safari、设置）。
    // 守护进程在 /usr/libexec、/System/Library 下，SpringBoard 在 /System/Library/CoreServices，
    // 都不匹配，所以不会被注入（系统 App 里出问题可在菜单里"禁用此应用"）。
    NSString *executablePath = NSProcessInfo.processInfo.arguments[0];
    if ([executablePath containsString:@"/var/containers/Bundle/Application"] ||
        [executablePath containsString:@"/Applications/"]) {
        %init;
        // 只有确认 UIScrollView 真的实现了这个私有方法，才挂载"续住系统动画"的钩子
        if (class_getInstanceMethod([UIScrollView class], @selector(_smoothScrollWithUpdateTime:))) {
            %init(NativeSmoothScroll);
        } else {
            nativeSustainBroken = YES; // 没有该方法 -> 自动档直接走我们自己的驱动
        }
    }
}
