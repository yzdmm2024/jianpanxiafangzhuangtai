#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置

static NSString *const KS_SUITE = @"com.yzdmm.keyboardstatus";
static NSInteger const KS_TOOLBAR_TAG = 9174;
// 设置面板改值后广播的 darwin 通知（KSSettingsController/KSPreviewCell 里同名 post）
#define KS_DARWIN_NOTI "com.yzdmm.keyboardstatus.prefschanged"

// 前向声明：ksToast / ksGetKeyboardImpl 定义见文件后部，供文件靠前的方法提前调用
static void ksToast(NSString *msg);
static id ksGetKeyboardImpl(void);

#pragma mark - 偏好（跨进程：设置面板与 tweak 共用 KS_SUITE）

// Roothide 实测（2026-09-06 frida）：面板写入的偏好经 RootHide 重定向，落在
// .jbroot-<UUID>/var/mobile/Library/Preferences/ 的文件里；而普通 App 进程的
// CFPreferencesCopyAppValue 走 cfprefsd 默认容器视图，读不到这份文件 → 设置永不生效。
// 解法：读直接落 jbroot 的 plist 文件，与面板写入落点物理一致，绕开 cfprefsd。
static NSString *ksPrefsFilePath(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *leaf = @"var/mobile/Library/Preferences/com.yzdmm.keyboardstatus.plist";
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *p = [@"/var/jb" stringByAppendingPathComponent:leaf];
            if ([fm fileExistsAtPath:p]) { cached = p; return; }
            NSString *base = @"/private/var/containers/Bundle/Application";
            for (NSString *it in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if ([it hasPrefix:@".jbroot-"]) {
                    NSString *cand = [[base stringByAppendingPathComponent:it] stringByAppendingPathComponent:leaf];
                    if ([fm fileExistsAtPath:cand]) { cached = cand; return; }
                }
            }
        } @catch (NSException *e) {}
    });
    return cached;
}

static void KSSyncPrefs(void) {
    // 文件直读无需同步；保留空实现兼容旧调用点
}

static id KSCopyPref(NSString *key) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            id v = d[key];
            // 文件有该键 → 以文件为准（面板经 Roothide 重定向写到这里，进程内 cfprefsd 读不到）
            if (v) return v;
        }
        // 文件缺失该键时（典型：本进程直写 jbroot 文件失败，只有 CFPreferences 落了值）
        // 回退 CFPreferences，保证「保存即生效、删除即消失」，不再因两处存储不一致把默认/旧值复活
        return (__bridge_transfer id)CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, (__bridge CFStringRef)KS_SUITE);
    } @catch (NSException *e) { return nil; }
}

static BOOL KSBool(NSString *key, BOOL def) {
    @try {
        id v = KSCopyPref(key);
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    } @catch (NSException *e) {}
    return def;
}

static CGFloat KSFloat(NSString *key, CGFloat def) {
    @try {
        id v = KSCopyPref(key);
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v floatValue];
    } @catch (NSException *e) {}
    return def;
}

static void KSSetPref(NSString *key, id value) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) {
            // 直写 jbroot 文件（与面板/读侧一致）
            NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:p] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
            if (value) d[key] = value; else [d removeObjectForKey:key];
            [d writeToFile:p atomically:YES];
        }
        // 同时写 CFPreferences 作兜底：避免「不同会话里 jbroot 路径命中不一致」导致
        // 一处写入、另一处读到旧值（表现为设置/短语删了又还原）。两条路径都留最新值。
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)KS_SUITE);
        CFPreferencesSynchronize((__bridge CFStringRef)KS_SUITE,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    } @catch (NSException *e) {}
}

#pragma mark - 剪贴板历史（内存缓存，进程内有效）

static NSMutableArray *ksClipboardHistory = nil;
static const NSUInteger kMaxClip = 30;

static void ksInitClipboardObserver(void) {
    static dispatch_once_t once;
    static id ksClipboardObserver = nil;
    dispatch_once(&once, ^{
        ksClipboardHistory = [[NSMutableArray alloc] init];
        ksClipboardObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIPasteboardChangedNotification object:nil
                       queue:[NSOperationQueue mainQueue]
                  usingBlock:^(NSNotification *note) {
            @try {
                NSString *text = [UIPasteboard generalPasteboard].string;
                if (text.length == 0) return;
                if (ksClipboardHistory.count && [ksClipboardHistory.firstObject isEqualToString:text]) return;
                [ksClipboardHistory insertObject:text atIndex:0];
                if (ksClipboardHistory.count > kMaxClip) [ksClipboardHistory removeLastObject];
            } @catch (NSException *e) {}
        }];
    });
}

#pragma mark - 快捷短语（持久化到全局 suite，跨 App 共享）

static NSArray *ksDefaultPhrases(void) {
    return @[@"好的",@"收到",@"谢谢",@"不客气",@"稍等",@"没问题",
             @"了解",@"OK",@"辛苦了",@"马上处理",@"请稍等"];
}

static NSMutableArray *ksLoadPhrases(void) {
    @try {
        // 存过就尊重（含空数组：用户已清空，不该再把默认短语塞回来）
        id saved = KSCopyPref(@"quickPhrases");
        if ([saved isKindOfClass:[NSArray class]]) return [saved mutableCopy];
    } @catch (NSException *e) {}
    return [ksDefaultPhrases() mutableCopy];
}

static void ksSavePhrases(NSArray *phrases) {
    KSSetPref(@"quickPhrases", phrases);
}

#pragma mark - UI 辅助

// 14.5 SDK 无 UIWindowScene.keyWindow(iOS 15+)，用 windows+isKeyWindow(iOS13 即有) 兼容查找
static UIWindow *ksKeyWindow(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableArray *wins = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in app.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    [wins addObjectsFromArray:((UIWindowScene *)s).windows];
                }
            }
        }
        if (wins.count == 0) [wins addObjectsFromArray:app.windows];
        for (UIWindow *w in wins) {
            if (w.isKeyWindow) return w;
        }
        return wins.lastObject;
    } @catch (NSException *e) { return nil; }
}

static UIResponder *ksFindFirstResponder(void) {
    @try {
        UIWindow *kw = ksKeyWindow();
        return [kw valueForKey:@"firstResponder"];
    } @catch (NSException *e) { return nil; }
}

