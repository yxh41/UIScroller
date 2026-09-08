#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIScrollView (UIScroller)
@property (nonatomic,readonly) UIPanGestureRecognizer *panGestureRecognizer;
- (void)startUIScroller;
- (void)stopUIScroller;
- (void)autoScroll;
- (void)handleTaps:(UITapGestureRecognizer *)gesture;
- (void)stopAutoDisableTimer;
- (void)autoDisableScrolling;
@end

// per-instance 状态存在 associated object 上，避免全局单例导致的：
//   1) NSTimer 强引用 UIScrollView 造成的对象泄漏
//   2) 多个 scroll view 共用一个 timer 互相串扰
//   3) didMoveToWindow 反复 addGestureRecognizer 造成手势累积
static const void *kScrollTimerKey      = &kScrollTimerKey;
static const void *kAutoDisableTimerKey = &kAutoDisableTimerKey;
static const void *kTapAddedKey         = &kTapAddedKey;
static const void *kMenuAddedKey        = &kMenuAddedKey;
static const void *kVerticalDownKey     = &kVerticalDownKey;

int scrollSpeedType = 0;    // 0: Slow, 1: Normal, 2: Medium, 3: Fast
int autoDisableMinutes = 0; // 0: Disabled, >0: Minutes until auto-disable

// per-app 禁用 key（原版用全局 key，UI 写 "Disable for this app" 但实际禁用所有 app）
static NSString *disabledKey() {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [NSString stringWithFormat:@"uiscroller_disabled_%@", bid];
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
    if ([topController isKindOfClass:[UINavigationController class]]) {
        UIViewController *visibleController = ((UINavigationController *)topController).visibleViewController;
        if (visibleController) topController = visibleController;
    }
    if (topController != rootController) return topController;
    else return rootController;
}

void openSimpleMenu() {
    if (![topViewController() isKindOfClass:[UIAlertController class]]) {
        BOOL isDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"UIScroller Quick Menu"
                                        message:nil
                                        preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *speed = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Speed: %@", scrollSpeedType == 3 ? @"Fast" : (scrollSpeedType == 2 ? @"Medium" : (scrollSpeedType == 1 ? @"Normal" : @"Slow"))] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    if (scrollSpeedType == 3) scrollSpeedType = 0;
                                    else scrollSpeedType += 1;
                                }];
        UIAlertAction *autoDisable = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Auto-disable: %@", autoDisableMinutes == 0 ? @"Off" : [NSString stringWithFormat:@"%d min", autoDisableMinutes]] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    UIAlertController *inputAlert = [UIAlertController alertControllerWithTitle:@"Set auto-disable Timer"
                                                                                                      message:@"Enter minutes (0 to disable)"
                                                                                               preferredStyle:UIAlertControllerStyleAlert];

                                    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                        textField.keyboardType = UIKeyboardTypeNumberPad;
                                        textField.placeholder = @"Minutes";
                                        textField.text = [NSString stringWithFormat:@"%d", autoDisableMinutes];
                                    }];

                                    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *action) {
                                            NSString *input = inputAlert.textFields.firstObject.text;
                                            int minutes = [input intValue];
                                            if (minutes < 0) minutes = 0;
                                            if (minutes > 180) minutes = 180;
                                            autoDisableMinutes = minutes;
                                            NSString *message = autoDisableMinutes == 0 ?
                                                @"Auto-disable timer disabled" :
                                                [NSString stringWithFormat:@"Auto-disable timer set to %d minutes", autoDisableMinutes];
                                            UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:@"Timer Updated"
                                                                                                                message:message
                                                                                                         preferredStyle:UIAlertControllerStyleAlert];
                                            [confirmation addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                                            [topViewController() presentViewController:confirmation animated:YES completion:nil];
                                        }];

                                    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
                                    [inputAlert addAction:confirmAction];
                                    [inputAlert addAction:cancelAction];
                                    [topViewController() presentViewController:inputAlert animated:YES completion:nil];
                                }];
        UIAlertAction *toggle = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ for this app", isDisabled ? @"Enable" : @"Disable"] style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                    if (isDisabled) [[NSUserDefaults standardUserDefaults] setBool:NO forKey:disabledKey()];
                                    else [[NSUserDefaults standardUserDefaults] setBool:YES forKey:disabledKey()];
                                }];
        UIAlertAction *dismiss = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:speed];
        [alert addAction:autoDisable];
        [alert addAction:toggle];
        [alert addAction:dismiss];
        [topViewController() presentViewController:alert animated:YES completion:nil];
    }
}

