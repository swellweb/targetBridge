#import "tb_background_ui.h"

#import <AppKit/AppKit.h>
#include <string.h>

#include "tb_i18n.h"

static NSString *const kBackgroundModeKey = @"backgroundMode";
static NSString *const kShowWindowAtStartKey = @"showWindowAtStart";

@interface TBBackgroundUI : NSObject
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusLine;
@property(nonatomic, strong) NSMenuItem *showWindowItem;
@property(nonatomic, strong) NSMenuItem *backgroundItem;
@property(nonatomic, strong) NSMenuItem *showAtStartItem;
@property(nonatomic, strong) NSMenuItem *quitItem;
@property(nonatomic, strong) NSButton *checkbox;
@property(nonatomic, strong) NSButton *showAtStartCheckbox;
@property(nonatomic, strong) NSTextField *loginHint;
@property(nonatomic, strong) NSMenuItem *loginHintItem;
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
    [menu addItem:NSMenuItem.separatorItem];
    _showWindowItem = [menu addItemWithTitle:@"" action:@selector(showWindow:) keyEquivalent:@""];
    _showWindowItem.target = self;
    _backgroundItem = [menu addItemWithTitle:@"" action:@selector(toggleBackground:) keyEquivalent:@""];
    _backgroundItem.target = self;
    _showAtStartItem = [menu addItemWithTitle:@"" action:@selector(toggleShowAtStart:) keyEquivalent:@""];
    _showAtStartItem.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    _loginHintItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _loginHintItem.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    _quitItem = [menu addItemWithTitle:@"" action:@selector(quit:) keyEquivalent:@""];
    _quitItem.target = self;
    _statusItem.menu = menu;
    return self;
}

- (void)showWindow:(id)sender {
    self.actions |= TB_BACKGROUND_UI_SHOW_WINDOW;
}

- (void)toggleBackground:(id)sender {
    self.actions |= TB_BACKGROUND_UI_TOGGLE;
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
    self.checkbox = [self addCheckboxTo:content
                                    key:"receiver.background.run"
                                 action:@selector(toggleBackground:)];
    [self layoutCheckboxes];

    NSTextField *hint = [NSTextField labelWithString:tb_ui_text("receiver.background.login_hint")];
    hint.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.alignment = NSTextAlignmentRight;
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 2;
    CGFloat hintWidth = MIN(420.0, NSWidth(content.bounds) - 48.0);
    hint.frame = NSMakeRect(NSWidth(content.bounds) - hintWidth - 24.0, 72.0, hintWidth, 32.0);
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

/* One row in the footer band, right-aligned, to the right of the version text. */
- (void)layoutCheckboxes {
    NSView *content = self.checkbox.superview;
    if (!content) return;

    CGFloat right = NSWidth(content.bounds) - 36.0;
    for (NSButton *checkbox in @[ self.showAtStartCheckbox, self.checkbox ]) {
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
    self.backgroundItem.title = tb_ui_text("receiver.background.run");
    self.showAtStartItem.title = tb_ui_text("receiver.background.show_at_start");
    self.quitItem.title = tb_ui_text("receiver.background.quit");
    self.loginHintItem.title = tb_ui_text("receiver.background.login_hint");
    self.loginHint.stringValue = tb_ui_text("receiver.background.login_hint");
    self.checkbox.title = tb_ui_text("receiver.background.run");
    self.showAtStartCheckbox.title = tb_ui_text("receiver.background.show_at_start");
    [self layoutCheckboxes];
}

- (void)updateBackground:(int)background
             showAtStart:(int)showAtStart
                 visible:(int)visible
                 session:(int)session
                  status:(const char *)status {
    if (visible != self.policyVisible) {
        self.policyVisible = visible;
        [NSApp setActivationPolicy:visible ? NSApplicationActivationPolicyRegular
                                           : NSApplicationActivationPolicyAccessory];
        if (visible) [NSApp activateIgnoringOtherApps:YES];
    }

    [self installCheckboxIfNeeded];
    [self refreshTextsIfNeeded];

    NSControlStateValue state = background ? NSControlStateValueOn : NSControlStateValueOff;
    self.backgroundItem.state = state;
    self.checkbox.state = state;
    self.checkbox.hidden = session != 0;

    /* Without background mode the window always shows at start. */
    NSControlStateValue showAtStartState = showAtStart ? NSControlStateValueOn : NSControlStateValueOff;
    self.showAtStartItem.state = showAtStartState;
    self.showAtStartItem.enabled = background != 0;
    self.showAtStartCheckbox.state = showAtStartState;
    self.showAtStartCheckbox.enabled = background != 0;
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

int tb_background_mode_load(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kBackgroundModeKey] ? 1 : 0;
}

void tb_background_mode_save(int enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled != 0 forKey:kBackgroundModeKey];
}

int tb_show_window_at_start_load(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kShowWindowAtStartKey] ? 1 : 0;
}

void tb_show_window_at_start_save(int enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled != 0 forKey:kShowWindowAtStartKey];
}

void tb_background_ui_install(void) {
    if (!g_background_ui) g_background_ui = [[TBBackgroundUI alloc] init];
}

void tb_background_ui_update(int background_mode,
                             int show_at_start,
                             int window_visible,
                             int session_active,
                             const char *status) {
    [g_background_ui updateBackground:background_mode
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
