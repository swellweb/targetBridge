#import "tb_background_ui.h"

#import <AppKit/AppKit.h>
#include <string.h>

#include "tb_i18n.h"

static NSString *const kBackgroundModeKey = @"backgroundMode";   /* before 4.0 */
static NSString *const kAppPresentationKey = @"appPresentation";
static NSString *const kShowWindowAtStartKey = @"showWindowAtStart";

@interface TBBackgroundUI : NSObject
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusLine;
@property(nonatomic, strong) NSMenuItem *noticeLine;
@property(nonatomic, strong) NSMenuItem *downloadItem;
@property(nonatomic, strong) NSMenuItem *showWindowItem;
@property(nonatomic, strong) NSMenuItem *backgroundItem;      /* "App mode" submenu */
@property(nonatomic, strong) NSMenuItem *presentationStandardItem;
@property(nonatomic, strong) NSMenuItem *presentationBackgroundItem;
@property(nonatomic, strong) NSMenuItem *presentationFacelessItem;
@property(nonatomic, strong) NSTextField *presentationLabel;
@property(nonatomic) int requestedPresentation;              /* -1: none */
@property(nonatomic, strong) NSMenuItem *showAtStartItem;
@property(nonatomic, strong) NSMenuItem *quitItem;
@property(nonatomic, strong) NSMenuItem *performanceItem;
@property(nonatomic, strong) NSMenuItem *signinItem;
@property(nonatomic, strong) NSMenuItem *signinStatusLine;
@property(nonatomic, strong) NSMenuItem *signinInstallItem;
@property(nonatomic, strong) NSMenuItem *signinUninstallItem;
@property(nonatomic, strong) NSMenuItem *signinHelpItem;
@property(nonatomic) int signinInstalled;
@property(nonatomic, strong) NSMenuItem *newestFrameItem;
@property(nonatomic, strong) NSMenuItem *wakeOnDataItem;
@property(nonatomic, strong) NSMenuItem *expertItem;
@property(nonatomic, strong) NSMenuItem *rendererHeader;
@property(nonatomic, strong) NSMenuItem *rendererTargetBridgeItem;
@property(nonatomic, strong) NSMenuItem *rendererSDLMetalItem;
@property(nonatomic, strong) NSMenuItem *rendererSDLOpenGLItem;
@property(nonatomic, strong) NSMenuItem *displaySyncItem;
@property(nonatomic, strong) NSMenuItem *statsItem;
@property(nonatomic, strong) NSPopUpButton *checkbox;        /* app mode */
@property(nonatomic, strong) NSButton *showAtStartCheckbox;
@property(nonatomic, strong) NSTextField *loginHint;
@property(nonatomic, copy) NSString *language;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) unsigned int actions;
@property(nonatomic) int policyVisible;
@end

static NSString *tb_ui_text(const char *key) {
    const char *text = tb_i18n_get(key);
    return text ? [NSString stringWithUTF8String:text] : @"";
}

static NSWindow *tb_ui_largest_window(void) {
    NSWindow *largest = nil;
    CGFloat largest_area = 0.0;
    for (NSWindow *window in NSApp.windows) {
        NSSize size = window.frame.size;
        CGFloat area = size.width * size.height;
        if (area > largest_area) {
            largest = window;
            largest_area = area;
        }
    }
    return largest;
}

