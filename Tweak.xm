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
static const void *kHandoffKey          = &kHandoffKey;
static const void *kHandoffOffsetKey    = &kHandoffOffsetKey;
static const void *kHandoffTimeKey      = &kHandoffTimeKey;
static const void *kIdleTimerSetKey     = &kIdleTimerSetKey;
static const void *kIdleTimerPrevKey    = &kIdleTimerPrevKey;

int scrollSpeedType = 4;    // 0:慢速 1:标准 2:较快 3:快速 4:自动（跟随滑动力道，默认）
int autoDisableMinutes = 0; // 0: Disabled, >0: Minutes until auto-disable
BOOL keepScreenAwake = NO;  // 自动滚动期间禁止息屏（默认关，菜单里可开）

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
// 停止阈值（pt/s）：衰减到该速度以下结束驱动（已慢到看不出在动）。
static const float kAutoStopSpeed = 20.0f;
// 自动档的甩动触发阈值（pt/s）：故意比固定挡的 700 低很多——
// 轻轻一甩也会自动延续，且滚动速度完全跟随力道（甩得快滚得快、甩得慢滚得慢，pxcex 行为）。
// 拉低后不必担心误触：微信下拉面板/滚轮/回弹区仍由各自的守卫拦住。
static const float kAutoTriggerAuto = 300.0f;
// 刹车时长（秒）：停止时做匀减速（像摩擦制动）滑到 0，而不是瞬间定住。
// 0.35s 既刹得住又不会显得生硬；想要更干脆就调小。
static const CFTimeInterval kBrakeDuration = 0.35;
// 接管阈值：松手速度达到该值(pt/s)才进入自动滚动；低于它不接管，留给用户自然手动滑。
// 没有它的话每一次甩动都会被劫持，用户就没法连续快速地手动滑了。
static const float kAutoTriggerVelocity = 700.0f;
// "按住即停"需要按住的时长（秒）：设成 0 会让连续快速甩动时每一次触屏都触发刹车，
// 干扰手动滑。0.25s 足以过滤掉甩动（甩动从触屏到抬手一般 <0.15s），又不会觉得迟钝。
static const NSTimeInterval kStopTouchDuration = 0.25;
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

// ── 自动停止倒计时悬浮窗 ──
// 只在最后 10 秒出现，1 秒更新一次（不跟屏幕刷新率，功耗可忽略）；
// 关键：userInteractionEnabled = NO，绝不能挡住 App 自己的触摸。
static UILabel *hudLabel = nil;

static UILabel *hudEnsureLabel(void) {
    if (hudLabel && hudLabel.superview) return hudLabel;
    UIWindow *host = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowLevel == UIWindowLevelNormal && !w.hidden) { host = w; break; }
    }
    if (!host) return nil;
    if (!hudLabel) {
        hudLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        hudLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
        hudLabel.textColor = [UIColor whiteColor];
        hudLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        hudLabel.textAlignment = NSTextAlignmentCenter;
        hudLabel.layer.cornerRadius = 6.0;
        hudLabel.layer.masksToBounds = YES;
        hudLabel.userInteractionEnabled = NO; // 不挡触摸
    }
    [host addSubview:hudLabel];
    return hudLabel;
}

static void updateCountdownHUD(int seconds) {
    if (seconds <= 0) { hudLabel.hidden = YES; return; }
    UILabel *lab = hudEnsureLabel();
    if (!lab) return;
    lab.text = [NSString stringWithFormat:@"自动停止 %d", seconds];
    [lab sizeToFit];
    CGFloat w = CGRectGetWidth(lab.bounds) + 16.0;
    CGFloat h = CGRectGetHeight(lab.bounds) + 8.0;
    UIView *host = lab.superview;
    CGFloat top = 26.0;
    if (@available(iOS 11.0, *)) top = host.safeAreaInsets.top + 6.0;
    lab.frame = CGRectMake(CGRectGetWidth(host.bounds) - w - 10.0, top, w, h);
    lab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    lab.hidden = NO;
}

