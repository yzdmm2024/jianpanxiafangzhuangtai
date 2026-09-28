#import <Preferences/Preferences.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define KS_SUITE @"com.yzdmm.keyboardstatus"
// 与 Tweak.xm 里监听的同名 darwin 通知：面板改值 → tweak 实时刷新
#define KS_DARWIN_NOTI "com.yzdmm.keyboardstatus.prefschanged"

// 14.5 SDK 的 Preferences.h 未必声明该方法，兜底声明（运行时 PSListController 确有实现）
@interface PSListController (KSDeclare)
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end

#pragma mark - 偏好读写：直落 jbroot 文件（与 tweak 完全同款，绕开 cfprefsd）

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

static NSDictionary *KSPrefDict(void) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) return [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

static void KSPostChanged(void) {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR(KS_DARWIN_NOTI), NULL, NULL, TRUE);
    } @catch (NSException *e) {}
}

static void KSWriteKey(NSString *key, id value) {
    @try {
        NSString *p = ksPrefsFilePath();
        if (p) {
            NSMutableDictionary *d = [KSPrefDict() mutableCopy] ?: [NSMutableDictionary dictionary];
            if (value) d[key] = value; else [d removeObjectForKey:key];
            if ([d writeToFile:p atomically:YES]) { KSPostChanged(); return; }
        }
        // 文件写失败退回 CFPreferences（面板进程 root，带 RootHide hook 时同样落 jbroot）
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)KS_SUITE);
        CFPreferencesSynchronize((__bridge CFStringRef)KS_SUITE,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        KSPostChanged();
    } @catch (NSException *e) {}
}

static BOOL KSBool(NSString *key, BOOL def) {
    @try {
        id v = KSPrefDict()[key];
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    } @catch (NSException *e) {}
    return def;
}

static CGFloat KSFloat(NSString *key, CGFloat def) {
    @try {
        id v = KSPrefDict()[key];
        if (v == nil) return def;
        if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v floatValue];
    } @catch (NSException *e) {}
    return def;
}

#pragma mark - 实时预览 cell：固定键盘主体 + 实时工具栏（可拖动调位置）

static NSArray *ksDefaultButtonOrder(void) {
    return @[@"showSelectAll", @"showCut", @"showPaste", @"showClipboard",
             @"showPhrases", @"showCursor", @"showDismiss", @"showDeleteAll",
             @"showQuickAction", @"showAI", @"showGlobe"];
}

// 用户自定义顺序（toolbarOrder）与默认顺序合并：非法/缺失项按默认补齐
static NSArray *ksFinalButtonOrder(void) {
    NSArray *def = ksDefaultButtonOrder();
    NSMutableArray *outOrder = [NSMutableArray array];
    id saved = KSPrefDict()[@"toolbarOrder"];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id o in saved)
            if ([o isKindOfClass:[NSString class]] && [def containsObject:o] && ![outOrder containsObject:o])
                [outOrder addObject:o];
    }
    for (NSString *k in def)
        if (![outOrder containsObject:k]) [outOrder addObject:k];
    return outOrder;
}
static NSDictionary *ksBtnSpecs(void) {
    return @{
        @"showSelectAll":  @[@"selection.pin.in.out", @"全"],
        @"showCut":        @[@"scissors", @"剪"],
        @"showPaste":      @[@"doc.on.clipboard", @"粘"],
        @"showClipboard":  @[@"list.clipboard", @"历"],
        @"showPhrases":    @[@"text.quote", @"语"],
        @"showCursor":     @[@"arrow.right", @"→"],
        @"showDismiss":    @[@"keyboard.chevron.compact.down", @"收"],
        @"showDeleteAll":  @[@"trash", @"清"],
        @"showQuickAction":@[@"rectangle.stack", @"切"],
        @"showAI":         @[@"sparkles", @"AI"],
        @"showGlobe":      @[@"globe", @"🌐"],
    };
}

// PSCustomCell 的 cellClass 必须继承 PSTableCell（坑H：否则点面板闪退）
@interface KSPreviewCell : PSTableCell
@end

@implementation KSPreviewCell {
    UIStackView   *_bar;      // 工具条（实时渲染，1:1 真实尺寸，无键盘主体）
    NSLayoutConstraint *_cx, *_btm;
    NSTimer       *_timer;
    NSString      *_builtSig;
    CGFloat       _iconSize;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        [self refresh];
    }
    return self;
}

// PSCustomCell 可能走这个 init（双保险，两个都实现）
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [self initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    return self;
}