@implementation TBBackgroundUI

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _policyVisible = -1;
    _requestedPresentation = -1;
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"display"
                              accessibilityDescription:@"TargetBridge Receiver"];
    if (icon) {
        icon.template = YES;
        _statusItem.button.image = icon;
    } else {
        _statusItem.button.title = @"TB";
    }

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    _statusLine = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _statusLine.enabled = NO;
    _noticeLine = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _noticeLine.enabled = NO;
    _noticeLine.hidden = YES;
    _downloadItem = [menu addItemWithTitle:@"" action:@selector(openDownload:) keyEquivalent:@""];
    _downloadItem.target = self;
    _downloadItem.hidden = YES;
    [menu addItem:NSMenuItem.separatorItem];
    _showWindowItem = [menu addItemWithTitle:@"" action:@selector(showWindow:) keyEquivalent:@""];
    _showWindowItem.target = self;
    NSMenu *presentation = [[NSMenu alloc] init];
    presentation.autoenablesItems = NO;
    _presentationStandardItem = [self addItemTo:presentation action:@selector(choosePresentationItem:)];
    _presentationStandardItem.tag = TB_APP_PRESENTATION_STANDARD;
    _presentationBackgroundItem = [self addItemTo:presentation action:@selector(choosePresentationItem:)];
    _presentationBackgroundItem.tag = TB_APP_PRESENTATION_BACKGROUND;
    _presentationFacelessItem = [self addItemTo:presentation action:@selector(choosePresentationItem:)];
    _presentationFacelessItem.tag = TB_APP_PRESENTATION_FACELESS;
    _backgroundItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _backgroundItem.submenu = presentation;
    _showAtStartItem = [menu addItemWithTitle:@"" action:@selector(toggleShowAtStart:) keyEquivalent:@""];
    _showAtStartItem.target = self;
    [menu addItem:NSMenuItem.separatorItem];

    NSMenu *performance = [[NSMenu alloc] init];
    performance.autoenablesItems = NO;
    _newestFrameItem = [self addItemTo:performance action:@selector(toggleNewestFrame:)];
    _wakeOnDataItem = [self addItemTo:performance action:@selector(toggleWakeOnData:)];
    [performance addItem:NSMenuItem.separatorItem];
    _statsItem = [self addItemTo:performance action:@selector(toggleStats:)];
    [performance addItem:NSMenuItem.separatorItem];

    /* For developers: SDL's own renderers and display sync. */
    NSMenu *expert = [[NSMenu alloc] init];
    expert.autoenablesItems = NO;
    _rendererHeader = [expert addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _rendererHeader.enabled = NO;
    _rendererTargetBridgeItem = [self addItemTo:expert action:@selector(chooseRenderer:)];
    _rendererTargetBridgeItem.tag = 0;
    _rendererSDLMetalItem = [self addItemTo:expert action:@selector(chooseRenderer:)];
    _rendererSDLMetalItem.tag = 1;
    _rendererSDLOpenGLItem = [self addItemTo:expert action:@selector(chooseRenderer:)];
    _rendererSDLOpenGLItem.tag = 2;
    [expert addItem:NSMenuItem.separatorItem];
    _displaySyncItem = [self addItemTo:expert action:@selector(toggleDisplaySync:)];
    _expertItem = [performance addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _expertItem.submenu = expert;
    _performanceItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _performanceItem.submenu = performance;

    /* Experimental: show a Mac's picture at the sign-in window. Nothing is
     * installed until the user chooses Install. */
    NSMenu *signin = [[NSMenu alloc] init];
    signin.autoenablesItems = NO;
    _signinStatusLine = [signin addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _signinStatusLine.enabled = NO;
    [signin addItem:NSMenuItem.separatorItem];
    _signinInstallItem = [self addItemTo:signin action:@selector(installSignin:)];
    _signinUninstallItem = [self addItemTo:signin action:@selector(uninstallSignin:)];
    [signin addItem:NSMenuItem.separatorItem];
    _signinHelpItem = [self addItemTo:signin action:@selector(signinHelp:)];
    _signinItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _signinItem.submenu = signin;
    [menu addItem:NSMenuItem.separatorItem];
    _quitItem = [menu addItemWithTitle:@"" action:@selector(quit:) keyEquivalent:@""];
    _quitItem.target = self;
    _statusItem.menu = menu;
    return self;
}

- (void)openDownload:(id)sender {
    NSURL *url = [NSURL URLWithString:@TB_RECEIVER_DOWNLOAD_URL];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)installSignin:(id)sender {
    self.actions |= TB_BACKGROUND_UI_SIGNIN_INSTALL;
}

- (void)uninstallSignin:(id)sender {
    self.actions |= TB_BACKGROUND_UI_SIGNIN_UNINSTALL;
}

- (void)signinHelp:(id)sender {
    self.actions |= TB_BACKGROUND_UI_SIGNIN_HELP;
}

- (void)refreshSigninItems {
    self.signinStatusLine.title = tb_ui_text(self.signinInstalled ? "receiver.signin.installed"
                                                                   : "receiver.signin.not_installed");
    self.signinInstallItem.enabled = !self.signinInstalled;
    self.signinUninstallItem.enabled = self.signinInstalled;
}

- (void)showWindow:(id)sender {
    self.actions |= TB_BACKGROUND_UI_SHOW_WINDOW;
}

- (void)choosePresentationItem:(NSMenuItem *)sender {
    self.requestedPresentation = (int)sender.tag;
    self.actions |= TB_BACKGROUND_UI_TOGGLE;
}

- (void)choosePresentationPopup:(NSPopUpButton *)sender {
    self.requestedPresentation = (int)sender.selectedTag;
    self.actions |= TB_BACKGROUND_UI_TOGGLE;
}

/* Opening the app again (Finder, Launchpad, `open`) while it runs: show the
 * window. This is the way back to the settings in faceless mode. */
- (void)handleReopen:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply {
    self.actions |= TB_BACKGROUND_UI_SHOW_WINDOW;
}

- (NSMenuItem *)addItemTo:(NSMenu *)menu action:(SEL)action {
    NSMenuItem *item = [menu addItemWithTitle:@"" action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)toggleNewestFrame:(id)sender {
    self.actions |= TB_BACKGROUND_UI_TOGGLE_NEWEST_FRAME;
}

- (void)toggleWakeOnData:(id)sender {
    self.actions |= TB_BACKGROUND_UI_TOGGLE_WAKE_ON_DATA;
}

- (void)chooseRenderer:(NSMenuItem *)sender {
    switch (sender.tag) {
    case 1: self.actions |= TB_BACKGROUND_UI_RENDERER_SDL_METAL; break;
    case 2: self.actions |= TB_BACKGROUND_UI_RENDERER_SDL_OPENGL; break;
    default: self.actions |= TB_BACKGROUND_UI_RENDERER_TARGETBRIDGE; break;
    }
}

- (void)toggleDisplaySync:(id)sender {
    self.actions |= TB_BACKGROUND_UI_TOGGLE_DISPLAY_SYNC;
}

- (void)toggleStats:(id)sender {
    self.actions |= TB_BACKGROUND_UI_TOGGLE_STATS;
}

- (void)toggleShowAtStart:(id)sender {
    self.actions |= TB_BACKGROUND_UI_TOGGLE_SHOW_AT_START;
}

- (void)quit:(id)sender {
    self.actions |= TB_BACKGROUND_UI_QUIT;
}

- (void)installCheckboxIfNeeded {
    if (self.checkbox) return;
    NSWindow *window = tb_ui_largest_window();
    NSView *content = window.contentView;
    if (!content) return;

    self.showAtStartCheckbox = [self addCheckboxTo:content
                                               key:"receiver.background.show_at_start"
                                            action:@selector(toggleShowAtStart:)];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    popup.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    popup.target = self;
    popup.action = @selector(choosePresentationPopup:);
    for (int mode = TB_APP_PRESENTATION_STANDARD; mode <= TB_APP_PRESENTATION_FACELESS; ++mode) {
        [popup addItemWithTitle:[NSString stringWithFormat:@"%d", mode]];
        popup.lastItem.tag = mode;
    }
    [content addSubview:popup positioned:NSWindowAbove relativeTo:nil];
    self.checkbox = popup;
    NSTextField *label = [NSTextField labelWithString:tb_ui_text("receiver.app_mode.label")];
    label.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    label.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:label positioned:NSWindowAbove relativeTo:nil];
    self.presentationLabel = label;
    [self layoutCheckboxes];

    NSTextField *hint = [NSTextField labelWithString:tb_ui_text("receiver.background.login_hint")];
    hint.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.alignment = NSTextAlignmentRight;
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 2;
    CGFloat hintWidth = MIN(640.0, NSWidth(content.bounds) - 240.0);
    hint.frame = NSMakeRect(NSWidth(content.bounds) - hintWidth - 24.0, 8.0, hintWidth, 30.0);
    hint.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:hint positioned:NSWindowAbove relativeTo:nil];
    self.loginHint = hint;
    self.language = nil;
}

- (NSButton *)addCheckboxTo:(NSView *)content key:(const char *)key action:(SEL)action {
    NSButton *checkbox = [NSButton checkboxWithTitle:tb_ui_text(key) target:self action:action];
    checkbox.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    checkbox.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:checkbox positioned:NSWindowAbove relativeTo:nil];
    return checkbox;
}

