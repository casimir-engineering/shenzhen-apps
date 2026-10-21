#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "../SPDFMacAIChatView.h"
#import "../SPDFMacAIChatMarkdown.h"
#import "../SPDFMacAIChatSession.h"
#import "../SPDFMacAIChatSearch.h"
#import "../SPDFMacAIChatActivity.h"
#import "../SPDFMacChatMarkdownView.h"
#import "../SPDFMacAIChatViewParts.h"
static int failures;
static NSEvent* pendingUp;
@interface NSButton (AIChatSymbolProbe)
- (NSRect)rectForSymbol:(NSImage*)image;
@end
@interface NSWindow (AIChatProbe)
- (NSEvent*)chatProbeEvent:(NSEventMask)mask;
@end
@implementation NSWindow (AIChatProbe)
- (NSEvent*)chatProbeEvent:(NSEventMask)mask { (void)mask; NSEvent* event=pendingUp; pendingUp=nil; return event; }
@end
@interface ChatFixture : NSObject
@property(nonatomic) NSDictionary* chat;
@property(nonatomic) NSString* status;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL canUndo;
@property(nonatomic) BOOL canRedo;
@property(nonatomic) BOOL canCompact;
@property(nonatomic) BOOL canRetry;
@property(nonatomic) SPDFMacAIChatActivityState activityState;
@property(nonatomic) NSString* activityDetail;
@end
@implementation ChatFixture @end
static void Check(BOOL yes,NSString* message) { if(!yes) { failures++; fprintf(stderr,"FAIL %s\n",message.UTF8String); } }
static NSView* Find(NSView* root,NSString* key) {
    if([root.identifier isEqual:key]) return root;
    for(NSView* child in root.subviews) { NSView* found=Find(child,key); if(found) return found; } return nil;
}
static NSUInteger InspectTargets(NSView* view) {
    NSUInteger count=0;
    if([view isKindOfClass:NSClassFromString(@"SPDFChatButton")] && !view.hiddenOrHasHiddenAncestor) {
        NSView* root=view.window.contentView;
        for(NSValue* p in @[[NSValue valueWithPoint:NSMakePoint(2,2)],
            [NSValue valueWithPoint:NSMakePoint(NSWidth(view.bounds)-2,NSHeight(view.bounds)-2)]]) {
            if(!NSPointInRect(p.pointValue,view.visibleRect)) continue;
            NSPoint point=[view convertPoint:p.pointValue toView:nil];
            Check([root hitTest:[root.superview convertPoint:point fromView:nil]]==view,
                [@"chat action visible corners unobstructed: " stringByAppendingString:view.identifier]); count++;
        }
    }
    for(NSView* child in view.subviews) count+=InspectTargets(child); return count;
}
static NSUInteger ImageCount(NSView* view) {
    NSUInteger count=[view isKindOfClass:NSImageView.class] ? 1 : 0;
    for(NSView* child in view.subviews) count+=ImageCount(child); return count;
}
// Evidence renders go where SPDF_AI_CHAT_RENDERS names, to be looked at; otherwise into a folder of this run's own,
// removed when it exits, so a test run leaves nothing behind.
static NSString* gOwnRenders;
static void RemoveOwnRenders(void) {
    if(gOwnRenders) [NSFileManager.defaultManager removeItemAtPath:gOwnRenders error:nil];
}
static NSString* RenderPath(NSString* name) {
    static NSString* folder;
    if(!folder) {
        const char* named=getenv("SPDF_AI_CHAT_RENDERS");
        if(named && *named) {
            folder=@(named);
            [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                          error:nil];
        } else {
            char pattern[PATH_MAX];
            snprintf(pattern,sizeof pattern,"%s/sz-ai-chat-renders.XXXXXX",
                     NSTemporaryDirectory().fileSystemRepresentation);
            if(mkdtemp(pattern)) { folder=gOwnRenders=@(pattern); atexit(RemoveOwnRenders); }
            else folder=NSTemporaryDirectory();
        }
    }
    return [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"sz-ai-chat-%@.png",name]];
}
static void Capture(NSView* view,NSString* name) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds]; [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    Check([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:RenderPath(name)
        atomically:YES],@"native state evidence saved");
}
static void Click(NSWindow* window,NSButton* button,NSPoint local) {
    NSPoint point=[button convertPoint:local toView:nil];
    NSView* root=window.contentView; NSView* hit=[root hitTest:[root.superview convertPoint:point fromView:nil]];
    Check(hit==button,@"native hierarchy owns full button bounds");
    NSTimeInterval stamp=NSProcessInfo.processInfo.systemUptime;
    NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:stamp
        windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    pendingUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:stamp+.01
        windowNumber:window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
    Method original=class_getInstanceMethod(NSWindow.class,@selector(nextEventMatchingMask:));
    Method injected=class_getInstanceMethod(NSWindow.class,@selector(chatProbeEvent:));
    method_exchangeImplementations(original,injected); [hit mouseDown:down]; method_exchangeImplementations(original,injected);
}
// AppKit calls -visualizeConstraints: when it has to break a constraint, once the
// NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints default is on (its log goes only to the unified log);
// counting the calls instead of drawing them keeps the window off screen.
@interface ConstraintWatchWindow : NSWindow
@property(nonatomic) NSUInteger conflicts;
@end
@implementation ConstraintWatchWindow
- (void)visualizeConstraints:(NSArray<NSLayoutConstraint*>*)constraints { (void)constraints; self.conflicts++; }
@end
static void CheckNoConstraintConflicts(void) {
    NSString* key=@"NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints";
    [NSUserDefaults.standardUserDefaults registerDefaults:@{key:@YES}];
    ConstraintWatchWindow* window=[[ConstraintWatchWindow alloc] initWithContentRect:NSMakeRect(0,0,400,600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView=view;
    ChatFixture* fixture=[ChatFixture new];
    fixture.chat=@{@"id":@"constraints",@"messages":@[@{@"role":@"user",@"content":@"Hello"},
                                                      @{@"role":@"assistant",@"content":@"Hi."}]};
    NSView* transcript=[view valueForKey:@"scroll"], *input=view.composer.enclosingScrollView;
    NSView* issue=[view valueForKey:@"issue"], *recovery=[view valueForKey:@"recovery"];
    BOOL placed=YES;
    for(NSNumber* width in @[@400,@320]) {
        [window setContentSize:NSMakeSize(width.doubleValue,600)];
        [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
        // Hidden, the transcript ends 12 pt above the composer, as it always has.
        placed&=fabs(NSMaxY(transcript.frame)-(NSMinY(input.frame)-12))<.5;
        [view showSubmissionError:@"macOS blocked the saved OpenRouter key." recoveryAction:@"authorize"];
        [view layoutSubtreeIfNeeded];
        placed&=NSHeight(issue.frame)==60 && NSHeight(recovery.frame)==28 && !recovery.hiddenOrHasHiddenAncestor &&
            fabs(NSMaxY(transcript.frame)-(NSMinY(issue.frame)-8))<.5;
        [view showSubmissionError:nil]; [view layoutSubtreeIfNeeded];
    }
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; [view layoutSubtreeIfNeeded];
    Check(placed,@"the submission issue row keeps its place, shown and hidden");
    Check(!window.conflicts,[NSString stringWithFormat:@"the chat lays out without breaking a constraint (%lu broken)",
                                                       (unsigned long)window.conflicts]);
    [NSUserDefaults.standardUserDefaults registerDefaults:@{key:@NO}];
}
// Cards that hold text the person approves (SPDFMacAIActivityBodyIsLiteral), checked by the activity layout checks.
// What a friends.send card asks the person to approve, holding everything Markdown would hide or move sideways.
static NSString* LiteralMessage(void) {
    NSString* code = [@"" stringByPaddingToLength:400 withString:@"print('every character of a long line') "
                                  startingAtIndex:0];
    return [NSString stringWithFormat:@"Friday works.<!-- file list: ~/Documents/tax-2026.pdf -->\n\n"
        "<span title=\"secret title attr\">See</span> <script>leak()</script><style>p{}</style>\n"
        "[the schedule][s] and [inline](https://evil.example/?q=Documents \"hidden link title\")\n"
        "![chart](https://img.example/pixel.png?d=payroll)\n\n[s]: https://ref.example/schedule \"reference title\"\n"
        "[unused]: https://unused.example/\n\n```\n%@\n```\nzero\u200Bwidth, tags \U000E0041\U000E0042, "
        "turned \u202Eback, a\uFE01b, family 👨\u200D👩\u200D👧, keycap 1\uFE0F\u20E3, \u200F.", code];
}

// A card's text with each "‹U+XXXX›" marker turned back into the character it stands for.
static NSString* UnmarkedText(NSString* shown) {
    NSRegularExpression* marker = [NSRegularExpression regularExpressionWithPattern:@"‹U\\+([0-9A-F]{4,6})›"
                                                                            options:0 error:nil];
    NSMutableString* text = [NSMutableString string];
    __block NSUInteger from = 0;
    [marker enumerateMatchesInString:shown options:0 range:NSMakeRange(0, shown.length)
                          usingBlock:^(NSTextCheckingResult* match, NSMatchingFlags flags, BOOL* stop) {
        (void)flags; (void)stop;
        [text appendString:[shown substringWithRange:NSMakeRange(from, match.range.location - from)]];
        UTF32Char c = (UTF32Char)strtoul([shown substringWithRange:[match rangeAtIndex:1]].UTF8String, NULL, 16);
        unichar units[2] = {(unichar)c, 0};
        BOOL pair = c > 0xFFFF && CFStringGetSurrogatePairForLongCharacter(c, units);
        [text appendString:[NSString stringWithCharacters:units length:pair ? 2 : 1]];
        from = NSMaxRange(match.range);
    }];
    [text appendString:[shown substringFromIndex:from]];
    return text;
}

static NSUInteger ScrollViews(NSView* root) {
    NSUInteger count = [root isKindOfClass:NSScrollView.class] ? 1 : 0;
    for (NSView* child in root.subviews) count += ScrollViews(child);
    return count;
}

// Every character Friends will deliver is on the card, laid out inside it: the HTML comment, tag attributes, script,
// link addresses and titles, reference definitions, the whole long line, and characters that draw nothing.
static void CheckLiteralCard(NSView* card, NSTextView* body, NSString* message, NSString* at) {
    NSArray* parts = @[@"<!-- file list: ~/Documents/tax-2026.pdf -->", @"title=\"secret title attr\"",
        @"<script>leak()</script><style>p{}</style>", @"(https://evil.example/?q=Documents \"hidden link title\")",
        @"![chart](https://img.example/pixel.png?d=payroll)", @"[s]: https://ref.example/schedule \"reference title\"",
        @"[unused]: https://unused.example/", @"‹U+200B›", @"‹U+E0041›‹U+E0042›", @"‹U+202E›", @"‹U+FE01›",
        @"‹U+200F›", @"👨\u200D👩\u200D👧", @"1\uFE0F\u20E3"];
    BOOL all = body.string.length > 0;
    for (NSString* part in parts) all &= [body.string containsString:part];
    NSArray* longestFirst = [[message componentsSeparatedByString:@"\n"]
        sortedArrayUsingComparator:^(NSString* a, NSString* b) { return [@(b.length) compare:@(a.length)]; }];
    NSString* line = longestFirst.firstObject;
    Check(all && [body.string containsString:line] && [UnmarkedText(body.string) isEqual:message] &&
          ![body isKindOfClass:SPDFMacChatMarkdownView.class],
          [@"a send card shows its message as literal text, every character" stringByAppendingString:at]);
    __block BOOL decorated = NO;
    [body.textStorage enumerateAttributesInRange:NSMakeRange(0, body.textStorage.length) options:0
                                      usingBlock:^(NSDictionary* attributes, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        decorated |= attributes[NSLinkAttributeName] || attributes[NSAttachmentAttributeName];
    }];
    NSArray<NSValue*>* invisible = nil;
    SPDFMacAIActivityVisibleText(body.string, &invisible);
    Check(!decorated && !invisible.count && !ScrollViews(card),
          [@"no link, picture, sideways strip or invisible character on a send card" stringByAppendingString:at]);
    NSLayoutManager* layout = body.layoutManager;
    NSTextContainer* container = body.textContainer;
    [layout ensureLayoutForTextContainer:container];
    __block CGFloat right = 0;
    __block NSUInteger lines = 0;
    [layout enumerateLineFragmentsForGlyphRange:NSMakeRange(0, layout.numberOfGlyphs)
                                     usingBlock:^(NSRect rect, NSRect used, NSTextContainer* in, NSRange glyphs,
                                                  BOOL* stop) {
        (void)rect; (void)in; (void)glyphs; (void)stop;
        right = MAX(right, NSMaxX(used));
        lines++;
    }];
    NSRect used = [layout usedRectForTextContainer:container];
    Check(layout.firstUnlaidCharacterIndex == body.string.length && right <= container.size.width + .5 &&
          fabs(container.size.width - (NSWidth(body.bounds) - 2 * body.textContainerInset.width)) < 1 &&
          NSMaxY(used) + 2 * body.textContainerInset.height <= NSHeight(body.bounds) + .5 &&
          lines > [message componentsSeparatedByString:@"\n"].count &&
          NSContainsRect(NSInsetRect(card.bounds, -.5, -.5), [body convertRect:body.bounds toView:card]),
          [NSString stringWithFormat:@"the message wraps inside the card, long line included (%.0f of %.0f pt)%@",
                                     right, container.size.width, at]);
    Check([[(NSTextField*)Find(card, [@"activityNote:" stringByAppendingString:[body.identifier
              substringFromIndex:@"activityBody:".length]]) stringValue] isEqual:
              @"Each ‹U+…› marks a character in the message that doesn’t show on screen."],
          [@"marked characters are explained under the message" stringByAppendingString:at]);
}

#import "SPDFMacAIChatDockChecks.h"
#import "SPDFMacAIChatReopenChecks.h"
#import "SPDFMacAIChatOrderChecks.h"
#import "SPDFMacAIChatBlankRowsChecks.h"
#import "SPDFMacAIAnswerCardViewChecks.h"
#import "SPDFMacAIChatActivityViewChecks.h"
#import "SPDFMacAIChatActivityStepChecks.h"
#import "SPDFMacAIChatBannerChecks.h"
#import "SPDFMacAIChatEditChecks.h"
#import "SPDFMacAIChatLinkChecks.h"
#import "SPDFMacAIChatRetryChecks.h"
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSDate* started=[NSDate date];
    CheckNoConstraintConflicts();
    RunChatBannerChecks();
    RunChatReopenChecks();
    RunChatOrderChecks();
    RunBlankChatRowsChecks();
    RunAnswerCardViewChecks();
    RunChatActivityViewChecks();
    RunChatActivityLayoutChecks();
    RunChatActivityStepChecks();
    RunChatLinkChecks();
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,760,580) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds]; window.contentView=view;
    ChatFixture* fixture=[ChatFixture new]; fixture.chat=@{@"id":@"test",@"messages":@[
        @{@"role":@"user",@"content":@"What is the board’s power requirement?"},
        @{@"role":@"assistant",@"content":@"## Power requirements\nThe board uses **5 V input**. See [the schematic, page 2](spdf-ai://document?path=board.pdf&page=2).\n\n- Peak current: **2 A**\n- Check connector polarity before connecting.\n\n```c\nconst float voltage = 5.0f;\n```\n\nI checked the schematic and assembly notes. The values agree; the assembly guide also recommends a regulated supply. The test fixture intentionally includes a longer paragraph describing evidence quality, connector assumptions, polarity and voltage tolerance. These words must wrap over additional lines in a narrow chat panel while remaining fully selectable and never covering the next message."}
    ]};
    [view displaySession:(id)fixture]; [window.contentView layoutSubtreeIfNeeded];
    NSStackView* messages=[view valueForKey:@"messages"];
    NSTextView* answer=(id)messages.arrangedSubviews[3]; CGFloat wide=NSHeight(answer.frame);
    Check([answer.string hasPrefix:@"Power requirements"],@"assistant response follows the user in chronological order");
    Check([[(NSTextField*)Find(view,@"latestUserPrompt") stringValue] containsString:@"What is the board’s power requirement?"],@"latest user question stays visible above a long answer");
    [window setContentSize:NSMakeSize(520,580)]; [window.contentView layoutSubtreeIfNeeded];
    // The message renders again for its new width after the layout pass that resized it: wait for that, up to 5 s,
    // instead of a fixed 20 ms, which a loaded machine sometimes missed.
    BOOL (^fits)(void)=^BOOL{
        NSRange finalGlyph=NSMakeRange(answer.layoutManager.numberOfGlyphs-1,1);
        NSRect finalLine=[answer.layoutManager boundingRectForGlyphRange:finalGlyph
                                                          inTextContainer:answer.textContainer];
        return NSHeight(answer.frame)>wide && NSMaxY(finalLine)<=NSHeight(answer.bounds)+.5;
    };
    for(NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];!fits() && deadline.timeIntervalSinceNow>0;) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        [window.contentView layoutSubtreeIfNeeded];
    }
    Check(NSHeight(answer.frame)>wide,@"message height reflows at narrower width");
    Check([answer.string hasSuffix:@"next message."] && fits(),
        @"compact measurement preserves the final line of long wrapped prose");
    Check(InspectTargets(view)>=10,@"all narrow chat header controls tested at visible corners");
    NSScrollView* transcript=[view valueForKey:@"scroll"];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; [view layoutSubtreeIfNeeded];
    Check(fabs(NSMaxY(transcript.contentView.bounds)-NSHeight(transcript.documentView.bounds))<2,
        @"newest message bottom stays visible after narrow reflow");
    NSTextField* question=(id)Find(view,@"latestUserPrompt");
    Check(NSContainsRect(view.bounds,[question convertRect:question.bounds toView:view]) &&
        NSMaxY([question convertRect:question.bounds toView:view])<=NSMinY(transcript.frame),@"question context fits above the transcript without overlap at minimum width");
    __block NSURL* citation; __block NSRange citationRange=NSMakeRange(NSNotFound,0);
    [answer.textStorage enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0,answer.string.length) options:0
        usingBlock:^(id value,NSRange range,BOOL* stop) {
            if([[value description] hasPrefix:@"spdf-ai://"]) { citation=value; citationRange=range; *stop=YES; }
        }];
    Check([citation.absoluteString isEqual:@"spdf-ai://document?path=board.pdf&page=2"],@"rendered citation preserves the exact custom URL");
    if(citationRange.location!=NSNotFound) {
        NSRange glyph=[answer.layoutManager glyphRangeForCharacterRange:NSMakeRange(citationRange.location,1) actualCharacterRange:nil];
        NSRect rect=[answer.layoutManager boundingRectForGlyphRange:glyph inTextContainer:answer.textContainer];
        [answer scrollRangeToVisible:citationRange];[view layoutSubtreeIfNeeded];
        NSPoint point=[answer convertPoint:NSMakePoint(NSMidX(rect)+answer.textContainerOrigin.x,NSMidY(rect)+answer.textContainerOrigin.y) toView:nil];
        Check([view hitTest:[view.superview convertPoint:point fromView:nil]]==answer,@"native citation glyph hit reaches its message view");
        __block NSURL* opened; view.openLink=^(NSURL* URL){ opened=URL; };
        [answer.delegate textView:answer clickedOnLink:citation atIndex:citationRange.location];
        Check([opened.absoluteString isEqual:citation.absoluteString],@"native text link delegate routes the exact document citation");
    }
    Check([NSStringFromClass(view.composer.enclosingScrollView.class) isEqual:@"SPDFChatInputScrollView"],@"composer uses explicit appearance-aware border drawing");
    Check(![(NSButton*)Find(view,@"undo") isEnabled],@"Undo is disabled without a reversible action");
    __block NSUInteger accepted=0; view.sendText=^BOOL(NSString* text){(void)text;return NO;};
    view.composer.string=@"Keep this draft"; NSButton* send=(id)Find(view,@"send"); [send performClick:nil];
    Check([view.composer.string isEqual:@"Keep this draft"],@"unconfigured account preserves composer text");
    view.sendText=^BOOL(NSString* text){(void)text;accepted++;return YES;};
    for(NSValue* p in @[[NSValue valueWithPoint:NSMakePoint(2,2)],[NSValue valueWithPoint:NSMakePoint(NSWidth(send.bounds)-2,NSHeight(send.bounds)-2)]]) {
        view.composer.string=@"A question"; Click(window,send,p.pointValue);
        Check(!view.composer.string.length,@"accepted native click clears submitted text");
    }
    Check(accepted==2,@"each full-bounds click submits exactly once");
    [window makeFirstResponder:view.composer];
    [view.composer setMarkedText:@"中文" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)];
    [view.composer keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
    Check(accepted==2,@"IME Return confirms composition without sending unfinished text");
    [view.composer unmarkText];view.composer.string=@"";

    __block NSMutableArray* actions=[NSMutableArray array];
    view.action=^(NSString* action){[actions addObject:action];};
    fixture.canUndo=YES;fixture.canRedo=YES;[view refreshActivityFromSession:(id)fixture];
    [window setContentSize:NSMakeSize(360,600)];[view layoutSubtreeIfNeeded];
    for(NSString* key in @[@"close",@"new",@"undo",@"redo",@"settings"]) {
        NSButton* button=(id)Find(view,key);
        Check(button.image && button.toolTip.length,@"panel actions have vector symbols and hover help");
        NSRect icon=[button rectForSymbol:button.image];
        Check(NSContainsRect(NSInsetRect(button.bounds,6,6),icon) &&
            fabs(NSWidth(icon)/NSHeight(icon)-button.image.size.width/button.image.size.height)<.0001,@"symbols keep fixed aspect ratio");
        Click(window,button,NSMakePoint(2,2));
        Click(window,button,NSMakePoint(NSWidth(button.bounds)-2,NSHeight(button.bounds)-2));
    }
    Check(actions.count==10,@"each header action responds at both corners at narrow width");
    NSEvent* redoKey=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagShift timestamp:0 windowNumber:window.windowNumber context:nil characters:@"Z" charactersIgnoringModifiers:@"Z" isARepeat:NO keyCode:6];
    [window makeFirstResponder:nil];[view.composer performKeyEquivalent:redoKey];
    Check(actions.count==10,@"composer cannot steal Undo or Redo from another focused control");
    [window makeFirstResponder:view.composer];
    Check([view.composer performKeyEquivalent:redoKey] && [actions.lastObject isEqual:@"redo"] && actions.count==11,@"uppercase Cmd Shift Z reaches agent Redo from empty composer");
    NSSearchField* chatSearch=[view valueForKey:@"chatSearch"]; chatSearch.stringValue=@"polarity";
    [(id<NSSearchFieldDelegate>)view controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:chatSearch]];
    Check([chatSearch.placeholderString isEqual:@"Search this chat"] && messages.arrangedSubviews.count==2,@"chat search filters only matching messages in this conversation");
    NSTextView* match=(id)messages.arrangedSubviews[1];
    NSRange hit=[match.string rangeOfString:@"polarity"];
    Check(hit.location!=NSNotFound && [match.layoutManager temporaryAttribute:NSBackgroundColorAttributeName atCharacterIndex:hit.location effectiveRange:nil],@"matching term is highlighted in rendered message");
    NSDictionary* originalChat=fixture.chat;
    NSString* padding=[@"Context line with enough text to wrap at narrow widths.\n\n" stringByPaddingToLength:3500 withString:@"Context line with enough text to wrap at narrow widths.\n\n" startingAtIndex:0];
    fixture.chat=@{@"id":@"search-deep",@"messages":@[@{@"role":@"assistant",@"content":[NSString stringWithFormat:@"%@First needle passage.\n\n%@Second needle passage.\n\n%@",padding,padding,padding]}]};
    Check(SPDFMacAIChatHasTextMatch(fixture.chat,@"NEEDLE") && !SPDFMacAIChatHasTextMatch(fixture.chat,@"search-deep") &&
        !SPDFMacAIChatHasTextMatch(@{@"messages":@[@{@"role":@"tool",@"content":@"needle"}]},@"needle"),
        @"history content search finds visible speaker messages, excluding titles and internal tool results");
    [view displaySession:(id)fixture];[view setChatSearchQuery:@"needle"];
    void (^checkVisibleHit)(NSUInteger)=^(NSUInteger occurrence) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.08]];[view layoutSubtreeIfNeeded];
        NSTextView* text=(id)messages.arrangedSubviews[1];NSRange hit=[text.string rangeOfString:@"needle"];
        if(occurrence)hit=[text.string rangeOfString:@"needle" options:0 range:NSMakeRange(NSMaxRange(hit),text.string.length-NSMaxRange(hit))];
        NSRange glyph=[text.layoutManager glyphRangeForCharacterRange:NSMakeRange(hit.location,1) actualCharacterRange:nil];
        NSRect rect=[text.layoutManager boundingRectForGlyphRange:glyph inTextContainer:text.textContainer];
        rect.origin.x+=text.textContainerOrigin.x;rect.origin.y+=text.textContainerOrigin.y;
        rect=[text convertRect:rect toView:transcript.documentView];
        Check(NSContainsRect(transcript.contentView.bounds,rect),@"chat search reveals exact glyph deep inside a long message");
        Check([text.layoutManager temporaryAttribute:NSBackgroundColorAttributeName atCharacterIndex:hit.location effectiveRange:nil]!=nil,
            @"revealed search occurrence stays highlighted while field has focus");
    };
    checkVisibleHit(0);Capture(view,@"search-exact-passage");
    Check([(id<NSSearchFieldDelegate>)view control:chatSearch textView:(id)chatSearch.currentEditor doCommandBySelector:@selector(insertNewline:)],@"Return in chat search navigates matches instead of submitting a message");
    checkVisibleHit(1);
    [(SPDFMacAIChatSearch*)[view valueForKey:@"chatFind"] moveBy:-1];checkVisibleHit(0);
    fixture.chat=originalChat;[view displaySession:(id)fixture];
    [view setChatSearchQuery:@"nonexistent"];
    Check(!messages.arrangedSubviews.count && [[(NSTextField*)Find(view,@"chatActivityDetail") stringValue] isEqual:@"No matches in this chat"],@"no-match feedback remains local to current chat");
    [view setChatSearchQuery:@""];
    Check(messages.arrangedSubviews.count==4 && !Find(view,@"history"),@"clearing local search restores both speakers; duplicate history action removed");
    NSRect hideRect=[Find(view,@"close") convertRect:Find(view,@"close").bounds toView:view];
    Check(NSMinY(hideRect)==4 && NSHeight(hideRect)==28 && NSMinX(hideRect)<NSMinX([Find(view,@"new") convertRect:Find(view,@"new").bounds toView:view]),@"Hide is first in the aligned36point toolbar");
    Capture(view,@"docked-compact");
    fixture.running=YES; fixture.activityState=SPDFMacAIChatActivityWorking;
    fixture.status=@"Reading · Schematic, page 2"; fixture.activityDetail=fixture.status; [view displaySession:(id)fixture];
    Check([[(NSTextField*)Find(view,@"chatStatus") stringValue] containsString:@"Working"] &&
        [[(NSTextField*)Find(view,@"chatActivityDetail") stringValue] containsString:@"Schematic"],@"active work shows an explicit heading and current tool detail");
    Check(!send.enabled && [(NSButton*)Find(view,@"stop") isEnabled],@"active task has explicit stop action");
    [window setContentSize:NSMakeSize(760,580)];
    for(NSString* appearance in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
        window.appearance=[NSAppearance appearanceNamed:appearance];
        [view displayChats:@[]]; [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
        NSTextView* assistant=(id)messages.arrangedSubviews[3];
        NSTextView* user=(id)messages.arrangedSubviews[1];
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            Check(![[assistant.backgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace]
                isEqual:[user.backgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace]],@"user and assistant have distinct shades in each theme");
        }];
        NSBitmapImageRep* rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds]; [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        Check([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:RenderPath(appearance) atomically:YES],@"chat native preview saved");
    }
    [view displayChats:@[]];
    Check([(NSButton*)Find(view,@"stop") isEnabled],@"history keeps cancellation available for active tasks");
    fixture.running=NO; fixture.activityState=SPDFMacAIChatActivityStopped;
    fixture.status=@"Stopped. Completed changes can still be undone."; fixture.activityDetail=fixture.status; fixture.canUndo=YES;
    [view refreshActivityFromSession:(id)fixture];
    Check(![(NSButton*)Find(view,@"stop") isEnabled] && [(NSButton*)Find(view,@"undo") isEnabled],@"history refreshes task completion and undo state");
    Check([[(NSTextField*)[view valueForKey:@"status"] stringValue] hasPrefix:@"Stopped"],@"history shows current task status");
    Check(Find(view,@"current")!=nil,@"history offers return to current conversation");
    Check(view.composer.enclosingScrollView.hidden && Find(view,@"send").hidden,@"history hides the noneditable composer and Send");
    Check(![(NSButton*)Find(view,@"deleteAll") isEnabled],@"empty history cannot delete nonexistent chats");
    Check(InspectTargets(view)>=10,@"history controls remain reachable without composer");
    Capture(view,@"history-stopped");
    [window setContentSize:NSMakeSize(520,400)];
    fixture.chat=@{@"id":@"question",@"messages":@[
        @{@"role":@"user",@"content":@"Summarize the design notes."},
        @{@"role":@"assistant",@"content":@"Which document should I use: **Power supply** or **Board layout**?"}]};
    fixture.activityState=SPDFMacAIChatActivityCompleted; fixture.activityDetail=@"Waiting for your next message.";
    [view displaySession:(id)fixture]; Capture(view,@"question");
    window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [view displaySession:(id)fixture]; Capture(view,@"question-dark");
    NSTextView* compact=(id)messages.arrangedSubviews[1];
    NSView* nextRole=messages.arrangedSubviews[2];
    NSRect bodyRect=[compact convertRect:compact.bounds toView:transcript.documentView];
    NSRect nextRect=[nextRole.superview convertRect:[nextRole alignmentRectForFrame:nextRole.frame] toView:transcript.documentView];
    Check(NSHeight(compact.frame)<=40 && NSMinY(nextRect)-NSMaxY(bodyRect)>=15 && NSMinY(nextRect)-NSMaxY(bodyRect)<=20,
        @"short messages include comfortable padding and consistent16–20point separation");
    Check([compact.string hasSuffix:@"design notes."] && ![compact.string hasSuffix:@"\n"],@"only renderer-added terminal blank lines are removed");
    Check(InspectTargets(view)>=12,@"minimum-height chat keeps every header and footer action reachable");
    Check(NSHeight(transcript.frame)>80 && NSContainsRect(view.bounds,view.composer.enclosingScrollView.frame),@"minimum-height chat keeps transcript and composer usable");
    Check([[(NSTextField*)Find(view,@"chatStatus") stringValue] containsString:@"Ready for your reply"] && send.enabled,@"finished question explicitly invites the user’s reply");
    fixture.activityState=SPDFMacAIChatActivityThinking; fixture.activityDetail=@"Waiting for the model…"; fixture.running=YES;
    [view displaySession:(id)fixture]; Capture(view,@"thinking");
    Check([[(NSTextField*)Find(view,@"chatStatus") stringValue] isEqual:@"Thinking…"],@"thinking is a prominent explicit state");
    fixture.activityState=SPDFMacAIChatActivityPaused; fixture.activityDetail=@"Changes saved. Ask a follow-up to continue."; fixture.running=NO;
    [view displaySession:(id)fixture];
    Check([[(NSTextField*)Find(view,@"chatStatus") stringValue] hasPrefix:@"Paused"] && ![[(NSTextField*)Find(view,@"chatStatus") stringValue] containsString:@"Error"],@"step limit shows paused instead of incorrectly labelling successful changes an error");
    fixture.activityState=SPDFMacAIChatActivityError; fixture.activityDetail=@"Chat changed in another window. Reopen the latest conversation to continue."; fixture.running=NO;
    [view displaySession:(id)fixture]; Capture(view,@"error");
    Check([[(NSTextField*)Find(view,@"chatStatus") stringValue] containsString:@"Error"] &&
        [[(NSTextField*)Find(view,@"chatActivityDetail") stringValue] containsString:@"another window"],@"error heading and recovery detail remain visible");
    CheckRetryRow(view,fixture);
    view.composer.string=@"Please summarize this document.";
    [view showSubmissionError:@"macOS blocked the saved OpenRouter key. Authorize access to send this message." recoveryAction:@"authorize"];
    Capture(view,@"authorize-minimum");
    NSView* issue=Find(view,@"chatSubmissionIssue");
    Check(NSContainsRect(view.bounds,issue.frame) && NSContainsRect(view.bounds,view.composer.enclosingScrollView.frame) &&
        NSHeight(transcript.frame)>20 && InspectTargets(view)>=14,@"authorization recovery and preserved draft fit at520×400");
    [view showSubmissionError:nil]; view.composer.string=@"";
    fixture.chat=@{@"id":@"question",@"messages":@[
        @{@"role":@"user",@"content":@"Use the board layout."},
        @{@"role":@"assistant",@"content":@"Updated answer with the requested document."}]};
    [view displaySession:(id)fixture];
    Check([[(NSTextView*)messages.arrangedSubviews[3] string] hasPrefix:@"Updated answer"] &&
        [[(NSTextField*)Find(view,@"latestUserPrompt") stringValue] containsString:@"Use the board layout"],@"same-count transcript changes refresh both question context and answer");
    NSMutableArray* longMessages=[NSMutableArray array];
    for(NSUInteger i=0;i<45;i++) [longMessages addObject:@{@"role":@"user",@"content":[NSString stringWithFormat:@"Message %lu",(unsigned long)i]}];
    fixture.chat=@{@"id":@"long",@"messages":longMessages}; [view displaySession:(id)fixture];
    NSButton* older=(id)Find(view,@"older"); Check(older!=nil,@"long conversations reveal older-message affordance");
    Capture(view,@"older-messages");
    [view setChatSearchQuery:@"Message 0"];
    Check(messages.arrangedSubviews.count==2 && [[(NSTextView*)messages.arrangedSubviews[1] string] isEqual:@"Message 0"],@"search includes older messages beyond the initial40message viewport");
    [view setChatSearchQuery:@""]; older=(id)Find(view,@"older");
    [older performClick:nil]; Check(Find(view,@"older")==nil && messages.arrangedSubviews.count==90,@"older messages remain available on demand");
    NSString* scratch=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    setenv("SPDF_STATE_DIR",scratch.UTF8String,1);
    NSString* assets=[scratch stringByAppendingPathComponent:@"Chats/test-assets"];
    [NSFileManager.defaultManager createDirectoryAtPath:assets withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* imagePath=[assets stringByAppendingPathComponent:@"page.png"];
    NSBitmapImageRep* tiny=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:8 bitsPerPixel:32];
    memset(tiny.bitmapData,255,16);
    [[tiny representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:imagePath atomically:YES];
    fixture.chat=@{@"id":@"preview",@"messages":@[@{@"role":@"preview",@"local":@YES,
        @"preview":@{@"path":imagePath,@"caption":@"Schematic · Page 2",@"citation":@{@"path":@"board.pdf",@"page":@2}}}]};
    [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
    Check(ImageCount(view)==1,@"trusted tool page preview is displayed from chat assets");
    fixture.chat=@{@"id":@"blocked-preview",@"messages":@[@{@"role":@"preview",@"local":@YES,
        @"preview":@{@"path":@"/tmp/private.png",@"caption":@"Untrusted path"}}]};
    [view displaySession:(id)fixture];
    Check(ImageCount(view)==0,@"preview outside chat assets cannot load a local file");
    fixture.chat=@{@"id":@"empty",@"messages":@[]}; fixture.status=@""; fixture.activityState=SPDFMacAIChatActivityIdle; fixture.activityDetail=@"";
    [view displaySession:(id)fixture]; Capture(view,@"empty");
    Check(messages.arrangedSubviews.count==1 && [messages.arrangedSubviews.firstObject isKindOfClass:NSTextField.class],@"empty chat uses plain helper text without an empty message bubble");
    [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
        Check(!window.visible,@"probe never shows an app window");
    CheckChatDock();
    // Earlier runs rewrote /tmp/sz-ai-chat-*.png every time and never removed them.
    BOOL wroteTmp=NO;
    for(NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/private/tmp" error:nil]) {
        if(![name hasPrefix:@"sz-ai-chat-"]) continue;
        NSString* path=[@"/private/tmp" stringByAppendingPathComponent:name];
        NSDate* written=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
        wroteTmp|=[written compare:started]!=NSOrderedAscending;
    }
    Check(!wroteTmp && [NSFileManager.defaultManager fileExistsAtPath:RenderPath(@"empty")],
          @"evidence renders go to SPDF_AI_CHAT_RENDERS or this run's own folder, never /tmp");
    RunChatEditChecks();
    fprintf(stderr,"AI chat view: %d failures\n",failures); return failures?1:0;
} }
