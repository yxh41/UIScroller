#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

@interface UIScrollView (UIScroller)
@property (nonatomic,readonly) UIPanGestureRecognizer *panGestureRecognizer;
- (void)startUIScroller;
- (void)stopUIScroller;
- (void)autoScroll;
- (void)handleTaps:(UITapGestureRecognizer *)gesture;
- (void)stopAutoDisableTimer;
- (void)autoDisableScrolling;
- (void)attachStopTapGesture;
- (void)detachStopTapGesture;
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
static const void *kTapGestureKey       = &kTapGestureKey;
static const void *kMenuAddedKey        = &kMenuAddedKey;
static const void *kVerticalDownKey     = &kVerticalDownKey;
static const void *kDragVelocityKey     = &kDragVelocityKey;
static const void *kScrollStartKey      = &kScrollStartKey;
static const void *kScrollBaseOffsetKey = &kScrollBaseOffsetKey;
static const void *kScrollTravelKey     = &kScrollTravelKey;

int scrollSpeedType = 4;    // 0:慢速 1:标准 2:较快 3:快速 4:自动（跟随滑动力道，默认）
int autoDisableMinutes = 0; // 0: Disabled, >0: Minutes until auto-disable

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

// 自动档（跟随滑动力道）：稳态速度 = 松手甩动速度 × kAutoSpeedFactor，钳制 [min, max] pt/s。
// 这是一条纯连续曲线，与下面的固定挡位（50/100/150/200）完全无关，不做任何挡位量化。
static const float kAutoSpeedFactor     = 0.12f;
static const float kAutoSpeedMin        = 40.0f;
static const float kAutoSpeedMax        = 400.0f;
// 惯性收敛时间常数（秒）：接管瞬间速度 = 松手速度 V，随后按 e^(-t/tau) 平滑收敛到稳态速度。
// 取 ~0.45s 与 iOS 自带减速的衰减尺度接近，看上去就是"惯性自然延续"，不会顿一下。
static const CFTimeInterval kAutoEaseTau = 0.45;

// per-app 禁用 key（原版用全局 key，UI 写 "Disable for this app" 但实际禁用所有 app）
static NSString *disabledKey() {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [NSString stringWithFormat:@"uiscroller_disabled_%@", bid];
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

// 防重入：presentViewController 是异步的，展示动画完成前 topViewController() 还看不到这个 alert。
// 此时若再次触发就会重复 present —— QQ 等 App 上表现为"点任何按钮菜单都重新弹出并卡住"。
static BOOL menuBusy = NO;

void openSimpleMenu() {
    if (menuBusy) return;
    UIViewController *presenter = topViewController();
    if (!presenter) return;
    if ([presenter isKindOfClass:[UIAlertController class]]) return; // 菜单已在最上层
    if (presenter.presentedViewController) return;                   // 正在展示别的弹窗

    menuBusy = YES;
    BOOL isDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"UIScroller 快捷菜单"
                                    message:nil
                                    preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *speed = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"速度：%@", speedName(scrollSpeedType)] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    // 0 慢速 -> 1 标准 -> 2 较快 -> 3 快速 -> 4 自动 -> 回到 0
                                    scrollSpeedType = (scrollSpeedType >= 4) ? 0 : scrollSpeedType + 1;
                                }];
        UIAlertAction *autoDisable = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"自动停止：%@", autoDisableMinutes == 0 ? @"关闭" : [NSString stringWithFormat:@"%d 分钟", autoDisableMinutes]] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    UIAlertController *inputAlert = [UIAlertController alertControllerWithTitle:@"设置自动停止时间"
                                                                                                      message:@"输入分钟数（0 表示关闭）"
                                                                                               preferredStyle:UIAlertControllerStyleAlert];

                                    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                        textField.keyboardType = UIKeyboardTypeNumberPad;
                                        textField.placeholder = @"分钟";
                                        textField.text = [NSString stringWithFormat:@"%d", autoDisableMinutes];
                                    }];

                                    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *action) {
                                            NSString *input = inputAlert.textFields.firstObject.text;
                                            int minutes = [input intValue];
                                            if (minutes < 0) minutes = 0;
                                            if (minutes > 180) minutes = 180;
                                            autoDisableMinutes = minutes;
                                            NSString *message = autoDisableMinutes == 0 ?
                                                @"已关闭自动停止" :
                                                [NSString stringWithFormat:@"自动停止时间已设为 %d 分钟", autoDisableMinutes];
                                            UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:@"设置已更新"
                                                                                                                message:message
                                                                                                         preferredStyle:UIAlertControllerStyleAlert];
                                            [confirmation addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                                            [topViewController() presentViewController:confirmation animated:YES completion:nil];
                                        }];

                                    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
                                    [inputAlert addAction:confirmAction];
                                    [inputAlert addAction:cancelAction];
                                    [topViewController() presentViewController:inputAlert animated:YES completion:nil];
                                }];
        UIAlertAction *toggle = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@此应用", isDisabled ? @"启用" : @"禁用"] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    if (isDisabled) [[NSUserDefaults standardUserDefaults] setBool:NO forKey:disabledKey()];
                                    else [[NSUserDefaults standardUserDefaults] setBool:YES forKey:disabledKey()];
                                }];
        UIAlertAction *dismiss = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:speed];
        [alert addAction:autoDisable];
        [alert addAction:toggle];
        [alert addAction:dismiss];
        [presenter presentViewController:alert animated:YES completion:^{
            menuBusy = NO; // 展示完成后，继续由上面的 presentedViewController 判断拦截
        }];
    // 兜底：present 失败时 completion 不会调用，避免 menuBusy 卡住导致菜单再也打不开
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        menuBusy = NO;
    });
}