/* One row in the bottom bar, right-aligned, to the right of the version text. */
- (void)layoutCheckboxes {
    NSView *content = self.checkbox.superview;
    if (!content) return;

    CGFloat right = NSWidth(content.bounds) - 24.0;
    for (NSControl *checkbox in @[ self.showAtStartCheckbox, self.checkbox, self.presentationLabel ]) {
        [checkbox sizeToFit];
        NSSize size = checkbox.frame.size;
        checkbox.frame = NSMakeRect(right - size.width, 42.0, size.width, size.height);
        right -= size.width + 18.0;
    }
}

- (void)refreshTextsIfNeeded {
    const char *current = tb_i18n_current_language();
    NSString *language = current ? [NSString stringWithUTF8String:current] : @"";
    if ([language isEqualToString:self.language]) return;
    self.language = language;

    self.showWindowItem.title = tb_ui_text("receiver.background.show_window");
    self.backgroundItem.title = tb_ui_text("receiver.app_mode.label");
    self.presentationStandardItem.title = tb_ui_text("receiver.app_mode.standard");
    self.presentationBackgroundItem.title = tb_ui_text("receiver.app_mode.background");
    self.presentationFacelessItem.title = tb_ui_text("receiver.app_mode.faceless");
    self.showAtStartItem.title = tb_ui_text("receiver.background.show_main_window_at_start");
    self.quitItem.title = tb_ui_text("receiver.background.quit");
    self.downloadItem.title = tb_ui_text("receiver.version.download");
    self.performanceItem.title = tb_ui_text("receiver.performance.menu");
    self.signinItem.title = tb_ui_text("receiver.signin.menu");
    self.signinInstallItem.title = tb_ui_text("receiver.signin.install");
    self.signinUninstallItem.title = tb_ui_text("receiver.signin.uninstall");
    self.signinHelpItem.title = tb_ui_text("receiver.signin.how_to_use");
    [self refreshSigninItems];
    self.newestFrameItem.title = tb_ui_text("receiver.performance.newest_frame");
    self.wakeOnDataItem.title = tb_ui_text("receiver.performance.wake_on_data");
    self.expertItem.title = tb_ui_text("receiver.expert.menu");
    self.rendererHeader.title = tb_ui_text("receiver.expert.renderer");
    self.rendererTargetBridgeItem.title = tb_ui_text("receiver.expert.renderer_targetbridge");
    self.rendererSDLMetalItem.title = tb_ui_text("receiver.expert.renderer_sdl_metal");
    self.rendererSDLOpenGLItem.title = tb_ui_text("receiver.expert.renderer_sdl_opengl");
    self.displaySyncItem.title = tb_ui_text("receiver.expert.display_sync");
    self.statsItem.title = tb_ui_text("receiver.performance.show_stats");
    self.loginHint.stringValue = tb_ui_text("receiver.background.login_hint");
    [self.checkbox.menu itemWithTag:TB_APP_PRESENTATION_STANDARD].title = tb_ui_text("receiver.app_mode.standard");
    [self.checkbox.menu itemWithTag:TB_APP_PRESENTATION_BACKGROUND].title = tb_ui_text("receiver.app_mode.background");
    [self.checkbox.menu itemWithTag:TB_APP_PRESENTATION_FACELESS].title = tb_ui_text("receiver.app_mode.faceless");
    self.presentationLabel.stringValue = tb_ui_text("receiver.app_mode.label");
    self.showAtStartCheckbox.title = tb_ui_text("receiver.background.show_at_start");
    [self layoutCheckboxes];
}