- (UIButton *)ksMakeBtn:(NSString *)sf fallback:(NSString *)fb {
    @try {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:_iconSize
                                                                                          weight:UIImageSymbolWeightRegular];
        UIImage *img = [UIImage systemImageNamed:sf withConfiguration:cfg];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        if (img) [b setImage:img forState:UIControlStateNormal];
        else if (fb.length) [b setTitle:fb forState:UIControlStateNormal];
        [b setTintColor:[UIColor labelColor]];
        b.contentEdgeInsets = UIEdgeInsetsMake(3, 5, 3, 5); // 与 tweak 同款内边距
        b.userInteractionEnabled = NO; // 预览按钮不响应点击，拖动在整条上
        return b;
    } @catch (NSException *e) { return nil; }
}

- (void)rebuildBar {
    @try {
        if (_bar) { [_bar removeFromSuperview]; _bar = nil; _cx = nil; _btm = nil; }
        if (!KSBool(@"enabled", YES) || !KSBool(@"toolbarEnabled", YES)) return;

        _iconSize = KSFloat(@"iconSize", 15);
        CGFloat offX = KSFloat(@"toolbarX", -25);
        CGFloat lift = KSFloat(@"toolbarLift", 35);

        _bar = [[UIStackView alloc] init];
        _bar.axis = UILayoutConstraintAxisHorizontal;
        _bar.distribution = UIStackViewDistributionEqualSpacing;
        _bar.alignment = UIStackViewAlignmentCenter;
        _bar.spacing = KSFloat(@"toolbarSpacing", 4); // 图标间隔与真实工具栏同步
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        // 与真实工具栏一致：无独立底色，图标直接浮在 cell 底色上（1:1，无键盘主体）
        [self.contentView addSubview:_bar];

        // 与 tweak 同款竖线分隔符（剪贴板历史/光标/收起/快捷启动前各一条）
        UIView *__sep;
#define KSPREV_SEP() do { \
            __sep = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 20)]; \
            __sep.backgroundColor = [UIColor systemGray4Color]; \
            [_bar addArrangedSubview:__sep]; \
        } while(0)

        NSDictionary *specs = ksBtnSpecs();
        for (NSString *k in ksFinalButtonOrder()) {
            if ([k isEqualToString:@"showCursor"]) {
                if (!KSBool(@"showCursor", YES)) continue;
                KSPREV_SEP();
                UIButton *b = [self ksMakeBtn:@"arrow.left" fallback:@"←"];
                if (b) [_bar addArrangedSubview:b];
                NSArray *sf_fb = specs[k];
                b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
                if (b) [_bar addArrangedSubview:b];
                continue;
            }
            BOOL def = [k isEqualToString:@"showQuickAction"] || [k isEqualToString:@"showAI"] ? NO : YES;
            if (!KSBool(k, def)) continue;
            if ([k isEqualToString:@"showAI"] && !KSBool(@"aiEnabled", NO)) continue; // AI 总开关关闭不显示
            if ([k isEqualToString:@"showClipboard"] || [k isEqualToString:@"showDismiss"]
                || [k isEqualToString:@"showDeleteAll"]
                || [k isEqualToString:@"showQuickAction"] || [k isEqualToString:@"showAI"]
                || [k isEqualToString:@"showGlobe"]) {
                KSPREV_SEP();
            }
            NSArray *sf_fb = specs[k];
            UIButton *b = [self ksMakeBtn:sf_fb[0] fallback:sf_fb[1]];
            if (b) [_bar addArrangedSubview:b];
        }

        // 与 tweak 完全同款的定位方式：centerX 偏移 + 底边抬高（相对 cell 底边，1:1 映射）
        _cx  = [_bar.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor constant:offX];
        _btm = [_bar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-lift];
        _cx.active = YES; _btm.active = YES;

        // 极端参数（抬高 120 + 图标 26）下 top 防越界约束可能与 bottom 冲突，降级防 unsatisfiable
        NSLayoutConstraint *topGuard = [_bar.topAnchor constraintLessThanOrEqualToAnchor:self.contentView.topAnchor constant:2];
        topGuard.priority = 999;
        topGuard.active = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [_bar addGestureRecognizer:pan];
    } @catch (NSException *e) {}
}

- (void)onPan:(UIPanGestureRecognizer *)p {
    @try {
        if (!_bar) return;
        CGPoint t = [p translationInView:self.contentView];
        [p setTranslation:CGPointZero inView:self.contentView];
        CGFloat offX = KSFloat(@"toolbarX", -25) + t.x;
        CGFloat lift = KSFloat(@"toolbarLift", 35) - t.y; // 往上拖 = 抬高增大
        offX = MIN(120, MAX(-120, offX));
        lift = MIN(120, MAX(0, lift));
        KSWriteKey(@"toolbarX", @(offX));
        KSWriteKey(@"toolbarLift", @(lift));
        [self refresh]; // 立即反映（KSWriteKey 内已广播给 tweak）
    } @catch (NSException *e) {}
}