%hook UIWindow

    - (void)becomeKeyWindow {
        %orig;
        if (objc_getAssociatedObject(self, kMenuAddedKey)) return; // 去重：每个 window 只加一次
        // 只给主窗口（normal level）加菜单手势，避开键盘/弹窗等高 level 窗口
        if (self.windowLevel != UIWindowLevelNormal) return;
        UILongPressGestureRecognizer *menuGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuLongPress:)];
        menuGestureRecognizer.numberOfTouchesRequired = 4;
        [self addGestureRecognizer:menuGestureRecognizer];
        objc_setAssociatedObject(self, kMenuAddedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)handleMenuLongPress:(UILongPressGestureRecognizer *)gesture {
        // 长按手势在 Began/Changed/Ended 每个状态变化都会回调一次。
        // 不判断状态的话，点菜单按钮让 alert 消失的瞬间会被再次触发 -> 菜单反复弹出并卡住。
        if (gesture.state != UIGestureRecognizerStateBegan) return;
        openSimpleMenu();
    }

%end

%hook UIScrollView

    - (void)didMoveToWindow {
        %orig;

        // 离开窗口（复用/移除）时停掉滚动，避免 timer 持有已离屏 scroll view 造成泄漏
        if (self.window == nil) {
            [self stopUIScroller];
            [self stopAutoDisableTimer];
            return;
        }

        // 按 App 禁用：连手势也不挂、并清掉残留。
        // 之前 isDisabled 只在 _scrollViewWillBeginDragging 里拦"是否启动滚动"，
        // 手势照挂不误 —— 这就是"设置里禁用了，输入框依然点不动"的原因。
        if ([[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()]) {
            [self detachStopTapGesture];
            return;
        }
    }

    // 这里不再启动自动滚动：拖拽刚开始时 pan 速度接近 0（拿不到真实力道），
    // 而且此时启动会和用户正在进行的拖拽叠加，导致跟手发飘。
    // 改为在 _scrollViewWillEndDraggingWithDeceleration: 松手时接管。
    - (void)_scrollViewWillBeginDragging {
        %orig;
    }

    // 原版这里把 %orig 调了两次（第一次 if 里、第二次 return 里），原实现副作用会执行两次。改为只调一次。
    - (BOOL)_scrollViewWillEndDraggingWithDeceleration:(BOOL)arg1 {
        BOOL r = %orig;
        if (!r && !arg1) {
            // 松手后不会有惯性减速（慢慢拖停）-> 不接管
            [self stopUIScroller];
            return r;
        }

        BOOL isDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
        CGPoint velocity = [self.panGestureRecognizer velocityInView:self];
        if (!isDisabled && fabs(velocity.y) > fabs(velocity.x)) {
            // velocity.y > 0 表示手指向下滑 -> 继续向下滚 -> verticalDown = NO（保持原语义）
            BOOL vDown = (velocity.y <= 0);
            objc_setAssociatedObject(self, kVerticalDownKey, @(vDown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // 松手瞬间的速度才是"甩动力度"，用它决定自动滚动的恒定速度
            objc_setAssociatedObject(self, kDragVelocityKey, @(fabs(velocity.y)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self startUIScroller];
        }
        return r;
    }

    // 只在"自动滚动进行中"挂 tap 手势（用于点一下停）。平时不挂，
    // 避免在绝大多数非滚动场景下干扰 App 自身的点击（尤其是输入框）。
    %new
    - (void)attachStopTapGesture {
        if (objc_getAssociatedObject(self, kTapGestureKey)) return;
        if ([[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()]) return;
        // UITextView 本身就是 UIScrollView 子类，额外 tap 会和它内部文本交互手势冲突 -> 点了没反应
        if ([self isKindOfClass:[UITextView class]]) return;
        // WKWebView 内部的 WKScrollView 挂 tap 会让网页输入框点不动
        if (scrollViewInsideWebView(self)) return;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTaps:)];
        tap.numberOfTapsRequired = 1;
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesBegan = NO;
        tap.delaysTouchesEnded = NO; // 关键：不延迟 touchesEnded，否则点击输入框会卡住/没反应
        [self addGestureRecognizer:tap];
        objc_setAssociatedObject(self, kTapGestureKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)detachStopTapGesture {
        UITapGestureRecognizer *tap = objc_getAssociatedObject(self, kTapGestureKey);
        if (tap) {
            [self removeGestureRecognizer:tap];
            objc_setAssociatedObject(self, kTapGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    %new
    - (void)handleTaps:(UITapGestureRecognizer *)gesture {
        [self stopUIScroller];
    }

    %new
    - (void)startUIScroller {
        [self stopUIScroller];
        // 接管瞬间的基准位置 / 时刻 / 累计位移：之后按我们自己的曲线绝对定位，
        // 不再基于 self.contentOffset 做累加，避免和 iOS 自带减速互相打断造成顿挫。
        objc_setAssociatedObject(self, kScrollStartKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
        [self attachStopTapGesture];

        if (autoDisableMinutes > 0) {
            [self stopAutoDisableTimer];
            NSTimer *ad = [NSTimer scheduledTimerWithTimeInterval:autoDisableMinutes * 60 repeats:NO block:^(NSTimer * _Nonnull timer){
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) [strongSelf autoDisableScrolling];
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
        [self detachStopTapGesture];
    }

    %new
    - (void)stopAutoDisableTimer {
        NSTimer *ad = objc_getAssociatedObject(self, kAutoDisableTimerKey);
        if (ad) {
            [ad invalidate];
            objc_setAssociatedObject(self, kAutoDisableTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    %new
    - (void)autoScroll {
        CGFloat v0 = [objc_getAssociatedObject(self, kDragVelocityKey) doubleValue]; // 松手瞬时速度 pt/s

        // 稳态速度（pt/s）
        float steady = 100.0f;
        if (scrollSpeedType == 4) {
            // 自动档：纯连续函数，只看松手力度，不参考任何固定挡位
            steady = (float)(v0 * kAutoSpeedFactor);
            if (steady < kAutoSpeedMin) steady = kAutoSpeedMin;
            if (steady > kAutoSpeedMax) steady = kAutoSpeedMax;
        }
        else if (scrollSpeedType == 0) steady = 50.0f;
        else if (scrollSpeedType == 1) steady = 100.0f;
        else if (scrollSpeedType == 2) steady = 150.0f;
        else if (scrollSpeedType == 3) steady = 200.0f;

        // 自定义惯性：接管瞬间速度 = 松手速度 v0，之后按 e^(-t/tau) 平滑收敛到稳态速度。
        // 衰减尺度和 iOS 自带减速接近，所以是"惯性自然延续成定速"，不会先顿一下再起步。
        CFTimeInterval started = [objc_getAssociatedObject(self, kScrollStartKey) doubleValue];
        CFTimeInterval t = CACurrentMediaTime() - started;
        // 不要夹到 steady：轻扫时（v0 < steady）需要让它从 v0 平滑"升"到 steady，
        // 强行取 steady 反而会突跳一下。
        float speed = steady + (float)((v0 - steady) * exp(-t / kAutoEaseTau));
        if (speed < 0.0f) speed = 0.0f;

        // 位移由我们自己累计并绝对定位，不基于 self.contentOffset 累加，
        // 避免与 iOS 减速相互打断而产生抖动。
        CADisplayLink *link = objc_getAssociatedObject(self, kScrollTimerKey);
        NSTimeInterval frameDur = (link && link.duration > 0) ? link.duration : (1.0/60.0);
        double travel = [objc_getAssociatedObject(self, kScrollTravelKey) doubleValue] + (double)speed * frameDur;
        objc_setAssociatedObject(self, kScrollTravelKey, @(travel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        double base = [objc_getAssociatedObject(self, kScrollBaseOffsetKey) doubleValue];
        BOOL vDown = [objc_getAssociatedObject(self, kVerticalDownKey) boolValue];
        CGFloat targetY = (CGFloat)(vDown ? (base + travel) : (base - travel));

        // 越界判断：考虑 adjustedContentInset（iOS 11+ 安全区/导航栏/底部 home 指示条）
        UIEdgeInsets insets = self.adjustedContentInset;
        CGFloat minOffset = -insets.top;
        CGFloat maxOffset = MAX(minOffset, self.contentSize.height + insets.bottom - CGRectGetHeight(self.bounds));
        if (targetY >= maxOffset || targetY <= minOffset) {
            [self stopUIScroller];
            return;
        }

        CGPoint offset = self.contentOffset;
        offset.y = targetY;
        [self setContentOffset:offset animated:NO];
    }

    %new
    - (void)autoDisableScrolling {
        [self stopUIScroller];
        [self stopAutoDisableTimer];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"UIScroller"
                                                                     message:@"自动滚动已自动停止"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *ok = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:ok];
        [topViewController() presentViewController:alert animated:YES completion:nil];
    }

%end

%ctor {
    // Only run on user installed apps
    NSString *executablePath = NSProcessInfo.processInfo.arguments[0];
    if ([executablePath containsString:@"/var/containers/Bundle/Application"]) %init;
}
