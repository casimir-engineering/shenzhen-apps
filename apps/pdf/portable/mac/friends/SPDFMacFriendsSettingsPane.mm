#import "SPDFMacFriendsSettingsPane.h"
#import "SPDFMacCollectionStyle.h"

NSString* const SPDFMacFriendsEnableTitle = @"Enable Shenzhen Friends";
// What the server sees and what it never sees in two sentences: joined by a comma, "when ShenzhenPDF is open, never
// your name" read as one clause, and the reader could not tell which list was which. Shenzhen Files says the same.
NSString* const SPDFMacFriendsDisclosureText = @"ShenzhenPDF connects to the Friends server whenever it is open and "
    "Friends is on. The server sees your network address, your Friends ID and when ShenzhenPDF is open. It never sees "
    "your name, messages or files.";
// Friends is a beta in every app that has it; its menu and its Settings say so where people meet it.
NSString* const SPDFMacFriendsSettingsHeading = @"Shenzhen Friends (Beta)";
// M1 reaches friends only nearby (brief § Milestones), so the subtitle promises nothing about the Internet. It names
// every app, as the helper's queued note does: a friend with only Shenzhen Files or Shenzhen 3D open still receives.
NSString* const SPDFMacFriendsSettingsSubtitle = @"Send documents and messages to people you add, when they are nearby "
    "with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open.";
NSString* const SPDFMacFriendsSettingsSectionKey = @"friends";
NSString* const SPDFMacFriendsSettingsPaneRefreshNotification = @"SPDFMacFriendsSettingsPaneRefresh";

static __weak id<SPDFMacFriendsSettingsPaneSource> gSource;

void SPDFMacFriendsSetSettingsPaneSource(id<SPDFMacFriendsSettingsPaneSource> source) { gSource = source; }
id<SPDFMacFriendsSettingsPaneSource> SPDFMacFriendsSettingsPaneSourceForProcess(void) { return gSource; }

@implementation SPDFMacFriendsSettingsPane {
    id<SPDFMacFriendsSettingsPaneSource> _source;
    NSView* _section;
    BOOL _sectionShown;
    id _refreshObserver;
}

- (instancetype)initWithSource:(id<SPDFMacFriendsSettingsPaneSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 600, 120)])) return nil;
    _source = source;
    // The assistant's app_controls leaves out anything under a "szfriends." identifier (SPDFMacAIAppControls.h), so
    // text in a document cannot turn Friends off or reach the views' section placed inside this pane.
    self.identifier = @"szfriends.settings-pane";
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _enableCheckbox = [NSButton checkboxWithTitle:SPDFMacFriendsEnableTitle target:self action:@selector(toggle:)];
    _enableCheckbox.identifier = @"friendsEnabled";
    _enableCheckbox.font = [NSFont systemFontOfSize:13];
    _enableCheckbox.accessibilityLabel = SPDFMacFriendsEnableTitle;
    _disclosure = SPDFCollectionText(SPDFMacFriendsDisclosureText, 12, NSFontWeightRegular, YES);
    _disclosure.identifier = @"friendsDisclosure";
    _disclosure.lineBreakMode = NSLineBreakByWordWrapping;
    _disclosure.maximumNumberOfLines = 0;
    _disclosure.cell.wraps = YES;
    _disclosure.cell.scrollable = NO;
    [_disclosure setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    _sectionContainer = [NSView new];
    _sectionContainer.identifier = @"friendsSection";
    NSStackView* stack = [NSStackView stackViewWithViews:@[_enableCheckbox, _disclosure, _sectionContainer]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [stack setCustomSpacing:16 afterView:_disclosure];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    // Empty while Friends is off: the weakest possible zero height collapses it without fighting the section's own.
    NSLayoutConstraint* collapsed = [_sectionContainer.heightAnchor constraintEqualToConstant:0];
    collapsed.priority = 1;
    [NSLayoutConstraint activateConstraints:@[
        collapsed,
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_disclosure.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_sectionContainer.widthAnchor constraintEqualToAnchor:stack.widthAnchor]]];
    __weak SPDFMacFriendsSettingsPane* weakSelf = self;
    _refreshObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:SPDFMacFriendsSettingsPaneRefreshNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
            (void)note;
            SPDFMacFriendsSettingsPane* pane = weakSelf;
            // Attaching or detaching replaces the views' objects: show the section that belongs to the new state.
            [pane hideSection];
            [pane refresh];
        }];
    [self refresh];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:_refreshObserver]; }

- (void)toggle:(NSButton*)sender {
    [_source friendsSettingsSetEnabled:sender.state == NSControlStateValueOn];
    [self refresh];
}

- (void)hideSection {
    if (_sectionShown) [_source friendsSettingsSectionDidDisappear];
    _sectionShown = NO;
    [_section removeFromSuperview];
    _section = nil;
}

- (void)refresh {
    BOOL enabled = _source ? _source.friendsEnabled : YES;
    _enableCheckbox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _enableCheckbox.enabled = _source != nil;
    if (!enabled || !self.window) { [self hideSection]; return; }
    if (_sectionShown) return;
    NSView* section = [_source friendsSettingsSectionViewWillAppear];
    _sectionShown = YES;
    if (!section) return;
    _section = section;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    [_sectionContainer addSubview:section];
    [NSLayoutConstraint activateConstraints:@[
        [section.leadingAnchor constraintEqualToAnchor:_sectionContainer.leadingAnchor],
        [section.trailingAnchor constraintEqualToAnchor:_sectionContainer.trailingAnchor],
        [section.topAnchor constraintEqualToAnchor:_sectionContainer.topAnchor],
        [section.bottomAnchor constraintEqualToAnchor:_sectionContainer.bottomAnchor]]];
}

// The views hold their `settings` subscription only while the section is on screen (SZFriendsSettingsSection.h):
// Settings rebuilds its pages by removing them, so leaving the window is leaving the screen.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self refresh];
}

@end
