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
- (void)attachStopTouchGesture;
- (void)detachStopTouchGesture;
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
// 刹车时长（秒）：停止时做匀减速（像摩擦制动）滑到 0，而不是瞬间定住。
// 0.35s 既刹得住又不会显得生硬；想要更干脆就调小。
static const CFTimeInterval kBrakeDuration = 0.35;
// 接管阈值：松手速度达到该值(pt/s)才进入自动滚动；低于它不接管，留给用户自然手动滑。
// 没有它的话每一次甩动都会被劫持，用户就没法连续快速地手动滑了。
static const float kAutoTriggerVelocity = 700.0f;
// 接管还要求内容真的够滚（可滚距离下限 pt）：像微信下拉小程序面板这种一屏放得下的视图，
// 没有可滚的距离，接管只会打断它自己的回弹/动画，看起来就是卡住
static const float kMinScrollableTravel = 120.0f;

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
        menuGestureRecognizer.numberOfTouchesRequired = 3;
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
            [self detachStopTouchGesture];
            return;
        }
    }

    // 用户真正开始拖拽时：立刻结束我们的接管（含刹车中的）。
    // 否则我们每帧的绝对定位写入会把内容"锁死"，手指拖不动，就没法手动连续快速滑动。
    - (void)_scrollViewWillBeginDragging {
        %orig;
        [self stopUIScroller];
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
        BOOL shouldTakeOver = !isDisabled && vertical && strongEnough && scrollable && !inBounceZone && !pickerLike;

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

        // 用 minimumPressDuration = 0 的长按手势：手指一落下就进入 Began，
        // 不需要等一次完整 tap（原来的 tap 手势要抬手才算，手指稍微一动就识别失败）。
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleStopTouch:)];
        press.minimumPressDuration = 0.0;
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

    %new
    - (void)startUIScroller {
        [self stopUIScroller];
        // 接管瞬间的基准位置 / 时刻 / 累计位移：之后按我们自己的曲线绝对定位，
        // 不再基于 self.contentOffset 做累加，避免和 iOS 自带减速互相打断造成顿挫。
        objc_setAssociatedObject(self, kScrollStartKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kLastTickKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 首帧用默认 1/60s

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
        objc_setAssociatedObject(self, kBrakingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            [self stopUIScroller];
            return;
        }

        CGPoint offset = self.contentOffset;
        offset.y = targetY;
        [self setContentOffset:offset animated:NO];
    }

    %new
    - (void)autoDisableScrolling {
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

%ctor {
    // 用户 App（/var/containers/Bundle/Application）+ 系统 App（/Applications/，如照片、Safari、设置）。
    // 守护进程在 /usr/libexec、/System/Library 下，SpringBoard 在 /System/Library/CoreServices，
    // 都不匹配，所以不会被注入（系统 App 里出问题可在菜单里"禁用此应用"）。
    NSString *executablePath = NSProcessInfo.processInfo.arguments[0];
    if ([executablePath containsString:@"/var/containers/Bundle/Application"] ||
        [executablePath containsString:@"/Applications/"]) {
        %init;
    }
}