- (void)refresh {
    @try {
        CGFloat iconSize = KSFloat(@"iconSize", 15);
        // 签名含 iconSize + 每个开关独立一位，任何一项变化都触发重建
        CGFloat spacing = KSFloat(@"toolbarSpacing", 4);
        NSString *orderSig = [ksFinalButtonOrder() componentsJoinedByString:@","];
        NSString *sig = [NSString stringWithFormat:@"%.1f|%.0f|%@|%d%d%d%d%d%d%d%d%d%d%d%d%d",
            iconSize, spacing, orderSig,
            KSBool(@"enabled", YES) && KSBool(@"toolbarEnabled", YES) ? 1 : 0,
            KSBool(@"showSelectAll", YES) ? 1 : 0,
            KSBool(@"showCut", YES) ? 1 : 0,
            KSBool(@"showPaste", YES) ? 1 : 0,
            KSBool(@"showClipboard", YES) ? 1 : 0,
            KSBool(@"showPhrases", YES) ? 1 : 0,
            KSBool(@"showCursor", YES) ? 1 : 0,
            KSBool(@"showDismiss", YES) ? 1 : 0,
            KSBool(@"showDeleteAll", YES) ? 1 : 0,
            KSBool(@"showQuickAction", NO) ? 1 : 0,
            (KSBool(@"showAI", NO) && KSBool(@"aiEnabled", NO)) ? 1 : 0,
            KSBool(@"showGlobe", YES) ? 1 : 0];
        if (![sig isEqualToString:_builtSig]) {
            _builtSig = sig;
            [self rebuildBar];
        }
        if (_cx) _cx.constant = KSFloat(@"toolbarX", -25);
        if (_btm) _btm.constant = -KSFloat(@"toolbarLift", 35);
    } @catch (NSException *e) {}
}

// 定时器轮询（0.25s）：开关/滑块改动自动反映到预览；页面退出时停掉
- (void)didMoveToWindow {
    [super didMoveToWindow];
    @try {
        if (self.window == nil) {
            [_timer invalidate]; _timer = nil;
        } else if (!_timer) {
            _timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        }
    } @catch (NSException *e) {}
}

- (void)dealloc {
    [_timer invalidate]; _timer = nil;
}

@end

#pragma mark - 自定义滑块 cell：左侧文字(PSTableCell 自带 textLabel) + 右侧滑条
// 关键：PSCustomCell 实际走 initWithStyle:reuseIdentifier: 创建（setSpecifier: 后补配置），
// 自定义 UI 必须在 initWithStyle 里构建；KSPreviewCell 能工作正是这个原因。

@interface KSSliderCell : PSTableCell
@end

@implementation KSSliderCell {
    UISlider    *_slider;
    PSSpecifier *_spec;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        if (!_slider) {
            _slider = [[UISlider alloc] init];
            _slider.translatesAutoresizingMaskIntoConstraints = NO;
            // ⚠️ 事件绑定必须在这里挂（v1.0.11 重构时丢失，导致拖滑条不写入、预览不同步、切 App 回退旧值）
            [_slider addTarget:self action:@selector(ksSlide:) forControlEvents:UIControlEventValueChanged];
            [self.contentView addSubview:_slider];
            // 左侧 ~150pt 留给 textLabel（specifier 的 label 由父类填充显示）
            [NSLayoutConstraint activateConstraints:@[
                [_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:150],
                [_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
                [_slider.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            ]];
        }
    }
    return self;
}

// 兜底：部分调用路径走这个（内部转 initWithStyle 构建）
- (instancetype)initWithSpecifier:(PSSpecifier *)spec {
    self = [self initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    return self;
}

// Preferences 创建后调 setSpecifier: 传 plist 配置 → 在这里读 key/min/max/default 配置滑条
- (void)setSpecifier:(PSSpecifier *)spec {
    [super setSpecifier:spec];
    _spec = spec;
    @try {
        if (!_slider || !spec) return;
        NSString *key = [spec propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] || !key.length) return;
        id mnV = [spec propertyForKey:@"min"], mxV = [spec propertyForKey:@"max"], dvV = [spec propertyForKey:@"default"];
        CGFloat mn = [mnV isKindOfClass:[NSNumber class]] ? [mnV floatValue] : 0;
        CGFloat mx = [mxV isKindOfClass:[NSNumber class]] ? [mxV floatValue] : 100;
        CGFloat dv = [dvV isKindOfClass:[NSNumber class]] ? [dvV floatValue] : mn;
        _slider.minimumValue = mn;
        _slider.maximumValue = mx;
        _slider.value = KSFloat(key, dv);
    } @catch (NSException *e) {}
}

- (void)ksSlide:(UISlider *)s {
    @try {
        NSString *key = [_spec propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] || !key.length) return;
        KSWriteKey(key, @(s.value)); // 直写 jbroot 文件 + 广播，预览与真实键盘实时跟随
    } @catch (NSException *e) {}
}