// 智能隐藏判断：验证码/密码/纯数字键盘、游戏隐藏输入框等场景下不该显示工具栏
// 依据当前第一响应者的输入特征判断，正常打字（QWERTY 文本框）不受影响
static BOOL ksShouldAutoHide(void) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr) return NO;
        // 游戏常用招数：拉起键盘的 UITextField 是隐藏/全透明/极小尺寸的（自己画键盘盖上去）
        // 这种场景系统键盘被盖住，工具栏只会从缝隙里漏出来 → 判定为该隐藏
        if ([fr isKindOfClass:[UIView class]]) {
            UIView *v = (UIView *)fr;
            if (v.hidden || v.alpha < 0.05 ||
                v.bounds.size.width < 10 || v.bounds.size.height < 10) return YES;
        }
        // 不是文本输入trait的（自定义 responder）不乱猜，保持显示
        if (![fr conformsToProtocol:@protocol(UITextInputTraits)]) return NO;
        id<UITextInputTraits> t = (id<UITextInputTraits>)fr;
        // 密码框
        if ([t respondsToSelector:@selector(isSecureTextEntry)] && t.isSecureTextEntry) return YES;
        // 系统验证码字段（短信自动填充的 OneTimeCode）
        if (@available(iOS 10.0, *)) {
            if ([t respondsToSelector:@selector(textContentType)] &&
                [t.textContentType isEqualToString:UITextContentTypeOneTimeCode]) return YES;
        }
        // 数字/小数点/电话键盘（验证码输入几乎全是这几类）
        UIKeyboardType kt = UIKeyboardTypeDefault;
        if ([t respondsToSelector:@selector(keyboardType)]) kt = t.keyboardType;
        if (kt == UIKeyboardTypeNumberPad || kt == UIKeyboardTypeDecimalPad ||
            kt == UIKeyboardTypePhonePad || kt == UIKeyboardTypeASCIICapableNumberPad) return YES;
        return NO;
    } @catch (NSException *e) { return NO; }
}

static UIViewController *ksTopViewController(void) {
    @try {
        UIWindow *kw = ksKeyWindow();
        UIViewController *vc = kw.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    } @catch (NSException *e) { return nil; }
}

static UIButton *ksMakeButton(NSString *sf, NSString *fallback, SEL action, id target, CGFloat iconSize) {
    @try {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:iconSize
                                                                                        weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:sf withConfiguration:cfg];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        if (img) [b setImage:img forState:UIControlStateNormal];
        else if (fallback.length) [b setTitle:fallback forState:UIControlStateNormal];
        [b setTintColor:[UIColor labelColor]];
        b.contentEdgeInsets = UIEdgeInsetsMake(3, 5, 3, 5);
        [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        return b;
    } @catch (NSException *e) { return nil; }
}

static UIView *ksSeparator(void) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 20)];
    v.backgroundColor = [UIColor systemGray4Color];
    return v;
}

#pragma mark - 弹窗：剪贴板历史 / 快捷短语

static void ksShowClipboardHistory(id self) {
    ksInitClipboardObserver();
    UIViewController *vc = ksTopViewController();
    if (!vc) return;
    @try {
        if (ksClipboardHistory.count == 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板历史"
                                                                      message:@"暂无复制记录"
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
            return;
        }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板历史"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *item in ksClipboardHistory) {
            NSString *d = item.length > 40 ? [[item substringToIndex:40] stringByAppendingString:@"…"] : item;
            [a addAction:[UIAlertAction actionWithTitle:d style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
                @try {
                    UIResponder *fr = ksFindFirstResponder();
                    if ([fr conformsToProtocol:@protocol(UITextInput)]) {
                        [UIPasteboard generalPasteboard].string = item;
                        [(id<UITextInput>)fr insertText:item];
                    }
                } @catch (NSException *e) {}
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *act){ [ksClipboardHistory removeAllObjects]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) {}
}

// 批量导入：粘贴多行文本，每行一条，自动忽略空行与去重；可勾选覆盖原有
@interface KSPhraseImportVC : UIViewController
@property (nonatomic, copy) void (^onImport)(NSArray<NSString *> *newPhrases, BOOL replace);
@end

@implementation KSPhraseImportVC {
    UITextView *_tv;
    UISwitch   *_replaceSwitch;
    UIBarButtonItem *_importItem;
    UILabel    *_hint;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"批量导入短语";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _tv = [[UITextView alloc] init];
    _tv.font = [UIFont systemFontOfSize:15];
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    _tv.layer.cornerRadius = 8;
    _tv.layer.borderWidth = 1;
    _tv.layer.borderColor = [[UIColor systemGray4Color] CGColor];
    _tv.text = [UIPasteboard generalPasteboard].string ?: @""; // 自动填入剪贴板，复制即导入
    _tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_tv];

    _hint = [[UILabel alloc] init];
    _hint.font = [UIFont systemFontOfSize:12];
    _hint.textColor = [UIColor secondaryLabelColor];
    _hint.numberOfLines = 0;
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_hint];

    _replaceSwitch = [[UISwitch alloc] init];
    _replaceSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *rl = [[UILabel alloc] init];
    rl.text = @"覆盖原有短语（清空后再导入）";
    rl.font = [UIFont systemFontOfSize:14];
    rl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_replaceSwitch];
    [self.view addSubview:rl];

    UILayoutGuide *mg = self.view.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_tv.topAnchor constraintEqualToAnchor:mg.topAnchor constant:8],
        [_tv.leadingAnchor constraintEqualToAnchor:mg.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:mg.trailingAnchor],
        [_tv.heightAnchor constraintEqualToConstant:240],
        [rl.topAnchor constraintEqualToAnchor:_tv.bottomAnchor constant:12],
        [rl.leadingAnchor constraintEqualToAnchor:mg.leadingAnchor],
        [_replaceSwitch.centerYAnchor constraintEqualToAnchor:rl.centerYAnchor],
        [_replaceSwitch.leadingAnchor constraintEqualToAnchor:rl.trailingAnchor constant:8],
        [_hint.topAnchor constraintEqualToAnchor:rl.bottomAnchor constant:8],
        [_hint.leadingAnchor constraintEqualToAnchor:mg.leadingAnchor],
        [_hint.trailingAnchor constraintEqualToAnchor:mg.trailingAnchor],
    ]];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(cancel)];
    _importItem = [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStyleDone
                                                 target:self action:@selector(doImport)];
    self.navigationItem.rightBarButtonItem = _importItem;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateCount)
                                          name:UITextViewTextDidChangeNotification object:_tv];
    [self updateCount];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 按任意换行符（\n / \r / 其他）分行，trim 后丢弃空行
- (NSArray<NSString *> *)parsedPhrases {
    NSString *raw = _tv.text ?: @"";
    NSArray *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *ln in lines) {
        NSString *t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }
    return out;
}

