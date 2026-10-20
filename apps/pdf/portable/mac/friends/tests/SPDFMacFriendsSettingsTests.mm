// settings.yaml's `friends` entry surviving the coordinator's whole-file saves, the Settings pane (checkbox,
// disclosure, the views' section only while on and on screen), Cmd+K rows and the assistant's citation links.

#import <AppKit/AppKit.h>
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsChatScope.h"
#import "SPDFMacFriendsPalette.h"
#import "SPDFMacFriendsSettings.h"
#import "SPDFMacFriendsSettingsPane.h"
#import "SPDFMacFriendsSettingsPage.h"
#import "SPDFMacFriendsTestSupport.h"

static void TestSettingsSurviveSaves(void) {
    SPDFMacFriendsSettingsState* state = [SPDFMacFriendsSettingsState new];
    NSDictionary* coordinatorSave = @{@"version" : @1, @"fitMode" : @2, @"markdownTheme" : @"dark"};
    Expect([[state settingsByAddingFriends:coordinatorSave] isEqual:coordinatorSave],
           @"an unloaded state must not invent a friends entry");
    // A newer build's key inside `friends` is kept when this build saves.
    [state loadFromSettings:@{@"friends" : @{@"enabled" : @NO, @"futureKey" : @"kept"}}];
    NSDictionary* saved = [state settingsByAddingFriends:coordinatorSave];
    Expect([saved[@"fitMode"] isEqual:@2] && [saved[@"markdownTheme"] isEqual:@"dark"], @"coordinator keys were lost");
    Expect([saved[@"friends"][@"enabled"] isEqual:@NO] && [saved[@"friends"][@"futureKey"] isEqual:@"kept"],
           @"the friends entry did not survive a save: %@", saved[@"friends"]);
    Expect(!state.enabled && state.introducedRevision == 0, @"loaded values");
    [state setIntroducedRevision:SPDFMacFriendsSettingsIntroductionRevision];
    [state setEnabled:YES];
    saved = [state settingsByAddingFriends:coordinatorSave];
    Expect([saved[@"friends"][@"enabled"] isEqual:@YES] &&
           [saved[@"friends"][@"settingsIntroduced"] integerValue] == SPDFMacFriendsSettingsIntroductionRevision,
           @"changes must reach the next save: %@", saved[@"friends"]);
    Expect(SPDFMacFriendsIntroducedRevisionInSettings(saved) == 1 && SPDFMacFriendsEnabledInSettings(saved),
           @"a saved entry must read back as written");
    // The shared state is what the coordinator's save line uses.
    [SPDFMacFriendsSettingsState.sharedState loadFromSettings:@{@"friends" : @{@"enabled" : @NO}}];
    Expect([SPDFMacFriendsSettingsForSaving(@{@"a" : @1})[@"friends"][@"enabled"] isEqual:@NO], @"save hook");
}

@interface FakePaneSource : NSObject <SPDFMacFriendsSettingsPaneSource>
@property(nonatomic) BOOL friendsEnabled;
@property NSInteger appears, disappears, sets;
@property NSView* section;
@end
@implementation FakePaneSource
- (void)friendsSettingsSetEnabled:(BOOL)enabled { self.friendsEnabled = enabled; self.sets++; }
- (NSView*)friendsSettingsSectionViewWillAppear { self.appears++; return self.section; }
- (void)friendsSettingsSectionDidDisappear { self.disappears++; }
@end