@end

#pragma mark - 主设置控制器

@interface KSSettingsController : PSListController
@end

@implementation KSSettingsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 每次开关/滑块改值都会走到这里（PSSwitchCell/PSSliderCell 的标准写入链路）
// → super 写 cfprefsd（RootHide 环境落 jbroot）→ 再直写文件双保险 → 广播 darwin 通知
- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    @try {
        [super setPreferenceValue:value specifier:specifier];
        if ([specifier respondsToSelector:@selector(propertyForKey:)]) {
            NSString *key = [specifier propertyForKey:@"key"];
            if ([key isKindOfClass:[NSString class]] && key.length) {
                NSString *p = ksPrefsFilePath();
                if (p) {
                    NSMutableDictionary *d = [KSPrefDict() mutableCopy] ?: [NSMutableDictionary dictionary];
                    if (value) d[key] = value;
                    [d writeToFile:p atomically:YES]; // 与 super 写的值一致，谁后写都无冲突
                }
            }
        }
        KSPostChanged();
    } @catch (NSException *e) {}
}

@end

#pragma mark - 子菜单入口 cell（点击 push 子页面；实现放文件尾，因引用其后的子页面类）

#pragma mark - 按钮排序页（拖动上下 = 键盘从左到右，即拖即存即生效）

@interface KSOrderViewController : UITableViewController
@end

@implementation KSOrderViewController {
    NSMutableArray *_keys;
    NSDictionary   *_names;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"按钮排序";
        _names = @{@"showSelectAll": @"全选", @"showCut": @"剪切", @"showPaste": @"粘贴",
                   @"showClipboard": @"剪贴板历史", @"showPhrases": @"快捷短语",
                   @"showCursor": @"光标左右移", @"showDismiss": @"收起键盘",
                   @"showDeleteAll": @"全删",
                   @"showQuickAction": @"快捷启动", @"showAI": @"AI 按钮",
                   @"showGlobe": @"切换输入法"};
        _keys = [ksFinalButtonOrder() mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(done)];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"k"];
}

// 进页面立刻进入编辑模式（UITableViewController 层会同步 tableView，把手才出现）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setEditing:YES animated:NO];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_keys removeAllObjects];
    [_keys addObjectsFromArray:ksFinalButtonOrder()];
    [self.tableView reloadData];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @"按住右侧 ≡ 把手，上下拖动即可调整按钮从左到右的顺序";
}

- (void)done {
    if (self.presentingViewController) [self dismissViewControllerAnimated:YES completion:nil];
    else [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _keys.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"k"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"k"];
    NSString *k = _keys[ip.row];
    c.textLabel.text = _names[k] ?: k;
    c.detailTextLabel.text = [NSString stringWithFormat:@"键盘上第 %lu 个", (unsigned long)ip.row + 1];
    return c;
}

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return YES; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip { return NO; }

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *k = _keys[from.row];
    [_keys removeObjectAtIndex:from.row];
    [_keys insertObject:k atIndex:to.row];
    for (NSInteger i = 0; i < (NSInteger)_keys.count; i++) {
        UITableViewCell *c = [tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
        c.detailTextLabel.text = [NSString stringWithFormat:@"键盘上第 %lu 个", (unsigned long)i + 1];
    }
    KSWriteKey(@"toolbarOrder", _keys); // 即存即广播：真实键盘与预览实时变
}

@end

#pragma mark - App 选择页（全部第三方 App 带图标，点选即设并自动返回）

// LSApplicationWorkspace 是私有类（SDK 无符号），一律 NSClassFromString 运行时获取，避免链接错误
@interface UIImage (KSIconPriv)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(NSInteger)fmt;
@end

@interface LSApplicationProxy : NSObject
+ (NSArray *)allApplications;
- (NSString *)localizedName;
- (NSString *)bundleIdentifier;
// iOS 16.6.1 实测：objectForInfoDictionaryKey: 不存在（unrecognized selector），
// 取 Info.plist 字典用 infoDictionary；URL Scheme 直接用 claimedURLSchemes
- (id)infoDictionary;
- (NSArray *)claimedURLSchemes;
@end

// 仅声明原型（NSClassFromString 拿 Class 后强转调用，编译期不产生链接符号）
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface KSAppPickerViewController : UITableViewController <UISearchResultsUpdating>
@end