- (void)updateCount {
    NSInteger n = [self parsedPhrases].count;
    _importItem.title = n > 0 ? [NSString stringWithFormat:@"导入 %ld 条", (long)n] : @"导入";
    _hint.text = n > 0
        ? [NSString stringWithFormat:@"将按换行分隔导入 %ld 条（已自动忽略空行，重复项不重复添加）。", (long)n]
        : @"每行一条短语，粘贴多行文本即可一次性导入。已自动填入剪贴板内容。";
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)doImport {
    NSArray *arr = [self parsedPhrases];
    if (arr.count == 0) { [self cancel]; return; }
    if (self.onImport) self.onImport(arr, _replaceSwitch.isOn);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface KSPhraseEditor : UITableViewController
@end
@implementation KSPhraseEditor {
    NSMutableArray *_phrases;
}
- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _phrases = ksLoadPhrases();
        self.title = @"快捷短语";
        UIBarButtonItem *addBtn =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                         target:self action:@selector(addPhrase)];
        UIBarButtonItem *batchBtn =
            [[UIBarButtonItem alloc] initWithTitle:@"批量" style:UIBarButtonItemStylePlain
                                           target:self action:@selector(batchImport)];
        self.navigationItem.rightBarButtonItems = @[addBtn, batchBtn];
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                           target:self action:@selector(done)];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableFooterView = [[UIView alloc] init];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _phrases.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.textLabel.text = _phrases[ip.row]; c.textLabel.font = [UIFont systemFontOfSize:16];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    @try {
        NSString *t = _phrases[ip.row];
        UIResponder *fr = ksFindFirstResponder();
        if ([fr conformsToProtocol:@protocol(UITextInput)]) [(id<UITextInput>)fr insertText:t];
    } @catch (NSException *e) {}
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st == UITableViewCellEditingStyleDelete) {
        [_phrases removeObjectAtIndex:ip.row]; ksSavePhrases(_phrases);
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleDelete;
}
- (void)addPhrase {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加短语" message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"短语内容"; tf.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
        NSString *t = [[a.textFields.firstObject text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) { [_phrases addObject:t]; ksSavePhrases(_phrases);
            [self.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:_phrases.count-1 inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationAutomatic]; }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)batchImport {
    KSPhraseImportVC *imp = [[KSPhraseImportVC alloc] init];
    __weak typeof(self) w = self;
    imp.onImport = ^(NSArray<NSString *> *newPhrases, BOOL replace) {
        if (replace) [w->_phrases removeAllObjects];
        for (NSString *p in newPhrases)
            if (![w->_phrases containsObject:p]) [w->_phrases addObject:p]; // 去重
        ksSavePhrases(w->_phrases);
        [w.tableView reloadData];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:imp];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static void ksShowQuickPhrases(id self) {
    UIViewController *vc = ksTopViewController();
    if (!vc) return;
    @try {
        KSPhraseEditor *ed = [[KSPhraseEditor alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ed];
        if (@available(iOS 13.0, *)) nav.modalPresentationStyle = UIModalPresentationAutomatic;
        else nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {}
}

#pragma mark - 按钮动作（全部 try/catch 兜底）

static void ksActSelectAll(id s, SEL _c) {
    @try { [[UIApplication sharedApplication] sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil]; } @catch (NSException *e) {}
}
static void ksActCut(id s, SEL _c) {
    @try { [[UIApplication sharedApplication] sendAction:@selector(cut:) to:nil from:nil forEvent:nil]; } @catch (NSException *e) {}
}
static void ksActPaste(id s, SEL _c) {
    @try { [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:nil forEvent:nil]; } @catch (NSException *e) {}
}
// 丢弃输入法组合态（未确认的拼音/候选字）：用 UITextInput 合规的 setMarkedText:@"" + unmarkText。
// 注意：对 markedTextRange 调 replaceRange 在 WKWebView/部分输入框上会抛异常被吞，导致候选残留；
// 这里改用 setMarkedText 把组合态置空再 unmark，稳。
static void ksClearComposition(id<UITextInput> ti) {
    if (!ti) return;
    @try {
        if ([ti respondsToSelector:@selector(setMarkedText:selectedRange:)])
            [ti setMarkedText:@"" selectedRange:NSMakeRange(0, 0)];
        if ([ti respondsToSelector:@selector(unmarkText)]) [ti unmarkText];
    } @catch (NSException *e) {}
}

// 全删：清空正文 + 丢弃未确认候选（markedText），键盘候选条一并清除
static void ksActDeleteAll(id s, SEL _c) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) {
            ksToast(@"请先点进输入框");
            return;
        }
        id<UITextInput> ti = (id<UITextInput>)fr;
        // 候选条由键盘（UIKeyboardImpl）自身持有并渲染，必须先让它放弃组合态，
        // 否则只清文本框、候选条仍挂在键盘上不消失
        id kb = ksGetKeyboardImpl();
        if (kb && [kb respondsToSelector:@selector(setMarkedText:selectedRange:)]) {
            @try { [kb setMarkedText:@"" selectedRange:NSMakeRange(0, 0)]; } @catch (NSException *e) {}
        }
        if (kb && [kb respondsToSelector:@selector(unmarkText)]) {
            @try { [kb unmarkText]; } @catch (NSException *e) {}
        }
        // 清文本框组合态（拼音/候选）
        ksClearComposition(ti);
        // 清空整篇正文（已提交的文字）
        @try {
            UITextRange *all = [ti textRangeFromPosition:ti.beginningOfDocument toPosition:ti.endOfDocument];
            if (all) [ti replaceRange:all withText:@""];
        } @catch (NSException *e) {}
        // 兜底再清一次（部分 App/WKWebView 顺序敏感，键盘可能在清正文后又把组合态推回）
        if (kb && [kb respondsToSelector:@selector(setMarkedText:selectedRange:)]) {
            @try { [kb setMarkedText:@"" selectedRange:NSMakeRange(0, 0)]; } @catch (NSException *e) {}
        }
        if (kb && [kb respondsToSelector:@selector(unmarkText)]) {
            @try { [kb unmarkText]; } @catch (NSException *e) {}
        }
        ksClearComposition(ti);
    } @catch (NSException *e) {}
}
static void ksActCursorLeft(id s, SEL _c) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) return;
        id<UITextInput> ti = (id<UITextInput>)fr;
        UITextRange *r = [ti selectedTextRange]; if (!r) return;
        UITextPosition *p = [ti positionFromPosition:r.start offset:-1]; if (!p) return;
        [ti setSelectedTextRange:[ti textRangeFromPosition:p toPosition:p]];
    } @catch (NSException *e) {}
}
static void ksActCursorRight(id s, SEL _c) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) return;
        id<UITextInput> ti = (id<UITextInput>)fr;
        UITextRange *r = [ti selectedTextRange]; if (!r) return;
        UITextPosition *p = [ti positionFromPosition:r.end offset:1]; if (!p) return;
        [ti setSelectedTextRange:[ti textRangeFromPosition:p toPosition:p]];
    } @catch (NSException *e) {}
}
static void ksActClipboard(id s, SEL _c) { ksShowClipboardHistory(s); }
static void ksActPhrases(id s, SEL _c)  { ksShowQuickPhrases(s); }
// 快捷启动：主路径 LSApplicationWorkspace openApplicationWithBundleID:
// （iOS 16.6.1 实测：openApplicationWithBundleURL: 已不存在；openApplicationWithBundleID: 在微信沙盒内 frida 实测返回 true 拉起成功）
// 兜底 quickActionURL 的 openURL 跳转
static void ksActQuickLaunch(id s, SEL _c) {
    @try {
        NSString *bid = KSCopyPref(@"quickActionBundleId");
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
            id ws = wsCls ? [(id)wsCls performSelector:@selector(defaultWorkspace)] : nil;
            if (ws && [ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
                BOOL ok = (BOOL)[ws performSelector:@selector(openApplicationWithBundleID:) withObject:bid];
                if (ok) return;
            }
        }
        // 兜底：URL Scheme openURL（兼容旧的系统设置页 app-prefs 跳转等）
        NSString *urlStr = KSCopyPref(@"quickActionURL");
        if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) return;
        NSURL *u = [NSURL URLWithString:urlStr];
        if (!u) return;
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    } @catch (NSException *e) {}
}