static void TestSettingsPane(void) {
    // The brief's M1 text, with what the server sees and what it never sees as two sentences, the wording Shenzhen
    // Files uses too: joined by a comma, the two lists ran together.
    Expect([SPDFMacFriendsDisclosureText isEqual:@"ShenzhenPDF connects to the Friends server whenever it is open and "
            "Friends is on. The server sees your network address, your Friends ID and when ShenzhenPDF is open. It "
            "never sees your name, messages or files."], @"the disclosure must say what the server sees, then what it "
           "never sees, in two sentences: %@", SPDFMacFriendsDisclosureText);
    // The subtitle names the apps the helper's own queued note names (fixtures/frames/welcome.json; make runs in
    // portable/), so Settings never tells someone a friend must have ShenzhenPDF open when Shenzhen Files will do.
    NSData* welcome = [NSData dataWithContentsOfFile:@"friends/fixtures/frames/welcome.json"];
    NSDictionary* frame = welcome ? [NSJSONSerialization JSONObjectWithData:welcome options:0 error:NULL] : nil;
    NSString* note = frame[@"strings"][@"queued_note"];
    NSRange nearby = note ? [note rangeOfString:@"nearby with "] : NSMakeRange(NSNotFound, 0);
    NSString* apps = nearby.location == NSNotFound ? nil : [note substringFromIndex:nearby.location];
    Expect(apps.length > 0 && [SPDFMacFriendsSettingsSubtitle hasSuffix:apps],
           @"the subtitle must end as the helper's queued note does (\"%@\"): %@", apps,
           SPDFMacFriendsSettingsSubtitle);
    FakePaneSource* source = [FakePaneSource new];
    source.friendsEnabled = YES;
    source.section = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 80)];
    SPDFMacFriendsSettingsPane* pane = [[SPDFMacFriendsSettingsPane alloc] initWithSource:source];
    Expect(pane.enableCheckbox.state == NSControlStateValueOn &&
           [pane.enableCheckbox.title isEqual:@"Enable Shenzhen Friends"], @"checkbox");
    Expect(source.appears == 0, @"the views' section subscribed before it was on screen");
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    [window.contentView addSubview:pane];
    Expect(source.appears == 1 && source.section.superview == pane.sectionContainer, @"the section did not appear");
    [pane refresh];
    Expect(source.appears == 1, @"a refresh subscribed twice");
    [pane.enableCheckbox performClick:nil];
    Expect(source.sets == 1 && !source.friendsEnabled && source.disappears == 1 && !source.section.superview,
           @"turning Friends off must hide its section and release the subscription");
    [pane.enableCheckbox performClick:nil];
    Expect(source.friendsEnabled && source.appears == 2, @"turning it on again must bring the section back");
    [pane removeFromSuperview];
    Expect(source.disappears == 2, @"leaving the screen must release the section's subscription");

    SPDFMacFriendsSettingsPane* orphan = [[SPDFMacFriendsSettingsPane alloc] initWithSource:nil];
    Expect(!orphan.enableCheckbox.enabled, @"without a source the checkbox cannot pretend to work");
}

static NSView* FindView(NSView* root, BOOL (^match)(NSView*)) {
    if (match(root)) return root;
    for (NSView* child in root.subviews) {
        NSView* found = FindView(child, match);
        if (found) return found;
    }
    return nil;
}

// The page in the real Settings window: heading, the reader's checkbox and disclosure, from the process's source.
static void TestSettingsPage(void) {
    FakePaneSource* source = [FakePaneSource new];
    source.friendsEnabled = NO;
    SPDFMacFriendsSetSettingsPaneSource(source);
    SPDFMacUnifiedSettingsController* controller =
        [[SPDFMacUnifiedSettingsController alloc] initWithState:@{@"setupWizard" : @NO}];
    [controller buildFriends];
    NSView* root = controller.window.contentView;
    NSView* heading = FindView(root, ^BOOL(NSView* view) {
        return [view isKindOfClass:NSTextField.class] && [((NSTextField*)view).stringValue isEqual:SPDFMacFriendsSettingsHeading];
    });
    SPDFMacFriendsSettingsPane* pane = (SPDFMacFriendsSettingsPane*)FindView(root, ^BOOL(NSView* view) {
        return [view isKindOfClass:SPDFMacFriendsSettingsPane.class];
    });
    Expect(heading && pane && pane.enableCheckbox.state == NSControlStateValueOff && pane.enableCheckbox.enabled,
           @"the Settings page must show the heading and the pane wired to this process's Friends");
    [pane.enableCheckbox performClick:nil];
    Expect(source.sets == 1 && source.friendsEnabled, @"the page's checkbox must reach the reader");
    SPDFMacFriendsSetSettingsPaneSource(nil);
    [controller close];
}