@implementation KSAppPickerViewController {
    NSMutableArray *_apps;      // @{bid,name,icon,scheme}
    NSMutableArray *_filtered;  // 搜索过滤后的显示数组
    NSString *_selectedBid;
    UISearchController *_searchController;
    NSString *_diag;            // 空列表时的诊断信息
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) { self.title = @"选择跳转 App"; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self ksLoad];
    // 搜索框（列表非空才挂上）
    if (_apps.count) {
        _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        _searchController.searchResultsUpdater = self;
        _searchController.obscuresBackgroundDuringPresentation = NO;
        _searchController.searchBar.placeholder = @"搜索 App 名称";
        self.navigationItem.searchController = _searchController;
        self.navigationItem.hidesSearchBarWhenScrolling = NO; // 进页面直接可见
        _filtered = [_apps mutableCopy];
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    [self ksApplyFilter];
}

- (void)ksApplyFilter {
    if (!_filtered) return;
    NSString *q = _searchController.searchBar.text ?: @"";
    [_filtered removeAllObjects];
    if (q.length == 0) {
        [_filtered addObjectsFromArray:_apps];
    } else {
        for (NSDictionary *a in _apps) {
            if ([a[@"name"] localizedCaseInsensitiveContainsString:q] ||
                [a[@"bid"] localizedCaseInsensitiveContainsString:q])
                [_filtered addObject:a];
        }
    }
    [self.tableView reloadData];
}

// 图标等比降到标准 29pt（cell 行高不至被大图标撑爆；format:2 原始尺寸过大）
static UIImage *ksIconStd(UIImage *img) {
    if (![img isKindOfClass:[UIImage class]]) return nil;
    CGFloat w = img.size.width;
    if (w <= 29.0 || w <= 0) return img;
    return [UIImage imageWithCGImage:img.CGImage scale:(w / 29.0)
                                          orientation:UIImageOrientationUp];
}