static void ksActDismiss(id s, SEL _c) {
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder)
                                                    to:nil from:nil forEvent:nil];
    } @catch (NSException *e) {}
}

// 地球键：切换到下一个输入法（把 HideGlobe 藏掉的那个 globe 以按钮形式复活）
// 私有入口：UIKeyboardImpl -setInputModeToNextInPreferredListWithExecutionContext:（iOS 13+ 通用）
//   iOS 12 及更早没有这个方法，回退无参 -setInputModeToNextInPreferredList
// 兼容：本 tweak 最低支持 iOS 15（UIKeyboardDockView 自 iOS 11 即存在，挂载点通用）
// 关键坑：该方法需要一个真实的 UIKeyboardTaskExecutionContext，传 nil 会在系统内部
//   直接 EXC_BAD_ACCESS -> 闪退（@try 抓不住这种内存崩溃）。正确姿势是用 kb.taskQueue
//   包一层：系统在自己的 task block 里会把合法的 context 传进来，正好喂给这个方法。
// 实例获取：优先 +activeInstance，其次 +sharedInstance（iOS 2.0 起就有，最稳），
//   不再依赖 +activeKeyboard（iOS16 上已非类方法）。仍拿不到才回退视图树找 delegate。

// 取当前激活的 UIKeyboardImpl 实例（多路兜底，绝不返回野指针）
static id ksGetKeyboardImpl(void) {
    Class impl = objc_getClass("UIKeyboardImpl");
    if (!impl) return nil;
    id kb = nil;
    if ([impl respondsToSelector:@selector(activeInstance)])
        kb = [impl performSelector:@selector(activeInstance)];
    if (!kb && [impl respondsToSelector:@selector(sharedInstance)])
        kb = [impl performSelector:@selector(sharedInstance)];
    // 极端兜底：在键盘窗口里找 UIKeyboard 私有视图，取其 delegate
    if (!kb) {
        Class kbCls = objc_getClass("UIKeyboard");
        @try {
            NSMutableArray *roots = [NSMutableArray array];
            for (UIWindow *w in [UIApplication sharedApplication].windows) [roots addObject:w];
            for (UIView *root in roots) {
                __block id kbView = nil;
                void (^walk)(UIView *) = ^(UIView *view) {
                    if (kbView) return;
                    if (kbCls && [view isKindOfClass:kbCls]) { kbView = view; return; }
                    for (UIView *sub in view.subviews) walk(sub);
                };
                walk(root);
                if (kbView && [kbView respondsToSelector:@selector(delegate)]) {
                    id d = [kbView performSelector:@selector(delegate)];
                    if (d) return d;
                }
            }
        } @catch (NSException *e) {}
    }
    return kb;
}

static void ksActGlobe(id s, SEL _c) {
    @try {
        id kb = ksGetKeyboardImpl();
        if (!kb) { ksToast(@"无法切换输入法"); return; }
        // 主路径：用 taskQueue 提供真实的 execution context 调用（官方内部姿势，绝不崩）
        // 私有 API 全部用 performSelector 调用，避开“未声明方法”编译错误
        if ([kb respondsToSelector:@selector(taskQueue)] &&
            [kb respondsToSelector:@selector(setInputModeToNextInPreferredListWithExecutionContext:)]) {
            id queue = [kb performSelector:@selector(taskQueue)];
            if (queue) {
                void (^blk)(id, int) = ^(id context, int arg2) {
                    @try {
                        [kb performSelector:@selector(setInputModeToNextInPreferredListWithExecutionContext:) withObject:context];
                    } @catch (NSException *e) {}
                };
                [queue performSelector:@selector(addTask:) withObject:blk];
                return;
            }
        }
        // 兜底：老系统（iOS15 及更早）的无参版本
        if ([kb respondsToSelector:@selector(setInputModeToNextInPreferredList)]) {
            [kb performSelector:@selector(setInputModeToNextInPreferredList)];
            return;
        }
        ksToast(@"无法切换输入法");
    } @catch (NSException *e) {}
}

#pragma mark - AI 按钮（OpenAI 兼容接口：单击默认动作 / 长按菜单）

// 预置模型：0=智谱 GLM-5.3-Flash，1=智谱 GLM-5.3，2=自定义（读 aiBaseURL/aiModel）
static void ksAIEndpoint(NSString **urlOut, NSString **modelOut) {
    NSInteger preset = 0;
    id pv = KSCopyPref(@"aiPreset");
    if ([pv isKindOfClass:[NSNumber class]]) preset = [pv integerValue];
    else if ([pv isKindOfClass:[NSString class]]) preset = [(NSString *)pv integerValue];
    if (preset == 1) {
        *urlOut = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
        *modelOut = @"glm-5.3";
    } else if (preset == 2) {
        id u = KSCopyPref(@"aiBaseURL");
        id m = KSCopyPref(@"aiModel");
        *urlOut  = [u isKindOfClass:[NSString class]] ? u : @"";
        *modelOut = [m isKindOfClass:[NSString class]] ? m : @"";
    } else {
        *urlOut = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
        *modelOut = @"glm-5.3-flash";
    }
}

// 内置动作模板（唯一 %@ = 选中文本）
static NSString *ksAIBuiltinPrompt(NSString *act) {
    NSDictionary *m = @{
        @"polish":  @"请润色改写下面的文本，保持原意、语句通顺，只输出改写结果，不要任何解释：\n\n%@\n",
        @"brief":   @"请精简压缩下面的文本，保留核心信息，只输出结果，不要解释：\n\n%@\n",
        @"expand":  @"请扩写下面的文本，使内容更丰富具体，只输出扩写结果：\n\n%@\n",
        @"summary": @"请总结下面文本的要点，输出简明摘要：\n\n%@\n",
        @"points":  @"请提取下面文本的关键要点，用简洁列表输出：\n\n%@\n",
        @"fix":     @"请纠正下面文本中的错别字和语病，只输出修正后的文本：\n\n%@\n",
        @"explain": @"请用通俗易懂的语言解释下面的文本：\n\n%@\n",
        @"z2e":     @"请把下面的中文翻译成英文，只输出译文：\n\n%@\n",
        @"e2z":     @"请把下面的英文翻译成中文，只输出译文：\n\n%@\n",
        @"ja":      @"请把下面的文本在中文与日文之间互译（中文译成日文，日文译成中文），只输出译文：\n\n%@\n",
        @"code":    @"你是一名资深程序员。请分析下面的代码或报错信息，给出优化后的代码或排查解决步骤：\n\n%@\n",
        @"wenyan":  @"请把下面这段现代中文改写成典雅的文言文，尽量用对仗与典故、保留原意，只输出文言文结果，不要任何解释或标点补充说明：\n\n%@\n",
    };
    return m[act];
}

