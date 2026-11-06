#import "tb_background_ui.h"

#import <AppKit/AppKit.h>
#include <string.h>

#include "tb_i18n.h"

static NSString *const kBackgroundModeKey = @"backgroundMode";

@interface TBBackgroundUI : NSObject
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusLine;
@property(nonatomic, strong) NSMenuItem *showWindowItem;
@property(nonatomic, strong) NSMenuItem *backgroundItem;
@property(nonatomic, strong) NSMenuItem *quitItem;
@property(nonatomic, strong) NSButton *checkbox;
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

- (void)quit:(id)sender {
    self.actions |= TB_BACKGROUND_UI_QUIT;
}

- (void)installCheckboxIfNeeded {
    if (self.checkbox) return;
    NSWindow *window = tb_ui_largest_window();
    NSView *content = window.contentView;
    if (!content) return;

    NSButton *checkbox = [NSButton checkboxWithTitle:tb_ui_text("receiver.background.run")
                                              target:self
                                              action:@selector(toggleBackground:)];
    checkbox.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [checkbox sizeToFit];
    NSSize size = checkbox.frame.size;
    checkbox.frame = NSMakeRect(NSWidth(content.bounds) - size.width - 24.0, 18.0, size.width, size.height);
    checkbox.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:checkbox positioned:NSWindowAbove relativeTo:nil];
    self.checkbox = checkbox;
    self.language = nil;
}

- (void)refreshTextsIfNeeded {
    const char *current = tb_i18n_current_language();
    NSString *language = current ? [NSString stringWithUTF8String:current] : @"";
    if ([language isEqualToString:self.language]) return;
    self.language = language;

    self.showWindowItem.title = tb_ui_text("receiver.background.show_window");
    self.backgroundItem.title = tb_ui_text("receiver.background.run");
    self.quitItem.title = tb_ui_text("receiver.background.quit");
    if (self.checkbox) {
        self.checkbox.title = tb_ui_text("receiver.background.run");
        NSRect frame = self.checkbox.frame;
        CGFloat right = NSMaxX(frame);
        [self.checkbox sizeToFit];
        frame.size = self.checkbox.frame.size;
        frame.origin.x = right - frame.size.width;
        self.checkbox.frame = frame;
    }
}

- (void)updateBackground:(int)background visible:(int)visible session:(int)session status:(const char *)status {
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

void tb_background_ui_install(void) {
    if (!g_background_ui) g_background_ui = [[TBBackgroundUI alloc] init];
}

void tb_background_ui_update(int background_mode,
                             int window_visible,
                             int session_active,
                             const char *status) {
    [g_background_ui updateBackground:background_mode
                              visible:window_visible
                              session:session_active
                               status:status];
}

unsigned int tb_background_ui_take_actions(void) {
    unsigned int actions = g_background_ui.actions;
    g_background_ui.actions = 0;
    return actions;
}