// 从 LSApplicationProxy 取 URL Scheme（workspace/proxy 两通道共用）
// v1.2.6：infoDictionary 返回懒加载包装对象 objectForKey 取不到数据 → 改优先 claimedURLSchemes
// （frida 实测 iOS 16.6.1：137 个三方 App 中 100 个有 scheme，微信 16 个）
- (NSString *)ksSchemeOfProxy:(LSApplicationProxy *)p {
    NSString *scheme = @"";
    @try {
        if ([p respondsToSelector:@selector(claimedURLSchemes)]) {
            NSArray *arr = [p claimedURLSchemes];
            for (NSString *s in arr) {
                if ([s isKindOfClass:[NSString class]] && s.length) { scheme = s; break; }
            }
        }
        if (scheme.length == 0 && [p respondsToSelector:@selector(infoDictionary)]) {
            id info = [p infoDictionary];
            if ([info respondsToSelector:@selector(objectForKey:)]) {
                id types = [info objectForKey:@"CFBundleURLTypes"];
                if ([types isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *t in types) {
                        id names = [t objectForKey:@"CFBundleURLSchemes"];
                        if ([names isKindOfClass:[NSArray class]] && [names count] > 0) {
                            NSString *s = [names firstObject];
                            if ([s isKindOfClass:[NSString class]] && s.length) { scheme = s; break; }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    return scheme;
}

// 通道3兜底：直接扫 App 安装目录读 Info.plist（磁盘枚举，不依赖任何私有 API）
static NSArray *ksScanDiskApps(NSMutableArray *diag) {
    NSMutableArray *list = [NSMutableArray array];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *bases = @[@"/var/mobile/Containers/Bundle/Application",
                           @"/var/containers/Bundle/Application",
                           @"/var/jb/var/mobile/Containers/Bundle/Application",
                           @"/var/jb/var/containers/Bundle/Application"];
        for (NSString *base in bases) {
            NSArray *uuids = [fm contentsOfDirectoryAtPath:base error:nil];
            [diag addObject:[NSString stringWithFormat:@"%@:%lu", base.lastPathComponent, (unsigned long)uuids.count]];
            for (NSString *uuid in uuids) {
                NSString *dir = [base stringByAppendingPathComponent:uuid];
                for (NSString *a in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                    if (![a hasSuffix:@".app"]) continue;
                    NSString *infoPath = [dir stringByAppendingPathComponent:
                                          [a stringByAppendingPathComponent:@"Info.plist"]];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                    if (![info isKindOfClass:[NSDictionary class]]) continue;
                    NSString *bid = info[@"CFBundleIdentifier"];
                    if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
                    if ([bid hasPrefix:@"com.apple."]) continue;
                    BOOL dup = NO;
                    for (NSDictionary *e in list)
                        if ([e[@"bid"] isEqualToString:bid]) { dup = YES; break; }
                    if (dup) continue;
                    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bid;
                    NSString *scheme = @"";
                    id types = info[@"CFBundleURLTypes"];
                    if ([types isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *t in types) {
                            id names = t[@"CFBundleURLSchemes"];
                            if ([names isKindOfClass:[NSArray class]] && [names count] > 0) {
                                NSString *s = [names firstObject];
                                if ([s isKindOfClass:[NSString class]] && s.length) { scheme = s; break; }
                            }
                        }
                    }
                    [list addObject:@{ @"bid": bid, @"name": name,
                                       @"icon": [NSNull null], @"scheme": scheme }];
                }
            }
            if (list.count) break; // 主路径有数据就不再试备用路径
        }
    } @catch (NSException *e) {
        [diag addObject:[NSString stringWithFormat:@"扫盘异常:%@", e.reason ?: @""]];
    }
    return list;
}

// 列全部第三方 App：通道1 workspace（类型化直调）→ 通道2 proxy.allApplications → 通道3 扫盘
// 每个 App 独立 @try：单个坏 App 不再拖死整个通道；诊断结果同时落盘供 frida 读取
- (void)ksLoad {
    NSMutableArray *list = [NSMutableArray array];
    NSMutableArray *diag = [NSMutableArray array];
    @try {
        // 通道1：LSApplicationWorkspace（dlopen 保险）
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsCls) {
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
            wsCls = NSClassFromString(@"LSApplicationWorkspace");
        }
        [diag addObject:[NSString stringWithFormat:@"WS:%@", wsCls ? @"有" : @"无"]];
        if (wsCls) {
            id ws = [(id)wsCls defaultWorkspace]; // 类方法：receiver 必须 id/Class 才匹配 +defaultWorkspace
            [diag addObject:[NSString stringWithFormat:@"wsObj:%@", ws ? @"有" : @"无"]];
            NSArray *all = [(LSApplicationWorkspace *)ws allInstalledApplications];
            [diag addObject:[NSString stringWithFormat:@"ws:%lu", (unsigned long)all.count]];
            for (id p in all) {
                @try {
                    NSString *bid = [p bundleIdentifier];
                    if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
                    if ([bid hasPrefix:@"com.apple."]) continue;
                    NSString *name = [p localizedName];
                    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bid;
                    UIImage *icon = nil;
                    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)])
                        icon = ksIconStd([UIImage _applicationIconImageForBundleIdentifier:bid format:2]);
                    [list addObject:@{ @"bid": bid, @"name": name,
                                       @"icon": icon ?: [NSNull null],
                                       @"scheme": [self ksSchemeOfProxy:p] }];
                } @catch (NSException *e) {
                    if (diag.count < 6) // 只记前几条，避免诊断行刷屏
                        [diag addObject:[NSString stringWithFormat:@"p异常:%@", e.name ?: @""]];
                }
            }
        }
        // 通道2：LSApplicationProxy +allApplications（16.6.1 实测 respondsToSelector=NO，保留兼容）
        if (list.count == 0) {
            Class proxyCls = NSClassFromString(@"LSApplicationProxy");
            BOOL ok = proxyCls && [proxyCls respondsToSelector:@selector(allApplications)];
            [diag addObject:[NSString stringWithFormat:@"proxy:%@", ok ? @"可用" : @"不可用"]];
            if (ok) {
                NSArray *proxies = [(id)proxyCls allApplications];
                for (id p in proxies) {
                    @try {
                        NSString *bid = [p bundleIdentifier];
                        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
                        if ([bid hasPrefix:@"com.apple."]) continue;
                        NSString *name = [p localizedName];
                        if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bid;
                        [list addObject:@{ @"bid": bid, @"name": name,
                                           @"icon": [NSNull null],
                                           @"scheme": [self ksSchemeOfProxy:p] }];
                    } @catch (NSException *e) {
                        if (diag.count < 6) // 只记前几条，避免诊断行刷屏
                            [diag addObject:[NSString stringWithFormat:@"p异常:%@", e.name ?: @""]];
                    }
                }
            }
        }
        // 通道3：扫盘
        if (list.count == 0) [list addObjectsFromArray:ksScanDiskApps(diag)];
    } @catch (NSException *e) {
        [diag addObject:[NSString stringWithFormat:@"异常:%@ %@", e.name ?: @"", e.reason ?: @""]];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    _apps = list;
    _filtered = [list mutableCopy];
    _diag = [diag componentsJoinedByString:@" "];
    _selectedBid = KSPrefDict()[@"quickActionBundleId"];
    if (![_selectedBid isKindOfClass:[NSString class]]) _selectedBid = nil;
    // 诊断落盘：列表为空时 frida 直读此文件即可定位，无需截图
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | 列表:%lu\n",
                      [NSDate date], _diag ?: @"", (unsigned long)list.count];
    [line writeToFile:@"/var/mobile/Library/Preferences/com.yzdmm.keyboardstatus.applist_diag.txt"
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _filtered.count ? _filtered.count : 1; // 空列表显示一行诊断提示
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // 不用 registerClass：默认样式没有 detailTextLabel（v1.2.2 诊断行因此显示不出来），改 Subtitle
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"a"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
    if (_filtered.count == 0) {
        c.textLabel.text = @"未获取到 App 列表";
        c.textLabel.numberOfLines = 1;
        c.detailTextLabel.text = _diag ?: nil; // 各通道诊断结果（Subtitle 样式此时可见）
        c.detailTextLabel.numberOfLines = 0;
        c.detailTextLabel.font = [UIFont systemFontOfSize:11];
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        c.imageView.image = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    NSDictionary *a = _filtered[ip.row];
    c.textLabel.text = a[@"name"];
    c.textLabel.numberOfLines = 1;
    NSString *scheme = a[@"scheme"];
    c.detailTextLabel.text = scheme.length ? [scheme stringByAppendingString:@"://"] : @"无 Scheme · 点选后直接拉起";
    c.detailTextLabel.numberOfLines = 1;
    c.detailTextLabel.font = nil;
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    UIImage *icon = a[@"icon"];
    if (![icon isKindOfClass:[UIImage class]]) {
        // 扫盘/代理兜底条目无图标：cell 复用时懒加载一次
        if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)])
            icon = ksIconStd([UIImage _applicationIconImageForBundleIdentifier:a[@"bid"] format:2]);
        if ([icon isKindOfClass:[UIImage class]]) {
            NSMutableDictionary *m = [a mutableCopy];
            m[@"icon"] = icon;
            NSUInteger ai = [_apps indexOfObject:a];
            if (ai != NSNotFound) [_apps replaceObjectAtIndex:ai withObject:m];
            [_filtered replaceObjectAtIndex:ip.row withObject:m];
        }
    }
    if ([icon isKindOfClass:[UIImage class]]) c.imageView.image = icon;
    else c.imageView.image = nil;
    c.accessoryType = [a[@"bid"] isEqualToString:_selectedBid]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_filtered.count == 0 || ip.row >= (NSInteger)_filtered.count) return;
    NSDictionary *a = _filtered[ip.row];
    _selectedBid = a[@"bid"];
    KSWriteKey(@"quickActionBundleId", _selectedBid); // 记录选择（勾选用）
    NSString *scheme = a[@"scheme"];
    // 有 Scheme 写 scheme://（openURL 跳转）；无 Scheme 写空串，工具栏按 bundle id 私有 API 拉起
    KSWriteKey(@"quickActionURL",
               ([scheme isKindOfClass:[NSString class]] && scheme.length)
                   ? [scheme stringByAppendingString:@"://"] : @"");
    [tv reloadData];
    // 单选完成即自动返回（选择自动替换上次选择）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.navigationController popViewControllerAnimated:YES];
    });
}