static NSString *ksAITitle(NSString *act) {
    NSDictionary *m = @{
        @"polish": @"✨ 润色改写", @"brief": @"✂️ 精简压缩", @"expand": @"📝 扩写内容",
        @"summary": @"📋 总结摘要", @"points": @"🔖 提取要点", @"fix": @"🩹 语病纠错",
        @"explain": @"💬 解释文本", @"z2e": @"🌐 中译英", @"e2z": @"🌐 英译中",
        @"ja": @"🌐 中日互译", @"code": @"💻 代码优化/报错分析",
        @"wenyan": @"📜 转文言文",
        @"custom1": @"⭐ 自定义模板 1", @"custom2": @"⭐ 自定义模板 2",
    };
    return m[act] ?: act;
}

// 面板进程/宿主进程通用轻提示（黑底圆角，1.4s 自动消失）
static void ksToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = ksKeyWindow();
            if (!w) return;
            UILabel *l = [[UILabel alloc] init];
            l.text = msg;
            l.font = [UIFont systemFontOfSize:14];
            l.textColor = UIColor.whiteColor;
            l.textAlignment = NSTextAlignmentCenter;
            l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
            l.layer.cornerRadius = 10;
            l.layer.masksToBounds = YES;
            CGFloat pad = 16.0;
            CGSize sz = [l sizeThatFits:CGSizeMake(w.bounds.size.width - 60, CGFLOAT_MAX)];
            l.frame = CGRectMake((w.bounds.size.width - sz.width - pad * 2) / 2,
                                 w.bounds.size.height * 0.35, sz.width + pad * 2, sz.height + 20);
            [w addSubview:l];
            [UIView animateWithDuration:0.2 animations:^{ l.alpha = 0; } completion:^(BOOL fin) {
                l.alpha = 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; }
                        completion:^(BOOL f2){ [l removeFromSuperview]; }];
                });
            }];
        } @catch (NSException *e) {}
    });
}

// loading：按钮转圈 + 保存请求 task（点按钮 = 取消）
static char kKSTaskKey;
static void ksAISetLoading(UIButton *btn, BOOL loading) {
    @try {
        if (!btn) return;
        UIActivityIndicatorView *sp = objc_getAssociatedObject(btn, @selector(ksAIIsLoading));
        if (loading) {
            if (!sp) {
                sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                sp.translatesAutoresizingMaskIntoConstraints = NO;
                [btn addSubview:sp];
                [NSLayoutConstraint activateConstraints:@[
                    [sp.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
                    [sp.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
                ]];
                objc_setAssociatedObject(btn, @selector(ksAIIsLoading), sp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            btn.imageView.hidden = YES;
            btn.alpha = 0.5;
            [sp startAnimating];
        } else {
            btn.imageView.hidden = NO;
            btn.alpha = 1.0;
            [sp stopAnimating];
            sp.hidden = YES;
            objc_setAssociatedObject(btn, &kKSTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (NSException *e) {}
}

static BOOL ksAIIsLoading(UIButton *btn) {
    UIActivityIndicatorView *sp = objc_getAssociatedObject(btn, @selector(ksAIIsLoading));
    return sp && !sp.hidden;
}

// 发请求：prompt → 回调主线程 (result|nil, err|nil)，返回 task 供取消
static NSURLSessionDataTask *ksAIRequest(NSString *prompt, void (^done)(NSString *result, NSString *err)) {
    @try {
        NSString *url = nil, *model = nil;
        ksAIEndpoint(&url, &model);
        id kv = KSCopyPref(@"aiApiKey");
        NSString *key = [kv isKindOfClass:[NSString class]] ? kv : nil;
        if (url.length == 0 || model.length == 0 || key.length == 0) {
            done(nil, @"AI 未配置完整：请到 设置→键盘下方状态→AI 大模型 填写 API Key 等参数");
            return nil;
        }
        CGFloat temp = KSFloat(@"aiTemp", 0.7);
        if (temp < 0) temp = 0; if (temp > 1) temp = 1;

        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        body[@"model"] = model;
        body[@"temperature"] = @(temp);
        body[@"messages"] = @[ @{ @"role": @"user", @"content": prompt } ];
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = data;
        req.timeoutInterval = 60;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];

        __block NSURLSessionDataTask *task;
        task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (e) { done(nil, [NSString stringWithFormat:@"请求失败：%@", e.localizedDescription]); return; }
                    NSInteger code = [(NSHTTPURLResponse *)r statusCode];
                    id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
                    if (code != 200) {
                        NSString *msg = @"服务端错误";
                        if ([json isKindOfClass:[NSDictionary class]]) {
                            id errObj = json[@"error"];
                            if ([errObj isKindOfClass:[NSDictionary class]]) {
                                id m = errObj[@"message"];
                                if ([m isKindOfClass:[NSString class]]) msg = m;
                            } else if ([errObj isKindOfClass:[NSString class]]) {
                                msg = errObj;
                            }
                        }
                        done(nil, [NSString stringWithFormat:@"HTTP %ld：%@", (long)code, msg]);
                        return;
                    }
                    NSString *out = nil;
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        id choices = json[@"choices"];
                        if ([choices isKindOfClass:[NSArray class]] && [choices count] > 0) {
                            id msg = choices[0][@"message"];
                            if ([msg isKindOfClass:[NSDictionary class]]) {
                                id c = msg[@"content"];
                                if ([c isKindOfClass:[NSString class]]) out = c;
                            }
                        }
                    }
                    if (out.length == 0) done(nil, @"返回内容解析失败");
                    else done(out, nil);
                } @catch (NSException *ex) { done(nil, ex.reason ?: @"解析异常"); }
            });
        }];
        [task resume];
        return task;
    } @catch (NSException *e) {
        done(nil, e.reason ?: @"请求异常");
        return nil;
    }
}