static void hideCountdownHUD(void) {
    hudLabel.hidden = YES;
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
                                    // 直接列出 5 档单选，不用一次 +1 循环点好几次
                                    UIAlertController *speedSheet = [UIAlertController alertControllerWithTitle:@"选择滚动速度"
                                                                                                       message:nil
                                                                                                preferredStyle:UIAlertControllerStyleAlert];
                                    for (int i = 0; i <= 4; i++) {
                                        int sel = i; // 每次迭代固定住值，供 block 捕获
                                        NSString *title = (sel == scrollSpeedType) ?
                                            [NSString stringWithFormat:@"✓ %@", speedName(sel)] : speedName(sel);
                                        [speedSheet addAction:[UIAlertAction actionWithTitle:title
                                                                                       style:UIAlertActionStyleDefault
                                                                                     handler:^(UIAlertAction *a) {
                                                                                         scrollSpeedType = sel;
                                                                                     }]];
                                    }
                                    [speedSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                                    [topViewController() presentViewController:speedSheet animated:YES completion:nil];
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
        UIAlertAction *awake = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"屏幕常亮：%@", keepScreenAwake ? @"开" : @"关"] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    keepScreenAwake = !keepScreenAwake;
                                    // 关闭时正在进行的滚动会在 stopUIScroller 里自动还原息屏策略
                                }];
        UIAlertAction *toggle = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@此应用", isDisabled ? @"启用" : @"禁用"] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    if (isDisabled) [[NSUserDefaults standardUserDefaults] setBool:NO forKey:disabledKey()];
                                    else [[NSUserDefaults standardUserDefaults] setBool:YES forKey:disabledKey()];
                                }];
        UIAlertAction *dismiss = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:speed];
        [alert addAction:autoDisable];
        [alert addAction:awake];
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
            [self startUIScroller];
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
        // 交接观察期：先让系统自带减速跑 1~2 帧，实测它真实的滚动速度再接手。
        // 手指速度（panGestureRecognizer）和系统内部投影速度并不相等，直接拿手指速度起步
        // 会在第一帧产生速度跳变 —— 就是"起步那一下衔接不自然"的根因。
        objc_setAssociatedObject(self, kHandoffKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kHandoffOffsetKey, @(self.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kHandoffTimeKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
        if (keepScreenAwake) {
            UIApplication *app = [UIApplication sharedApplication];
            // 先记下 App 原本的息屏策略，停止滚动时还原 —— 不能无脑设 NO，
            // 否则会把视频/导航类 App 本来就该常亮的状态给关掉。
            objc_setAssociatedObject(self, kIdleTimerPrevKey, @(app.idleTimerDisabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kIdleTimerSetKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            app.idleTimerDisabled = YES;
        }

        if (autoDisableMinutes > 0) {
            [self stopAutoDisableTimer];
            __block int remain = autoDisableMinutes * 60;
            // 1 秒一次（不是逐帧）：最后 10 秒才把悬浮窗显示出来，其余时间不打扰阅读
            NSTimer *ad = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer){
                __strong typeof(weakSelf) strongSelf = weakSelf;
                remain--;
                if (remain <= 10 && remain > 0) updateCountdownHUD(remain);
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
        if ([objc_getAssociatedObject(self, kIdleTimerSetKey) boolValue]) {
            BOOL prev = [objc_getAssociatedObject(self, kIdleTimerPrevKey) boolValue];
            [UIApplication sharedApplication].idleTimerDisabled = prev;
            objc_setAssociatedObject(self, kIdleTimerSetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kIdleTimerPrevKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
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
            if (vObs < kAutoTriggerAuto) { [self stopUIScroller]; return; } // 系统没在减速 -> 放弃接管
            objc_setAssociatedObject(self, kDragVelocityKey, @(vObs), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kScrollBaseOffsetKey, @(curOff), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kScrollTravelKey, @(0.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kScrollStartKey, @(nowT), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kLastTickKey, @(nowT), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kVerticalDownKey, @(curOff - lastOff > 0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kHandoffKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