- (void)updateBackground:(int)presentation
             showAtStart:(int)showAtStart
                 visible:(int)visible
                 session:(int)session
                  status:(const char *)status {
    /* A Dock icon in standard mode only; clicking it shows the window. */
    const int regular = presentation == TB_APP_PRESENTATION_STANDARD;
    const int policy = regular * 2 + visible;
    if (policy != self.policyVisible) {
        self.policyVisible = policy;
        [NSApp setActivationPolicy:regular ? NSApplicationActivationPolicyRegular
                                           : NSApplicationActivationPolicyAccessory];
        if (visible) [NSApp activateIgnoringOtherApps:YES];
    }
    /* Faceless: no menu bar icon either. */
    self.statusItem.visible = presentation != TB_APP_PRESENTATION_FACELESS;

    [self installCheckboxIfNeeded];
    [self refreshTextsIfNeeded];

    self.presentationStandardItem.state = presentation == TB_APP_PRESENTATION_STANDARD ? NSControlStateValueOn : NSControlStateValueOff;
    self.presentationBackgroundItem.state = presentation == TB_APP_PRESENTATION_BACKGROUND ? NSControlStateValueOn : NSControlStateValueOff;
    self.presentationFacelessItem.state = presentation == TB_APP_PRESENTATION_FACELESS ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.checkbox.selectedTag != presentation) [self.checkbox selectItemWithTag:presentation];
    self.checkbox.hidden = session != 0;
    self.presentationLabel.hidden = session != 0;

    NSControlStateValue showAtStartState = showAtStart ? NSControlStateValueOn : NSControlStateValueOff;
    self.showAtStartItem.state = showAtStartState;
    /* Applies in every app mode. */
    self.showAtStartItem.enabled = YES;
    self.showAtStartCheckbox.state = showAtStartState;
    self.showAtStartCheckbox.enabled = YES;
    self.showAtStartCheckbox.hidden = session != 0;
    self.loginHint.hidden = session != 0;
    self.showWindowItem.enabled = !visible;

    NSString *text = status ? [NSString stringWithUTF8String:status] : @"";
    if (text && ![text isEqualToString:self.status]) {
        self.status = text;
        self.statusLine.title = text;
    }
}