// 执行动作：取选中文本 → 拼 prompt → loading → 请求 → 替换/追加
static void ksAIExecute(NSString *act, UIButton *btn) {
    @try {
        if (!act.length) act = @"polish";
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) {
            ksToast(@"请先点进输入框再使用 AI");
            return;
        }
        id<UITextInput> ti = (id<UITextInput>)fr;
        NSString *sel = [ti textInRange:ti.selectedTextRange] ?: @"";
        if (sel.length == 0) {
            ksToast(@"请先选中要处理的文本");
            return;
        }
        // 模板：内置动作走常量格式串；自定义模板用 {{text}} 替换（防用户模板里 % 引发格式崩溃）
        NSString *prompt = nil;
        NSString *builtin = ksAIBuiltinPrompt(act);
        if (builtin) {
            prompt = [NSString stringWithFormat:builtin, sel];
        } else {
            NSString *tpl = nil;
            if ([act isEqualToString:@"custom1"]) tpl = KSCopyPref(@"aiCustomPrompt1");
            else if ([act isEqualToString:@"custom2"]) tpl = KSCopyPref(@"aiCustomPrompt2");
            if (![tpl isKindOfClass:[NSString class]] || tpl.length == 0) {
                ksToast(@"该自定义模板为空，请到设置里填写");
                return;
            }
            prompt = [tpl stringByReplacingOccurrencesOfString:@"{{text}}" withString:sel];
        }
        if (prompt.length == 0) return;

        ksAISetLoading(btn, YES);
        __block UIButton *b = btn;
        NSURLSessionDataTask *task = ksAIRequest(prompt, ^(NSString *result, NSString *err) {
            ksAISetLoading(b, NO);
            if (err) { ksToast(err); return; }
            if (!result) return;
            @try {
                id<UITextInput> t2 = (id<UITextInput>)ksFindFirstResponder();
                if (!t2) return;
                NSInteger outMode = 0;
                id om = KSCopyPref(@"aiOutputMode");
                if ([om isKindOfClass:[NSNumber class]]) outMode = [om integerValue];
                else if ([om isKindOfClass:[NSString class]]) outMode = [(NSString *)om integerValue];
                NSString *curSel = [t2 textInRange:t2.selectedTextRange] ?: @"";
                BOOL hasSel = curSel.length > 0;
                if (outMode == 1 || !hasSel) {
                    // 模式 B：光标后追加（或选区已丢失的兜底）
                    [(id<UITextInput>)t2 insertText:result];
                } else {
                    // 模式 A：直接替换选中文本
                    [(id<UITextInput>)t2 replaceRange:t2.selectedTextRange withText:result];
                }
            } @catch (NSException *e) { ksToast(e.reason ?: @"写入失败"); }
        });
        objc_setAssociatedObject(btn, &kKSTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        ksToast(e.reason ?: @"AI 执行异常");
    }
}

// 单击：执行默认动作；loading 中 = 取消请求
static void ksActAI(id s, SEL _c, id sender) {    @try {
        UIButton *btn = (UIButton *)sender;
        if ([btn isKindOfClass:[UIButton class]] && ksAIIsLoading(btn)) {
            NSURLSessionDataTask *task = objc_getAssociatedObject(btn, &kKSTaskKey);
            [task cancel];
            ksAISetLoading(btn, NO);
            ksToast(@"已取消 AI 请求");
            return;
        }
        NSString *act = KSCopyPref(@"aiDefaultAction");
        if (![act isKindOfClass:[NSString class]] || !act.length) act = @"polish";
        ksAIExecute(act, btn);
    } @catch (NSException *e) {}
}

// 本地文言文转换：内置词典，最长匹配优先逐字替换，不联网、不依赖 AI
// 注：这是「文言风味」转换，非严格古文，胜在即时、离线、零配置
static NSString *ksWenyanConvert(NSString *s) {
    if (s.length == 0) return s;
    static NSDictionary *map = nil;
    static NSArray *keys = nil;     // 按长度降序，保证「不是」先于「不」等
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // —— 代词 ——
            @"我们": @"吾辈", @"你们": @"尔等", @"他们": @"彼等",
            @"自己": @"己", @"什么": @"何", @"怎么": @"何", @"为什么": @"何故",
            @"谁": @"孰", @"哪里": @"何所", @"这里": @"此", @"那里": @"彼",
            @"这个": @"此", @"那个": @"彼", @"这些": @"此辈", @"那些": @"彼辈",
            @"我": @"余", @"你": @"汝", @"他": @"其", @"她": @"其", @"它": @"其",
            // —— 虚词 / 否定 ——
            @"不是": @"非", @"不要": @"勿", @"不能": @"不可", @"不敢": @"不敢",
            @"没有": @"无", @"不": @"弗", @"否": @"否", @"莫": @"莫",
            @"的": @"之", @"地": @"然", @"得": @"得",
            @"了": @"矣", @"吗": @"乎", @"呢": @"哉", @"吧": @"乎", @"啊": @"兮", @"呀": @"兮",
            // —— 连词 / 副词 ——
            @"如果": @"若", @"因为": @"以", @"所以": @"故", @"但是": @"然",
            @"而且": @"且", @"并且": @"且", @"或者": @"或", @"虽然": @"虽",
            @"于是": @"遂", @"然后": @"既而", @"因此": @"是以", @"从而": @"由是",
            @"可以": @"可", @"应该": @"宜", @"需要": @"须", @"想要": @"欲",
            @"就": @"即", @"才": @"方", @"已经": @"既", @"正在": @"方",
            @"将要": @"且", @"突然": @"忽", @"立刻": @"立", @"慢慢": @"徐",
            @"都": @"皆", @"全部": @"悉", @"所有": @"凡", @"许多": @"众",
            @"一些": @"些许", @"很少": @"鲜", @"一切": @"万有",
            // —— 时间 ——
            @"现在": @"今", @"以前": @"昔", @"以后": @"日后", @"今天": @"今日",
            @"明天": @"明日", @"昨天": @"昨日", @"早上": @"旦", @"晚上": @"暮",
            @"时候": @"时", @"不久": @"须臾", @"永远": @"恒",
            // —— 常用动词 ——
            @"说": @"曰", @"告诉": @"语", @"问": @"问", @"回答": @"答",
            @"看": @"观", @"看见": @"见", @"听": @"闻", @"吃": @"食",
            @"喝": @"饮", @"睡觉": @"寐", @"醒": @"寤", @"死": @"殁",
            @"做": @"为", @"使用": @"用", @"给": @"与", @"拿": @"取",
            @"得到": @"得", @"失去": @"失", @"去": @"往", @"来": @"来",
            @"回": @"归", @"走": @"行", @"跑": @"奔", @"知道": @"知",
            @"明白": @"悟", @"喜欢": @"喜", @"讨厌": @"恶", @"思考": @"思",
            @"学习": @"学", @"工作": @"事", @"休息": @"休", @"等候": @"待",
            // —— 名词 ——
            @"朋友": @"友", @"孩子": @"子", @"老师": @"师", @"学生": @"生",
            @"父亲": @"父", @"母亲": @"母", @"妻子": @"妻", @"丈夫": @"夫",
            @"国家": @"国", @"天下": @"天下", @"世界": @"世间", @"事情": @"事",
            @"问题": @"题", @"方法": @"法", @"原因": @"故", @"结果": @"果",
            @"计划": @"计", @"想法": @"意", @"地方": @"处", @"时间": @"时",
            @"书信": @"书", @"话语": @"言", @"文章": @"文",
            // —— 形容词 ——
            @"高兴": @"悦", @"生气": @"怒", @"悲伤": @"哀", @"害怕": @"惧",
            @"大": @"巨", @"小": @"微", @"新": @"新", @"旧": @"故", @"好": @"佳",
            @"坏": @"恶", @"快": @"疾", @"慢": @"缓", @"高": @"高", @"低": @"下",
            @"长": @"修", @"短": @"短", @"多": @"众", @"少": @"寡",
            @"美丽": @"丽", @"聪明": @"慧", @"愚蠢": @"愚", @"富裕": @"富",
            @"贫穷": @"贫", @"健康": @"康", @"危险": @"危", @"安全": @"安",
            // —— 介词 / 方位 ——
            @"在": @"于", @"从": @"自", @"到": @"至", @"和": @"与",
            @"跟": @"与", @"对": @"对", @"把": @"将", @"让": @"使", @"被": @"为",
            @"向": @"向", @"比": @"较", @"为": @"为",
        };
        // 按字符长度降序排序，长词优先匹配，避免「不」抢在「不是」前
        keys = [[map allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b){
            NSInteger la = (NSInteger)a.length, lb = (NSInteger)b.length;
            if (la > lb) return NSOrderedAscending;
            if (la < lb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    });
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, n = s.length;
    while (i < n) {
        BOOL matched = NO;
        for (NSString *k in keys) {
            if (i + k.length <= n &&
                [[s substringWithRange:NSMakeRange(i, k.length)] isEqualToString:k]) {
                [out appendString:map[k]];
                i += k.length;
                matched = YES;
                break;
            }
        }
        if (!matched) {
            [out appendString:[s substringWithRange:NSMakeRange(i, 1)]];
            i += 1;
        }
    }
    return out;
}