@end

#pragma mark - 子菜单入口 cell（实现置尾：alloc 的两个子页面类已在上方完整定义）

@interface KSMenuCell : PSTableCell
@end

@implementation KSMenuCell {
    PSSpecifier *_spec;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ksOpen)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)spec {
    [super setSpecifier:spec];
    _spec = spec;
}

// 双通道触发：tap 手势 + 点击选中（didSelectRow 会走 setSelected:YES），
// 防止其中一条路径被 Preferences 框架吞掉导致点击无反应
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    if (selected) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(ksOpen) object:nil];
        [self performSelector:@selector(ksOpen) withObject:nil afterDelay:0.05];
    }
}

- (UIViewController *)ksOwningVC {
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

- (void)ksOpen {
    @try {
        NSString *menu = [_spec propertyForKey:@"menu"];
        UIViewController *target = nil;
        if ([menu isEqualToString:@"order"]) target = [[KSOrderViewController alloc] init];
        else if ([menu isEqualToString:@"apppicker"]) target = [[KSAppPickerViewController alloc] init];
        if (!target) return;
        UIViewController *owner = [self ksOwningVC];
        if (owner.navigationController) {
            [owner.navigationController pushViewController:target animated:YES];
        } else {
            // 兜底：无导航栈时模态弹出
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:target];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [owner presentViewController:nav animated:YES completion:nil];
        }
    } @catch (NSException *e) {}
}

@end

#pragma mark - AI 连通性测试 cell（点击发一条测试消息，弹窗显示结果）