@end

static TBBackgroundUI *g_background_ui = nil;

int tb_app_presentation_load(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:kAppPresentationKey];
    if (stored) {
        const int value = (int)[stored integerValue];
        if (value >= TB_APP_PRESENTATION_STANDARD && value <= TB_APP_PRESENTATION_FACELESS) return value;
    }
    /* Before 4.0: "Run in background" on/off. */
    return [defaults boolForKey:kBackgroundModeKey] ? TB_APP_PRESENTATION_BACKGROUND
                                                    : TB_APP_PRESENTATION_STANDARD;
}

void tb_app_presentation_save(int presentation) {
    [NSUserDefaults.standardUserDefaults setInteger:presentation forKey:kAppPresentationKey];
    [NSUserDefaults.standardUserDefaults setBool:presentation != TB_APP_PRESENTATION_STANDARD
                                          forKey:kBackgroundModeKey];
}

int tb_background_ui_take_presentation_request(void) {
    if (!g_background_ui) return -1;
    const int requested = g_background_ui.requestedPresentation;
    g_background_ui.requestedPresentation = -1;
    return requested;
}

int tb_show_window_at_start_load(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kShowWindowAtStartKey];
    /* Never set: like before, standard mode shows the window, background
     * mode doesn't. */
    if (!stored) return tb_app_presentation_load() == TB_APP_PRESENTATION_STANDARD;
    return [stored boolValue] ? 1 : 0;
}

