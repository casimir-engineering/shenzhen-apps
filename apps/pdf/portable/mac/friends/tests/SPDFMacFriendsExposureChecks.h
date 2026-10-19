// Every other way chat content could reach the assistant, each closed by a check that fails if it opens
// (brief § AI boundaries, "Grants are the only way in"). Included by SPDFMacFriendsToolProviderTests.mm.
//
//   - The `@` picker: All Friends chats asks how long before anything is granted; only the person's choice grants.
//   - app_controls: the grant bar, the picker and Friends rows in Cmd+K are not listed, so the assistant can neither
//     read an excerpt there nor press Stop now or a length for itself.
//   - Source audit: only the scope gate opens chat scopes, only Cmd+K searches messages (for the person), only the
//     picker starts a time grant, Friends palette rows go nowhere but the palette, and "Ask AI about this…" passes
//     the typed query, never results. Run from portable/, as the suite's makefile does.

#pragma once
#import "SPDFMacAIAppControls.h"
#import "SPDFMacFriendsComposerScope.h"
#import "SPDFMacFriendsPalette.h"
#import "SPDFMacPaletteAppearance.h"

@interface GrantFixtureWindow : NSWindow
@end
@implementation GrantFixtureWindow
- (BOOL)isVisible { return YES; }
@end

static void CheckComposerLengthStep(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 120)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSScrollView* input = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 10, 480, 68)];
    NSTextView* composer = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 64)];
    composer.richText = NO;
    composer.font = [NSFont systemFontOfSize:13];
    input.documentView = composer;
    [window.contentView addSubview:input];
    [window makeFirstResponder:composer];
    NSArray* rows = @[@{@"conversation_id" : @"c_mei", @"title" : @"Mei"}];
    SPDFMacFriendsComposerScope* scope = [[SPDFMacFriendsComposerScope alloc] initWithComposer:composer
        choices:^(SPDFMacFriendsChoicesDelivery deliver) { deliver(SPDFMacFriendsScopeChoices(rows)); }];
    __block NSArray* offered = nil, *lengths = nil;
    __block NSInteger granted = -1;
    scope.presentPicker = ^(NSUInteger index, NSArray* choices) { (void)index; offered = choices; };
    scope.presentLengths = ^(NSUInteger index, NSArray* choices) { (void)index; lengths = choices; };
    scope.available = YES;

    // Without a grant to give (no time grants here), All Friends chats is a chip for this message, as before.
    [composer insertText:@"Ask @" replacementRange:composer.selectedRange];
    [scope choose:offered[0]];
    Expect(!lengths && !SPDFMacFriendsScopeInText(composer.textStorage).conversationIDs &&
           SPDFMacFriendsScopeInText(composer.textStorage), @"All Friends chats without time grants must be a chip");

    scope.grantAllChats = ^BOOL(SPDFMacFriendsGrantLength length) { granted = length; return YES; };
    composer.string = @"";
    [composer insertText:@"Ask @" replacementRange:composer.selectedRange];
    [scope choose:offered[0]];
    Expect(lengths.count == 3 && granted == -1 && [composer.string isEqual:@"Ask @"],
           @"All Friends chats must ask how long before granting anything: %@", composer.string);
    [scope choose:lengths[1]];
    Expect(granted == SPDFMacFriendsGrantLengthHour && [composer.string isEqual:@"Ask "] &&
           !SPDFMacFriendsTextHasChips(composer.textStorage) && scope.note.hidden,
           @"1 hour must start the grant and take the @ away, with no chip: %@", composer.string);
    granted = -1;
    [composer insertText:@"@" replacementRange:composer.selectedRange];
    [scope choose:offered[0]];
    [scope choose:lengths[0]];
    SPDFMacFriendsScopeRequest* chip = SPDFMacFriendsScopeInText(composer.textStorage);
    Expect(granted == -1 && chip && !chip.conversationIDs && !scope.note.hidden,
           @"\"This request\" must be the All Friends chats chip, never a grant");
    [scope uninstall];
}

static BOOL InspectionMentions(NSDictionary* inspection, NSString* text) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:inspection options:0 error:nil];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] containsString:text];
}