static SZFriendsSearchResult* Result(NSString* conversation, NSString* message, NSArray* excerpt) {
    SZFriendsSearchResult* result = [SZFriendsSearchResult new];
    result.conversationID = conversation; result.messageID = message; result.conversationTitle = @"Mei";
    result.timeLabel = @"Yesterday"; result.senderLabel = @"Mei"; result.excerpt = excerpt;
    return result;
}

static void TestPaletteRows(void) {
    NSArray* excerpt = @[@{@"text" : @"…the delivery\ndate "}, @{@"text" : @"moved", @"match" : @YES},
                         @{@"text" : @" to the 20th"}];
    NSMutableArray* results = [NSMutableArray arrayWithObject:Result(@"c_mei", @"m_1", excerpt)];
    for (int i = 0; i < 8; i++) [results addObject:Result(@"c_mei", [NSString stringWithFormat:@"m_%d", i + 2], @[])];
    [results addObject:Result(@"", @"m_x", @[])];
    NSArray* rows = SPDFMacFriendsPaletteRows(results);
    Expect(rows.count == SPDFMacFriendsPaletteLimit + 1 && [rows[0][@"kind"] isEqual:@"header"] &&
           [rows[0][@"title"] isEqual:@"Friends messages"], @"rows %@", rows);
    Expect([rows[1][@"title"] isEqual:@"Mei · Yesterday"] &&
           [rows[1][@"subtitle"] isEqual:@"Mei: …the delivery date moved to the 20th"] &&
           SPDFMacFriendsPaletteRowIsFriends(rows[1]) && !SPDFMacFriendsPaletteRowIsFriends(rows[0]),
           @"row %@", rows[1]);
    Expect(!SPDFMacFriendsPaletteRows(@[]).count, @"no results, no header");
    NSArray* palette = @[@{@"kind" : @"openDocument"}, @{@"kind" : @"askAI"}];
    NSArray* merged = SPDFMacFriendsPaletteMergeRows(palette, [rows subarrayWithRange:NSMakeRange(0, 2)]);
    Expect([[merged valueForKey:@"kind"] isEqual:(@[@"openDocument", @"header", @"friendsMessage", @"askAI"])],
           @"Ask AI must stay last: %@", [merged valueForKey:@"kind"]);
    Expect([SPDFMacFriendsPaletteMergeRows(@[], @[rows[1]]) count] == 1 &&
           [SPDFMacFriendsPaletteMergeRows(palette, @[]) isEqual:palette], @"merge edges");
}

static void TestCitationLinks(void) {
    NSURL* url = SPDFMacFriendsMessageCitationURL(@"c_mei", @"m_1");
    NSString* conversation = nil, *message = nil;
    Expect(SPDFMacFriendsParseMessageCitationURL(url, &conversation, &message) && [conversation isEqual:@"c_mei"] &&
           [message isEqual:@"m_1"], @"citation %@", url);
    NSURL* document = [NSURL URLWithString:@"spdf-ai://document?path=x&page=1"];
    NSURL* partial = [NSURL URLWithString:@"shenzhenpdf-friends://message?conversation=c"];
    Expect(!SPDFMacFriendsParseMessageCitationURL(document, nil, nil) &&
           !SPDFMacFriendsParseMessageCitationURL(partial, nil, nil),
           @"other links are not Friends citations");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TestSettingsSurviveSaves();
        TestSettingsPane();
        TestSettingsPage();
        TestPaletteRows();
        TestCitationLinks();
    }
    puts("SPDFMacFriendsSettingsTests passed");
    return 0;
}