void tb_show_window_at_start_save(int enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled != 0 forKey:kShowWindowAtStartKey];
}

int tb_pref_get(const char *key, int default_value) {
    NSString *name = [NSString stringWithUTF8String:key];
    id value = [NSUserDefaults.standardUserDefaults objectForKey:name];
    return value ? ([value boolValue] ? 1 : 0) : default_value;
}

void tb_pref_set(const char *key, int value) {
    [NSUserDefaults.standardUserDefaults setBool:value != 0 forKey:[NSString stringWithUTF8String:key]];
}

int tb_pref_get_int(const char *key, int default_value) {
    NSString *name = [NSString stringWithUTF8String:key];
    id value = [NSUserDefaults.standardUserDefaults objectForKey:name];
    return value ? (int)[value integerValue] : default_value;
}

void tb_pref_set_int(const char *key, int value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:[NSString stringWithUTF8String:key]];
}

static NSControlStateValue tb_ui_state(int on) {
    return on ? NSControlStateValueOn : NSControlStateValueOff;
}

void tb_background_ui_set_performance(int newest_frame, int wake_on_data, int renderer,
                                      int display_sync, int stats) {
    g_background_ui.newestFrameItem.state = tb_ui_state(newest_frame);
    g_background_ui.wakeOnDataItem.state = tb_ui_state(wake_on_data);
    g_background_ui.rendererTargetBridgeItem.state = tb_ui_state(renderer == 0);
    g_background_ui.rendererSDLMetalItem.state = tb_ui_state(renderer == 1);
    g_background_ui.rendererSDLOpenGLItem.state = tb_ui_state(renderer == 2);
    g_background_ui.displaySyncItem.state = tb_ui_state(display_sync);
    g_background_ui.displaySyncItem.enabled = renderer == 0;
    g_background_ui.statsItem.state = tb_ui_state(stats);
}

void tb_background_ui_set_update_notice(const char *text) {
    if (!g_background_ui) return;
    const BOOL show = text && *text;
    g_background_ui.noticeLine.title = show ? [NSString stringWithUTF8String:text] : @"";
    g_background_ui.noticeLine.hidden = !show;
    g_background_ui.downloadItem.title = tb_ui_text("receiver.version.download");
    g_background_ui.downloadItem.hidden = !show;
}

void tb_background_ui_install(void) {
    if (g_background_ui) return;
    g_background_ui = [[TBBackgroundUI alloc] init];
    [NSAppleEventManager.sharedAppleEventManager
        setEventHandler:g_background_ui
            andSelector:@selector(handleReopen:withReplyEvent:)
          forEventClass:kCoreEventClass
             andEventID:kAEReopenApplication];
}

void tb_background_ui_update(int presentation,
                             int show_at_start,
                             int window_visible,
                             int session_active,
                             const char *status) {
    [g_background_ui updateBackground:presentation
                          showAtStart:show_at_start
                              visible:window_visible
                              session:session_active
                               status:status];
}

unsigned int tb_background_ui_take_actions(void) {
    unsigned int actions = g_background_ui.actions;
    g_background_ui.actions = 0;
    return actions;
}

void tb_background_ui_set_signin_installed(int installed) {
    if (!g_background_ui) return;
    if (g_background_ui.signinInstalled == (installed ? 1 : 0) && g_background_ui.signinStatusLine.title.length > 0) return;
    g_background_ui.signinInstalled = installed ? 1 : 0;
    [g_background_ui refreshSigninItems];
}

void tb_background_ui_show_message(const char *title, const char *text) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithUTF8String:title ? title : ""] ?: @"";
    alert.informativeText = [NSString stringWithUTF8String:text ? text : ""] ?: @"";
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}