static void CheckAppControlsCannotReach(void) {
    gGrantNow = [NSDate date];
    SPDFMacFriendsChatGrant* grant = NewGrant();
    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    __block SPDFMacFriendsGrantBar* shown = nil;
    SPDFMacFriendsGrantBar* bar = [[SPDFMacFriendsGrantBar alloc] initWithGrant:grant
        show:^(SPDFMacFriendsGrantBar* b) { shown = b; }];
    Expect(shown == bar && [bar.accessibilityLabel hasPrefix:@"The assistant can read all your Friends chats · "],
           @"the bar must show while the grant runs: %@", bar.accessibilityLabel);

    GrantFixtureWindow* window = [[GrantFixtureWindow alloc] initWithContentRect:NSMakeRect(-20000, -20000, 700, 500)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView* content = window.contentView;
    bar.frame = NSMakeRect(0, 0, 400, 30);
    [content addSubview:bar];
    NSTextView* composer = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    SPDFMacFriendsComposerScope* scope = [[SPDFMacFriendsComposerScope alloc] initWithComposer:composer
        choices:^(SPDFMacFriendsChoicesDelivery deliver) { deliver(@[]); }];
    NSView* picker = [scope pickerViewWithChoices:SPDFMacFriendsGrantLengthChoices() title:@"How long"];
    SPDFMacFriendsComposerScope* other = [[SPDFMacFriendsComposerScope alloc] initWithComposer:composer
        choices:^(SPDFMacFriendsChoicesDelivery deliver) { deliver(@[]); }];
    NSView* friends = [other pickerViewWithChoices:SPDFMacFriendsScopeChoices(@[]) title:nil];
    [content addSubview:picker];
    [content addSubview:friends];
    SZFriendsSearchResult* hit = [SZFriendsSearchResult new];
    hit.conversationID = @"c_mei";
    hit.messageID = @"m_1";
    hit.conversationTitle = @"Mei";
    hit.excerpt = @[@{@"text" : @"the delivery date moved to the 20th"}];
    for (NSDictionary* row in SPDFMacFriendsPaletteRows(@[hit])) [content addSubview:SPDFPaletteResultView(row)];
    [content addSubview:[NSButton buttonWithTitle:@"Other" target:nil action:@selector(performClick:)]];
    NSMutableDictionary* targets = [NSMutableDictionary dictionary];
    NSDictionary* inspection = SPDFMacAIAppControlsInspect(nil, @[window], targets);
    Expect(InspectionMentions(inspection, @"Other") && !InspectionMentions(inspection, @"Stop now") &&
           !InspectionMentions(inspection, @"Search friends") && !InspectionMentions(inspection, @"20th") &&
           [picker.identifier hasPrefix:SPDFMacAIAppControlsHiddenPrefix],
           @"app_controls reached the grant bar, the picker or a Friends excerpt: %@", inspection);

    [bar.stopButton performClick:nil];
    Expect(!grant.active && shown == nil, @"Stop now must end the grant and take the bar away");
    [bar uninstall];
    [scope uninstall];
    [other uninstall];
}

// Every source file under mac/ outside tests that contains `needle`, as paths relative to portable/.
static NSSet<NSString*>* SourcesMentioning(NSString* needle) {
    NSMutableSet* found = [NSMutableSet set];
    NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:@"mac"];
    for (NSString* path in walk) {
        if ([path containsString:@"tests/"] || ![@[@"h", @"m", @"mm"] containsObject:path.pathExtension]) continue;
        NSString* full = [@"mac" stringByAppendingPathComponent:path];
        NSString* text = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
        if ([text containsString:needle]) [found addObject:full];
    }
    return found;
}

static void ExpectSources(NSString* needle, NSArray<NSString*>* allowed, NSString* why) {
    NSSet* found = SourcesMentioning(needle);
    Expect([found isEqual:[NSSet setWithArray:allowed]], @"%@ (%@): %@", why, needle, found);
}

static void CheckChatContentPaths(void) {
    BOOL isDirectory = NO;
    Expect([NSFileManager.defaultManager fileExistsAtPath:@"mac/friends" isDirectory:&isDirectory] && isDirectory,
           @"the audit must run from portable/");
    ExpectSources(@"openChatScopeForConversations:", @[@"mac/friends/SPDFMacFriendsChatScopeGate.mm"],
                  @"only the scope gate may open chats for the assistant");
    ExpectSources(@"searchMessages:", @[@"mac/friends/SPDFMacFriendsPaletteIntegration.mm"],
                  @"message search is Cmd+K's, for the person, never a tool's");
    ExpectSources(@"grantAllChatsFor:", (@[@"mac/friends/SPDFMacFriendsAssistantIntegration.mm",
                                          @"mac/friends/SPDFMacFriendsChatGrant.h",
                                          @"mac/friends/SPDFMacFriendsChatGrant.mm"]),
                  @"only the person's choice in the @ picker may start a time grant");
    ExpectSources(@"chipForGrantToken:", (@[@"mac/friends/SPDFMacFriendsToolProvider.mm",
                                           @"mac/friends/SPDFMacFriendsChatGrant.h",
                                           @"mac/friends/SPDFMacFriendsChatGrant.mm"]),
                  @"only the Friends provider may put a running grant on a request");
    ExpectSources(@"SPDFMacFriendsPaletteRows", (@[@"mac/friends/SPDFMacFriendsPalette.h",
                                                  @"mac/friends/SPDFMacFriendsPalette.mm",
                                                  @"mac/friends/SPDFMacFriendsPaletteIntegration.mm"]),
                  @"Friends results in Cmd+K go to the palette and nowhere else");
    ExpectSources(@"friendsSearchPaletteQuery", (@[@"mac/SPDFMacCollectionPalette.mm",
                                                  @"mac/friends/SPDFMacFriendsIntegration.h",
                                                  @"mac/friends/SPDFMacFriendsPaletteIntegration.mm"]),
                  @"only the palette asks Friends for results");
    // "Ask AI about this…" opens a chat with what the person typed, never the rows under it.
    for (NSString* path in SourcesMentioning(@"showAIChatForQuery:")) {
        NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSRange range = NSMakeRange(0, text.length);
        while ((range = [text rangeOfString:@"showAIChatForQuery:" options:0 range:range]).location != NSNotFound) {
            NSUInteger start = NSMaxRange(range);
            NSRange close = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"]{;"]
                                                  options:0 range:NSMakeRange(start, text.length - start)];
            NSString* argument = [[text substringWithRange:NSMakeRange(start, close.location - start)]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSArray* safe = @[@"nil", @"_paletteSearchField.stringValue", @"(NSString*)query"];
            Expect([safe containsObject:argument],
                   @"%@ opens AI chat with %@, which may carry Cmd+K results", path, argument);
            range = NSMakeRange(start, text.length - start);
        }
    }
}