%hook UIWindow

    - (void)becomeKeyWindow {
        %orig;
        if (objc_getAssociatedObject(self, kMenuAddedKey)) return; // 去重：每个 window 只加一次
        UILongPressGestureRecognizer *menuGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuLongPress:)];
        menuGestureRecognizer.numberOfTouchesRequired = 2;
        [self addGestureRecognizer:menuGestureRecognizer];
        objc_setAssociatedObject(self, kMenuAddedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %new
    - (void)handleMenuLongPress:(UITapGestureRecognizer *)gesture {
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

        // 去重：只在首次进 window 时加一次单点手势
        if (objc_getAssociatedObject(self, kTapAddedKey)) return;
        UITapGestureRecognizer *singleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTaps:)];
        singleTapGestureRecognizer.numberOfTapsRequired = 1;
        singleTapGestureRecognizer.cancelsTouchesInView = NO;
        [self addGestureRecognizer:singleTapGestureRecognizer];
        objc_setAssociatedObject(self, kTapAddedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    - (void)_scrollViewWillBeginDragging {
        %orig;

        CGPoint velocity = [self.panGestureRecognizer velocityInView:self];

        BOOL isDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:disabledKey()];
        if (!isDisabled) {
            if (fabs(velocity.y) > fabs(velocity.x)) {
                // velocity.y > 0 表示手指向下滑 -> 继续向下滚 -> verticalDown = NO（保持原语义）
                BOOL vDown = (velocity.y <= 0);
                objc_setAssociatedObject(self, kVerticalDownKey, @(vDown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self startUIScroller];
            }
        }
    }

    // 原版这里把 %orig 调了两次（第一次 if 里、第二次 return 里），原实现副作用会执行两次。改为只调一次。
    - (BOOL)_scrollViewWillEndDraggingWithDeceleration:(BOOL)arg1 {
        BOOL r = %orig;
        if (!r && !arg1) [self stopUIScroller];
        return r;
    }

    %new
    - (void)handleTaps:(UITapGestureRecognizer *)gesture {
        [self stopUIScroller];
    }

    %new
    - (void)startUIScroller {
        [self stopUIScroller];

        __weak typeof(self) weakSelf = self;
        // block 版 NSTimer：timer 强引用 block，block 只弱引用 self -> 打破原版对 UIScrollView 的强引用泄漏
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer * _Nonnull timer){
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) [strongSelf autoScroll];
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, kScrollTimerKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
        NSTimer *t = objc_getAssociatedObject(self, kScrollTimerKey);
        if (t) {
            [t invalidate];
            objc_setAssociatedObject(self, kScrollTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
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
        float scrollSpeed = 1.0;
        CGPoint offset = self.contentOffset;

        if (scrollSpeedType == 0) scrollSpeed = 0.5;
        else if (scrollSpeedType == 1) scrollSpeed = 1.0;
        else if (scrollSpeedType == 2) scrollSpeed = 1.5;
        else if (scrollSpeedType == 3) scrollSpeed = 2.0;

        BOOL vDown = [objc_getAssociatedObject(self, kVerticalDownKey) boolValue];
        if (vDown) offset.y += scrollSpeed;
        else offset.y -= scrollSpeed;

        // 越界判断：用 bounds 高度（兼容 zoomScale），且只在真正滚到头时停。
        // 短内容 (contentSize <= bounds) 时 maxOffset=0，offset.y 恒为 0，会立即停 -> 短内容不滚动（符合预期）。
        CGFloat maxOffset = MAX(0, self.contentSize.height - CGRectGetHeight(self.bounds));
        if ((vDown && offset.y >= maxOffset) || (!vDown && offset.y <= 0)) {
            [self stopUIScroller];
            return;
        }

        [self setContentOffset:offset animated:NO];
    }

    %new
    - (void)autoDisableScrolling {
        [self stopUIScroller];
        [self stopAutoDisableTimer];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"UIScroller"
                                                                     message:@"Auto-scrolling has been automatically disabled"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:ok];
        [topViewController() presentViewController:alert animated:YES completion:nil];
    }

%end

%ctor {
    // Only run on user installed apps
    NSString *executablePath = NSProcessInfo.processInfo.arguments[0];
    if ([executablePath containsString:@"/var/containers/Bundle/Application"]) %init;
}