// 文言文按钮：本地词典一键转换选中文字（不联网、无需配置 AI）
static void ksActWenyan(id s, SEL _c, id sender) {
    @try {
        UIResponder *fr = ksFindFirstResponder();
        if (!fr || ![fr conformsToProtocol:@protocol(UITextInput)]) {
            ksToast(@"请先点进输入框");
            return;
        }
        id<UITextInput> ti = (id<UITextInput>)fr;
        NSString *sel = [ti textInRange:ti.selectedTextRange] ?: @"";
        if (sel.length == 0) {
            ksToast(@"请先选中要转换的文字");
            return;
        }
        NSString *res = ksWenyanConvert(sel);
        if (res.length == 0) return;
        @try { [ti replaceRange:ti.selectedTextRange withText:res]; }
        @catch (NSException *e) { ksToast(e.reason ?: @"转换失败"); }
    } @catch (NSException *e) {}
}

// 长按：弹出功能菜单（翻译含二级子菜单）
static void ksAILongPress(id s, SEL _c, UILongPressGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan) return;
    @try {
        UIViewController *vc = ksTopViewController();
        if (!vc) return;
        UIButton *btn = (UIButton *)g.view;
        if (![btn isKindOfClass:[UIButton class]]) btn = nil;

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"✨AI处理"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        void (^run)(NSString *) = ^(NSString *act){ ksAIExecute(act, btn); };

        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 润色改写" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"polish"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 精简压缩" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"brief"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 扩写内容" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"expand"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 总结摘要" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"summary"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 提取要点" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"points"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 语病纠错" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"fix"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 解释文本" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"explain"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 翻译 ▷" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                UIAlertController *tr = [UIAlertController alertControllerWithTitle:@"翻译"
                                                                            message:nil
                                                                     preferredStyle:UIAlertControllerStyleActionSheet];
                [tr addAction:[UIAlertAction actionWithTitle:@"中译英" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *x){ run(@"z2e"); }]];
                [tr addAction:[UIAlertAction actionWithTitle:@"英译中" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *x){ run(@"e2z"); }]];
                [tr addAction:[UIAlertAction actionWithTitle:@"中日互译" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *x){ run(@"ja"); }]];
                [tr addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [vc presentViewController:tr animated:YES completion:nil];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"▫️ 💻 代码优化/报错分析" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ run(@"code"); }]];
        // 自定义模板（填写了才显示）
        NSString *c1 = KSCopyPref(@"aiCustomPrompt1");
        if ([c1 isKindOfClass:[NSString class]] && c1.length)
            [sheet addAction:[UIAlertAction actionWithTitle:@"⭐ 自定义模板 1" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a){ run(@"custom1"); }]];
        NSString *c2 = KSCopyPref(@"aiCustomPrompt2");
        if ([c2 isKindOfClass:[NSString class]] && c2.length)
            [sheet addAction:[UIAlertAction actionWithTitle:@"⭐ 自定义模板 2" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a){ run(@"custom2"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"⚙️ AI设置" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                ksToast(@"请打开 设置 → 键盘下方状态 → AI 大模型 配置");
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:sheet animated:YES completion:nil];
    } @catch (NSException *e) {}
}

#pragma mark - Hook：键盘 dock（仅普通 App，不碰主屏幕/设置）

@interface UIKeyboardDockView : UIView
@end