static void ksAIPreset(NSInteger preset, NSString **urlOut, NSString **modelOut) {
    if (preset == 1) {
        *urlOut = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
        *modelOut = @"glm-5.3";
    } else if (preset == 2) {
        id u = KSPrefDict()[@"aiBaseURL"];
        id m = KSPrefDict()[@"aiModel"];
        *urlOut = [u isKindOfClass:[NSString class]] ? u : @"";
        *modelOut = [m isKindOfClass:[NSString class]] ? m : @"";
    } else {
        *urlOut = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
        *modelOut = @"glm-5.3-flash";
    }
}

@interface KSAITestCell : PSTableCell
@end

@implementation KSAITestCell {
    PSSpecifier *_spec;
    BOOL _running;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)spec {
    [super setSpecifier:spec];
    _spec = spec;
    self.textLabel.text = @"🧪 AI 连通性测试";
    self.detailTextLabel.text = @"点此发送测试消息，验证 API Key 与接口";
    self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
}

- (UIViewController *)ksOwningVC {
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

- (void)ksShowResult:(NSString *)title message:(NSString *)msg {
    UIViewController *vc = [self ksOwningVC];
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

- (void)ksTest {
    if (_running) return;
    @try {
        NSDictionary *d = KSPrefDict();
        NSString *key = d[@"aiApiKey"];
        if (![key isKindOfClass:[NSString class]]) key = nil;
        if (key.length == 0) {
            [self ksShowResult:@"缺少 API Key" message:@"请先在上方「API Key」填入你的密钥"];
            return;
        }
        NSInteger preset = 0;
        id pv = d[@"aiPreset"];
        if ([pv isKindOfClass:[NSNumber class]]) preset = [pv integerValue];
        else if ([pv isKindOfClass:[NSString class]]) preset = [(NSString *)pv integerValue];
        NSString *url = nil, *model = nil;
        ksAIPreset(preset, &url, &model);
        if (url.length == 0 || model.length == 0) {
            [self ksShowResult:@"自定义接口未填完整" message:@"请填写「API 接口地址」和「模型名称」"];
            return;
        }
        CGFloat temp = 0.7;
        id tv = d[@"aiTemp"];
        if ([tv isKindOfClass:[NSNumber class]]) temp = [tv floatValue];

        _running = YES;
        self.detailTextLabel.text = @"测试中…";
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        body[@"model"] = model;
        body[@"temperature"] = @(temp);
        body[@"messages"] = @[ @{ @"role": @"user", @"content": @"你好，只回复四个字：连接成功" } ];
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = data;
        req.timeoutInterval = 30;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];

        __weak typeof(self) wself = self;
        NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *dt, NSURLResponse *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(wself) sself = wself;
                if (!sself) return;
                sself->_running = NO;
                sself.detailTextLabel.text = @"点此发送测试消息，验证 API Key 与接口";
                @try {
                    if (e) { [sself ksShowResult:@"❌ 连接失败" message:e.localizedDescription]; return; }
                    NSInteger code = [(NSHTTPURLResponse *)r statusCode];
                    id json = dt ? [NSJSONSerialization JSONObjectWithData:dt options:0 error:nil] : nil;
                    if (code != 200) {
                        NSString *m = @"服务端错误";
                        id errObj = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
                        if ([errObj isKindOfClass:[NSDictionary class]]) {
                            id mm = errObj[@"message"];
                            if ([mm isKindOfClass:[NSString class]]) m = mm;
                        }
                        [sself ksShowResult:[NSString stringWithFormat:@"❌ HTTP %ld", (long)code] message:m];
                        return;
                    }
                    NSString *out = nil;
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        id ch = json[@"choices"];
                        if ([ch isKindOfClass:[NSArray class]] && [ch count] > 0) {
                            id msg = ch[0][@"message"];
                            if ([msg isKindOfClass:[NSDictionary class]]) {
                                id c = msg[@"content"];
                                if ([c isKindOfClass:[NSString class]]) out = c;
                            }
                        }
                    }
                    if (out.length) {
                        [sself ksShowResult:@"✅ 连接成功"
                                    message:[NSString stringWithFormat:@"模型 %@ 回复：%@", model, out]];
                    } else {
                        [sself ksShowResult:@"⚠️ 返回异常" message:@"未解析到回复内容"];
                    }
                } @catch (NSException *ex) {
                    sself->_running = NO;
                    [sself ksShowResult:@"❌ 异常" message:ex.reason ?: @"解析失败"];
                }
            });
        }];
        [t resume];
    } @catch (NSException *e) {
        _running = NO;
        [self ksShowResult:@"❌ 异常" message:e.reason ?: @"测试失败"];
    }
}

// 双通道触发（与 KSMenuCell 同款：走 setSelected 选中触发更可靠）
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    if (selected) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(ksTest) object:nil];
        [self performSelector:@selector(ksTest) withObject:nil afterDelay:0.05];
    }
}

@end