// 工具栏构建尺寸 / 位置约束，用关联对象挂在 stack 上（每个 dock 实例独立）
static char kKSBuiltSizeKey;
static char kKSCXKey;
static char kKSBtmKey;

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;
    @try {
        KSSyncPrefs();  // 拿到设置里最新值（滑块改完，收起再拉起键盘即生效）

        if (!KSBool(@"enabled", YES) || !KSBool(@"toolbarEnabled", YES)) {
            UIView *old = [self viewWithTag:KS_TOOLBAR_TAG];
            if (old) [old removeFromSuperview];
            return;
        }

        // 智能隐藏：验证码/密码/数字键盘/游戏自定义键盘场景不显示（设置里「智能隐藏」开关控制）
        if (KSBool(@"smartHide", YES) && ksShouldAutoHide()) {
            UIView *tb = [self viewWithTag:KS_TOOLBAR_TAG];
            if (tb) tb.hidden = YES;
            return;
        }
        {
            UIView *tb = [self viewWithTag:KS_TOOLBAR_TAG];
            if (tb) tb.hidden = NO;
        }

        CGFloat iconSize = KSFloat(@"iconSize", 15);
        CGFloat offX     = KSFloat(@"toolbarX", -25);   // centerX 偏移（负=往左）
        CGFloat lift     = KSFloat(@"toolbarLift", 35); // 底部抬高量（避开 dock 行与语音键）

        CGFloat spacing = KSFloat(@"toolbarSpacing", 4); // 图标间隔
        // 自定义顺序（面板「按钮排序」写入 toolbarOrder；非法/缺项按默认补齐）
        NSArray *defOrder = @[@"showSelectAll", @"showCut", @"showPaste", @"showClipboard",
                              @"showPhrases", @"showCursor", @"showDismiss", @"showDeleteAll",
                              @"showQuickAction", @"showAI", @"showWenyan", @"showGlobe"];
        NSMutableArray *finalOrder = [NSMutableArray array];
        id savedOrder = KSCopyPref(@"toolbarOrder");
        if ([savedOrder isKindOfClass:[NSArray class]]) {
            for (id o in savedOrder)
                if ([defOrder containsObject:o] && ![finalOrder containsObject:o]) [finalOrder addObject:o];
        }
        for (NSString *k in defOrder)
            if (![finalOrder containsObject:k]) [finalOrder addObject:k];
        // 重建签名：图标大小 + 图标间隔 + 顺序 + 全部功能开关，任一变化都重建整个工具栏
        NSString *sig = [NSString stringWithFormat:@"%.1f|%.0f|%@|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d",
            iconSize, spacing, [finalOrder componentsJoinedByString:@","],
            KSBool(@"showSelectAll", YES), KSBool(@"showCut", YES), KSBool(@"showPaste", YES),
            KSBool(@"showClipboard", YES), KSBool(@"showPhrases", YES), KSBool(@"showCursor", YES),
            KSBool(@"showDismiss", YES), KSBool(@"showDeleteAll", YES), KSBool(@"showQuickAction", NO),
            KSBool(@"showAI", NO), KSBool(@"showWenyan", NO), KSBool(@"showGlobe", YES)];
        UIStackView *stack = (UIStackView *)[self viewWithTag:KS_TOOLBAR_TAG];
        NSString *built = objc_getAssociatedObject(stack, &kKSBuiltSizeKey);
        if (stack && (![built isKindOfClass:[NSString class]] || ![built isEqualToString:sig])) {
            [stack removeFromSuperview];
            stack = nil;
        }

        if (!stack) {
            stack = [[UIStackView alloc] init];
            stack.tag = KS_TOOLBAR_TAG;
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.distribution = UIStackViewDistributionEqualSpacing;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = spacing;
            stack.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:stack];

            UIButton *b;
            for (NSString *k in finalOrder) {
                if ([k isEqualToString:@"showSelectAll"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"selection.pin.in.out", @"全", @selector(ksActSelectAll), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showCut"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"scissors", @"剪", @selector(ksActCut), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showPaste"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"doc.on.clipboard", @"粘", @selector(ksActPaste), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showClipboard"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"list.clipboard", @"历", @selector(ksActClipboard), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showPhrases"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"text.quote", @"语", @selector(ksActPhrases), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showCursor"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"arrow.left",  @"←", @selector(ksActCursorLeft),  self, iconSize); if (b) [stack addArrangedSubview:b];
                    b = ksMakeButton(@"arrow.right", @"→", @selector(ksActCursorRight), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showDismiss"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"keyboard.chevron.compact.down", @"收", @selector(ksActDismiss), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showDeleteAll"] && KSBool(k, YES)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"trash", @"清", @selector(ksActDeleteAll), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showQuickAction"] && KSBool(k, NO)) {
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"rectangle.stack", @"切", @selector(ksActQuickLaunch), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showAI"] && KSBool(k, NO) && KSBool(@"aiEnabled", NO)) {
                    // AI 按钮：单击默认动作，长按弹功能菜单；总开关 aiEnabled 关闭时整个隐藏
                    [stack addArrangedSubview:ksSeparator()];
                    b = ksMakeButton(@"sparkles", @"AI", @selector(ksActAI:), self, iconSize);
                    if (b) {
                        UILongPressGestureRecognizer *lp =
                            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(ksAILongPress:)];
                        lp.minimumPressDuration = 0.4;
                        [b addGestureRecognizer:lp];
                        [stack addArrangedSubview:b];
                    }
                } else if ([k isEqualToString:@"showWenyan"] && KSBool(k, NO)) {
                    // 文言文按钮：复用 AI 管线，单字「文」做符号；未配置 AI 时按下会提示
                    b = ksMakeButton(@"", @"文", @selector(ksActWenyan:), self, iconSize); if (b) [stack addArrangedSubview:b];
                } else if ([k isEqualToString:@"showGlobe"] && KSBool(k, YES)) {
                    b = ksMakeButton(@"globe", @"🌐", @selector(ksActGlobe), self, iconSize); if (b) [stack addArrangedSubview:b];
                }
            }

            NSLayoutConstraint *cx  = [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:offX];
            NSLayoutConstraint *btm = [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-lift];
            cx.active = YES; btm.active = YES;
            objc_setAssociatedObject(stack, &kKSBuiltSizeKey, sig, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(stack, &kKSCXKey,  cx,  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(stack, &kKSBtmKey, btm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            // 已存在：只更新位置参数（实时跟随面板调整）
            NSLayoutConstraint *cx  = objc_getAssociatedObject(stack, &kKSCXKey);
            NSLayoutConstraint *btm = objc_getAssociatedObject(stack, &kKSBtmKey);
            cx.constant  = offX;
            btm.constant = -lift;
        }
    } @catch (NSException *e) {}
}

%end

#pragma mark - darwin 通知：面板改值 → 实时刷新键盘（无需收起再拉起）

static void ksRefreshLayouts(UIView *root) {
    if ([root isKindOfClass:NSClassFromString(@"UIKeyboardDockView")]) { [root setNeedsLayout]; return; }
    for (UIView *sub in [root subviews]) ksRefreshLayouts(sub);
}

static void ksPrefsChangedCB(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            KSSyncPrefs();
            UIApplication *app = [UIApplication sharedApplication];
            NSMutableArray *wins = [NSMutableArray array];
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in app.connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) {
                        [wins addObjectsFromArray:((UIWindowScene *)s).windows];
                    }
                }
            }
            if (wins.count == 0) [wins addObjectsFromArray:app.windows];
            for (UIWindow *w in wins) ksRefreshLayouts(w);
        } @catch (NSException *e) {}
    });
}

#pragma mark - 注入按钮动作方法到 dock 类

%ctor {
    @autoreleasepool {
        Class cls = NSClassFromString(@"UIKeyboardDockView");
        if (!cls) return;
        // 监听设置面板的实时广播（面板每次改开关/滑块都 post 一次）
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        ksPrefsChangedCB, CFSTR(KS_DARWIN_NOTI), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        struct { const char *name; IMP imp; const char *types; } methods[] = {
            {"ksActSelectAll",  (IMP)ksActSelectAll, "v@:"},
            {"ksActCut",        (IMP)ksActCut, "v@:"},
            {"ksActPaste",      (IMP)ksActPaste, "v@:"},
            {"ksActCursorLeft", (IMP)ksActCursorLeft, "v@:"},
            {"ksActCursorRight",(IMP)ksActCursorRight, "v@:"},
            {"ksActClipboard",  (IMP)ksActClipboard, "v@:"},
            {"ksActPhrases",    (IMP)ksActPhrases, "v@:"},
            {"ksActDismiss",    (IMP)ksActDismiss, "v@:"},
            {"ksActDeleteAll",  (IMP)ksActDeleteAll, "v@:"},
            {"ksActQuickLaunch",(IMP)ksActQuickLaunch, "v@:"},
            {"ksActGlobe",      (IMP)ksActGlobe, "v@:"},        // 切换输入法（地球键）
            {"ksActAI:",        (IMP)ksActAI, "v@:@"},          // 带 sender（loading/取消）
            {"ksAILongPress:",  (IMP)ksAILongPress, "v@:@"},    // 长按手势
            {"ksActWenyan:",    (IMP)ksActWenyan, "v@:@"},      // 文言文按钮（复用 AI 管线）
        };
        for (size_t i = 0; i < sizeof(methods)/sizeof(methods[0]); i++) {
            SEL sel = sel_registerName(methods[i].name);
            if (!class_addMethod(cls, sel, methods[i].imp, methods[i].types))
                class_replaceMethod(cls, sel, methods[i].imp, methods[i].types);
        }
    }
}
