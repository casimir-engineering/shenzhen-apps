// Chat activity rows in the real chat view: placement after their messages, disclosure, live actions, cards with
// Markdown and attachments, images with Save, in-place updates and search; then their layout at the dock's minimum
// (320 pt) and default (400 pt) widths. Included by SPDFMacAIChatViewTests.mm after ChatFixture, Find, Click and
// InspectTargets.
#pragma once
#import "../SPDFMacAIChatActivity.h"
#import "../SPDFMacAIChatActivityView.h"
#import "../SPDFMacChatMarkdownView.h"
#import "../SPDFMacCollectionStyle.h"

@interface ActivityChatFixture : ChatFixture
@property(nonatomic) NSDictionary<NSString*, NSArray*>* live;
@property(nonatomic) NSMutableArray<NSString*>* performed;
@end
@implementation ActivityChatFixture
- (NSArray*)liveActivityActionsForEntry:(NSString*)identifier { return self.live[identifier] ?: @[]; }
- (BOOL)performActivityAction:(NSString*)action forEntry:(NSString*)identifier {
    [self.performed addObject:[NSString stringWithFormat:@"%@:%@", identifier, action]];
    return YES;
}
@end

static NSString* WriteSizedPNG(NSString* directory, NSInteger width, NSInteger height) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    NSBitmapImageRep* pixels = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:width
        pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
    memset(pixels.bitmapData, 120, (size_t)(width * height * 4));
    NSString* name = [NSUUID.UUID.UUIDString stringByAppendingString:@".png"];
    NSString* path = [directory stringByAppendingPathComponent:name];
    [[pixels representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    return path;
}
static NSString* WriteActivityPNG(NSString* directory) { return WriteSizedPNG(directory, 4, 2); }

static BOOL ContainsLabel(NSView* root, NSString* text) {
    if ([root isKindOfClass:NSTextField.class] && [[(NSTextField*)root stringValue] isEqual:text]) return YES;
    for (NSView* child in root.subviews) if (ContainsLabel(child, text)) return YES;
    return NO;
}

// Text that wraps and Markdown that renders again at a new width do so after the layout pass that resized them.
static void SettleActivity(NSView* view) {
    for (int round = 0; round < 3; round++) {
        [view layoutSubtreeIfNeeded];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
    }
    [view layoutSubtreeIfNeeded];
}

static void RunChatActivityViewChecks(void) {
    NSString* scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"spdf-ai-activity-view-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    setenv("SPDF_STATE_DIR", scratch.UTF8String, 1);
    NSString* image = WriteActivityPNG([scratch stringByAppendingPathComponent:@"Chats/activity-assets"]);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 900)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    ActivityChatFixture* fixture = [ActivityChatFixture new];
    fixture.performed = [NSMutableArray array];
    NSDictionary* cancel = @{@"id" : @"cancel", @"title" : @"Cancel"};
    NSMutableDictionary* step = [@{@"id" : @"S", @"kind" : @"step", @"after" : @1, @"title" : @"Searching the web",
        @"detail" : @"delivery dates 2026", @"state" : @"running", @"actions" : @[cancel]} mutableCopy];
    NSDictionary* card = @{@"id" : @"C", @"kind" : @"card", @"after" : @2, @"title" : @"Sent to Mei",
        @"body" : @"**Done** today.", @"state" : @"running", @"status" : @"Sends when Mei is nearby",
        @"attachments" : @[@{@"name" : @"contract.pdf", @"detail" : @"PDF · 2 MB"}], @"actions" : @[cancel]};
    NSDictionary* picture = @{@"id" : @"I", @"kind" : @"image", @"after" : @2, @"state" : @"done",
        @"image" : @{@"path" : image, @"caption" : @"Deliveries by month"}};
    NSString* notKept = @"The messages it read aren’t kept after this request, because it included your Friends chats.";
    NSDictionary* kept = @{@"id" : @"R", @"kind" : @"card", @"after" : @2, @"title" : @"Read your chat with Mei",
        @"body" : notKept, @"state" : @"done", @"requestOnly" : @YES, @"redacted" : @YES};
    NSArray* messages = @[@{@"role" : @"user", @"content" : @"Plot the deliveries"},
                          @{@"role" : @"assistant", @"content" : @"Here is the chart."}];
    fixture.chat = @{@"id" : @"activity", @"messages" : messages, @"activity" : @[step, card, picture, kept]};
    fixture.live = @{@"S" : @[cancel], @"C" : @[cancel]};
    [view displaySession:(id)fixture];
    SettleActivity(view);
    NSStackView* rows = [view valueForKey:@"messages"];
    NSArray* arranged = rows.arrangedSubviews;
    NSUInteger stepIndex = [arranged indexOfObject:Find(view, @"activity:S")];
    Check(arranged.count == 8 && stepIndex == 2 && [arranged indexOfObject:Find(view, @"activity:C")] == 5 &&
          [arranged indexOfObject:Find(view, @"activity:R")] == 7,
          @"activity sits after the messages it followed, in order");
    Check(!Find(view, @"activityDetail:S") && Find(view, @"activityToggle:S"), @"a step starts collapsed");
    Click(window, (NSButton*)Find(view, @"activityToggle:S"), NSMakePoint(2, 2));
    SettleActivity(view);
    NSTextView* detail = (NSTextView*)Find(view, @"activityDetail:S");
    Check([detail.string isEqual:@"delivery dates 2026"], @"the disclosure shows the step's detail");
    NSButton* toggle = (NSButton*)Find(view, @"activityToggle:S");
    Click(window, toggle, NSMakePoint(NSWidth(toggle.bounds) - 2, NSHeight(toggle.bounds) - 2));
    SettleActivity(view);
    Check(!Find(view, @"activityDetail:S"), @"the disclosure hides it again, at either corner");
    NSButton* stop = (NSButton*)Find(view, @"activityAction:S:cancel");
    Click(window, stop, NSMakePoint(NSWidth(stop.bounds) - 2, 2));
    Check([fixture.performed isEqual:@[@"S:cancel"]] && [stop.accessibilityLabel containsString:@"Searching the web"],
          @"Cancel reaches the session for that entry and names what it cancels");
    NSTextView* body = (NSTextView*)Find(view, @"activityBody:C");
    NSFont* bold = [body.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
    Check([body.string hasPrefix:@"Done today."] && (bold.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold),
          @"a card body renders as Markdown");
    Check(ContainsLabel(Find(view, @"activity:C"), @"contract.pdf · PDF · 2 MB") &&
          [[(NSTextField*)Find(view, @"activityStatus:C") stringValue] isEqual:@"Sends when Mei is nearby"] &&
          Find(view, @"activityAction:C:cancel"), @"a card shows its attachments, status and live action");
    Check(!Find(view, @"activityAction:R:cancel") && [[(NSTextView*)Find(view, @"activityBody:R") string]
          isEqual:notKept], @"a redacted card shows its notice, no buttons");
    Check([[(NSImageView*)Find(view, @"activityImage:I") image] size].width > 0, @"an image from the chat shows");
    __block NSString* savedPath = nil;
    view.saveImage = ^(NSString* path, NSString* caption) { (void)caption; savedPath = path; };
    Click(window, (NSButton*)Find(view, @"activitySave:I"), NSMakePoint(2, 2));
    Check([savedPath isEqual:image], @"Save offers the image's own file");
    Check(InspectTargets(view) >= 12, @"every activity button is reachable at its corners");

    NSView* userText = arranged[1];
    step[@"state"] = @"done"; step[@"status"] = @"5 results"; [step removeObjectForKey:@"actions"];
    fixture.chat = @{@"id" : @"activity", @"messages" : messages, @"activity" : @[step, card, picture, kept]};
    fixture.live = @{@"C" : @[cancel]};
    [view displaySession:(id)fixture];
    SettleActivity(view);
    Check(rows.arrangedSubviews[1] == userText &&
          [[(NSTextField*)Find(view, @"activityStatus:S") stringValue] isEqual:@"5 results"] &&
          !Find(view, @"activityAction:S:cancel"), @"a finished step is redrawn alone, its Cancel gone");
    [view setChatSearchQuery:@"chart"];
    Check(!Find(view, @"activity:S") && !Find(view, @"activity:C"), @"searching a chat shows matching messages only");
    [view setChatSearchQuery:@""];
    fixture.chat = @{@"id" : @"moved", @"messages" : messages, @"activity" : @[@{@"id" : @"X", @"kind" : @"image",
        @"after" : @2, @"image" : @{@"path" : @"/etc/hosts.png", @"caption" : @"Elsewhere"}}]};
    [view displaySession:(id)fixture];
    Check(!Find(view, @"activityImage:X") &&
          ContainsLabel(Find(view, @"activity:X"), @"This image is no longer available."),
          @"an image outside the chat's storage is never read");
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    fixture.chat = @{@"id" : @"dark", @"messages" : messages, @"activity" : @[step, card, picture]};
    [view displaySession:(id)fixture];
    SettleActivity(view);
    Check(Find(view, @"activityBody:C") != nil, @"activity rows draw in the dark appearance");
    [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
    unsetenv("SPDF_STATE_DIR");
}

// WCAG 2 contrast of two colours as `appearance` draws them.
static double ActivityChannel(double c) { return c <= .04045 ? c / 12.92 : pow((c + .055) / 1.055, 2.4); }
static double ActivityContrast(NSColor* text, NSColor* background, NSString* appearance) {
    __block double ratio = 0;
    [[NSAppearance appearanceNamed:appearance] performAsCurrentDrawingAppearance:^{
        double luminance[2];
        NSArray* colors = @[text, background];
        for (int i = 0; i < 2; i++) {
            NSColor* c = [colors[i] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            luminance[i] = .2126 * ActivityChannel(c.redComponent) + .7152 * ActivityChannel(c.greenComponent) +
                .0722 * ActivityChannel(c.blueComponent);
        }
        ratio = (MAX(luminance[0], luminance[1]) + .05) / (MIN(luminance[0], luminance[1]) + .05);
    }];
    return ratio;
}
static BOOL SameColor(NSColor* a, NSColor* b) { return ActivityContrast(a, b, NSAppearanceNameAqua) < 1.01; }
static NSRect InTranscript(NSView* view, NSView* transcript) {
    return view ? [view convertRect:view.bounds toView:transcript] : NSZeroRect;
}
static NSColor* PixelAt(NSView* view, NSPoint point) {
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return [rep colorAtX:(NSInteger)(point.x * rep.pixelsWide / NSWidth(view.bounds))
                       y:(NSInteger)(point.y * rep.pixelsHigh / NSHeight(view.bounds))];
}

// Longer than a 320 or 400 pt transcript has room for beside its host.
static NSString* const kLongLinkTitle = @"Delivery schedule for every bracket order placed with Mei Lin Fabrication";
static NSDictionary* LayoutChat(NSString* chart, NSString* page) {
    NSDictionary* cancel = @{@"id" : @"cancel", @"title" : @"Cancel"}, *show = @{@"id" : @"show", @"title" : @"Show"};
    NSMutableString* table = [@"| supplier | city | part | qty | unit price | currency | lead time | incoterm | "
                              "contact | status |\n|---|---|---|---|---|---|---|---|---|---|\n" mutableCopy];
    for (NSString* who in @[@"Mei Lin Fabrication", @"Kenji Works", @"Priya Metals"])
        [table appendFormat:@"| %@ | Shenzhen | bracket | 400 | 2.15 | USD | 12 days | FOB | mei@meilin.example | "
                             "confirmed |\n", who];
    NSArray* activity = @[
        @{@"id" : @"W1", @"kind" : @"step", @"after" : @1, @"title" : @"Searched the web", @"state" : @"done",
          @"status" : @"3 results", @"detail" : @"“bracket supplier delivery dates”",
          @"links" : @[@{@"url" : @"https://meilin.example/schedule", @"title" : kLongLinkTitle,
                         @"host" : @"meilin.example"}, @"https://kenji.example/news",
                       @"http://plain.example/", @"spdf-ai://document?path=a.pdf&page=2"]},
        @{@"id" : @"W2", @"kind" : @"step", @"after" : @1, @"title" : @"Opened meilin.example", @"state" : @"done"},
        @{@"id" : @"E", @"kind" : @"step", @"after" : @1, @"title" : @"Didn’t open 192.168.1.10", @"state" : @"failed",
          @"status" : @"Only public websites are opened, and this address is on a network of your own"},
        @{@"id" : @"A", @"kind" : @"step", @"after" : @1, @"title" : @"Compare supplier dates", @"state" : @"running",
          @"status" : @"Reading Supplier contract v3, page 4", @"actions" : @[cancel]},
        @{@"id" : @"T", @"kind" : @"card", @"after" : @1, @"title" : @"suppliers.csv", @"state" : @"done",
          @"status" : @"3 rows", @"body" : table},
        @{@"id" : @"I", @"kind" : @"image", @"after" : @1, @"state" : @"done",
          @"image" : @{@"path" : chart, @"caption" : @"Deliveries by month"}},
        @{@"id" : @"X", @"kind" : @"card", @"after" : @1, @"title" : @"Install Python for the assistant?",
          @"state" : @"running", @"status" : @"Not installed",
          @"actions" : @[@{@"id" : @"install", @"title" : @"Install"}]},
        @{@"id" : @"P", @"kind" : @"step", @"after" : @2, @"title" : @"Ran Python", @"state" : @"done",
          @"detailStyle" : @"python", @"detail" : @"import pandas as pd\nfor month in range(12):\n    print(month, "
          "pd.Timestamp(2026, month + 1, 1).day_name(), 'a long line that never wraps in the code box')"},
        @{@"id" : @"S", @"kind" : @"card", @"after" : @3, @"title" : @"Message for Mei", @"state" : @"running",
          @"status" : @"Friends sends it when Mei is online or nearby. Show opens your chat with Mei, where you can "
          "see when it arrives.", @"body" : @"Can the brackets ship **Friday**?", @"actions" : @[show, cancel]},
        @{@"id" : @"F", @"kind" : @"card", @"after" : @3, @"title" : @"Not sent to Priya", @"state" : @"failed",
          @"status" : @"Friends stopped responding, so this may not have been sent. Check your chat with Priya."},
        @{@"id" : @"L", @"kind" : @"card", @"after" : @3, @"title" : @"Message for Mei", @"state" : @"running",
          @"cardKind" : @"friends.send", @"body" : LiteralMessage(), @"status" : @"Not sent yet. Check it, then "
          "press Send.", @"actions" : @[@{@"id" : @"send", @"title" : @"Send", @"primary" : @YES}]},
        @{@"id" : @"Q", @"kind" : @"card", @"after" : @3, @"title" : @"Quoted exactly", @"state" : @"done",
          @"bodyStyle" : @"literal", @"body" : @"**not bold** <!-- shown -->"}];
    NSArray* messages = @[@{@"role" : @"user", @"content" : @"When do the brackets arrive?"},
        @{@"role" : @"assistant", @"content" : @"Friday."},
        @{@"role" : @"preview", @"local" : @YES, @"preview" : @{@"path" : page, @"caption" : @"Contract · Page 4"}}];
    return @{@"id" : @"layout", @"messages" : messages, @"activity" : activity};
}

static void CheckActivityLayout(NSString* chart, NSString* page, CGFloat width) {
    NSString* at = [NSString stringWithFormat:@" (%.0f pt)", width];
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, 2800)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    ActivityChatFixture* fixture = [ActivityChatFixture new];
    fixture.performed = [NSMutableArray array];
    fixture.chat = LayoutChat(chart, page);
    NSDictionary* cancel = @{@"id" : @"cancel", @"title" : @"Cancel"};
    fixture.live = @{@"A" : @[cancel], @"X" : @[@{@"id" : @"install", @"title" : @"Install"}],
                     @"S" : @[@{@"id" : @"show", @"title" : @"Show"}, cancel]};
    [view displaySession:(id)fixture];
    SettleActivity(view);
    Check(Find(view, @"activity:fold:W1") && !Find(view, @"activity:W1") && !Find(view, @"activity:W2") &&
          Find(view, @"activity:E") && Find(view, @"activity:A") && Find(view, @"activity:P"),
          [@"two finished steps in a row fold into one line; failures, running steps and a lone step do not"
              stringByAppendingString:at]);
    NSTextField* fold = (NSTextField*)Find(view, @"activityTitle:fold:W1");
    NSString* named = [(NSButton*)Find(view, @"activityToggle:fold:W1") accessibilityLabel];
    Check([fold.stringValue isEqual:@"2 steps"] && [named containsString:@"Opened meilin.example"],
          [@"the fold says how many steps it holds and names them" stringByAppendingString:at]);
    [(NSButton*)Find(view, @"activityToggle:fold:W1") performClick:nil];
    SettleActivity(view);
    [(NSButton*)Find(view, @"activityToggle:W1") performClick:nil];
    SettleActivity(view);
    [(NSButton*)Find(view, @"activityToggle:P") performClick:nil];
    SettleActivity(view);
    Check(NSWidth(window.contentView.frame) == width && NSWidth(view.frame) == width,
          [@"no activity row or page preview widens the chat panel" stringByAppendingString:at]);
    NSView* transcript = [(NSScrollView*)[view valueForKey:@"scroll"] documentView];
    NSRect column = InTranscript([view valueForKey:@"messages"], transcript);
    Capture(view, [NSString stringWithFormat:@"activity-%.0f", width]);  // the window shows every row

    // 1. A wide table scrolls sideways inside its card.
    SPDFMacChatMarkdownView* body = (SPDFMacChatMarkdownView*)Find(view, @"activityBody:T");
    Check([body isKindOfClass:SPDFMacChatMarkdownView.class] && body.wideBlocks.count == 1 &&
          NSHeight(Find(view, @"activity:T").frame) < 300 && NSMaxX(InTranscript(body, transcript)) <= NSMaxX(column),
          [@"a 10-column table keeps its columns and scrolls sideways inside a short card" stringByAppendingString:at]);
    // 2. A 640 px chart scales down to the transcript, left-aligned, with its caption and Save… under it.
    NSRect picture = InTranscript(Find(view, @"activityImage:I"), transcript);
    NSRect save = InTranscript(Find(view, @"activitySave:I"), transcript);
    NSRect caption = InTranscript(Find(view, @"activityCaption:I"), transcript);
    Check(NSWidth(picture) > 100 && NSMinX(picture) == NSMinX(column) && NSMaxX(picture) <= NSMaxX(column) + .5 &&
          fabs(NSHeight(picture) / NSWidth(picture) - 400. / 640.) < .02,
          [@"a wide picture scales down to the transcript, keeping its shape" stringByAppendingString:at]);
    Check(NSMinY(save) >= NSMaxY(picture) && fabs(NSMidY(save) - NSMidY(caption)) < 2 &&
          fabs(NSMaxX(save) - NSMaxX(picture)) < 1 && fabs(NSMinX(caption) - NSMinX(picture)) <= 2,
          [@"the caption and Save… share one line under the picture" stringByAppendingString:at]);
    // 3. A running step keeps its title, with its progress on the line under it.
    NSRect title = InTranscript(Find(view, @"activityTitle:A"), transcript);
    NSRect progress = InTranscript(Find(view, @"activityStatus:A"), transcript);
    NSRect stop = InTranscript(Find(view, @"activityAction:A:cancel"), transcript);
    Check(NSWidth(title) >= 100 && NSMinY(progress) >= NSMaxY(title) - 1 && NSMaxX(stop) <= NSMaxX(column),
          [@"a running step's title stays readable beside its spinner and Cancel" stringByAppendingString:at]);
    // 4. A status wraps on its own line above the actions, which sit at the right of the card.
    NSTextField* sent = (NSTextField*)Find(view, @"activityStatus:S");
    NSRect show = InTranscript(Find(view, @"activityAction:S:show"), transcript);
    NSRect cancelled = InTranscript(Find(view, @"activityAction:S:cancel"), transcript);
    NSRect card = InTranscript(Find(view, @"activity:S"), transcript);
    Check(sent.maximumNumberOfLines == 0 && NSHeight(InTranscript(sent, transcript)) > 24 &&
          NSMaxY(InTranscript(sent, transcript)) <= NSMinY(show) && fabs(NSMaxX(cancelled) - (NSMaxX(card) - 12)) < 1 &&
          NSMinX(show) < NSMinX(cancelled),
          [@"a card's status wraps above its actions, at the right" stringByAppendingString:at]);
    NSTextField* failed = (NSTextField*)Find(view, @"activityStatus:E");
    NSView* failedTitle = Find(view, @"activityTitle:E");
    Check(failedTitle && failed.maximumNumberOfLines == 0 && NSHeight(InTranscript(failed, transcript)) > 24 &&
          NSMinY(InTranscript(failed, transcript)) >= NSMaxY(InTranscript(failedTitle, transcript)) - 1,
          [@"a failed step's reason wraps whole under its title" stringByAppendingString:at]);
    // 6. Finished steps step back: 12 pt regular secondary text on 24 pt rows; running ones stay at 13 pt.
    NSTextField* quiet = (NSTextField*)Find(view, @"activityTitle:W2");
    NSNumber* weight = [quiet.font.fontDescriptor objectForKey:NSFontTraitsAttribute][NSFontWeightTrait];
    Check(quiet.font.pointSize == 12 && fabs(weight.doubleValue) < .05 &&
          SameColor(quiet.textColor, SPDFCollectionColor(@"secondary")) && NSHeight(quiet.superview.frame) == 24 &&
          [(NSTextField*)Find(view, @"activityTitle:A") font].pointSize == 13,
          [@"finished steps are quieter than running ones and the answer" stringByAppendingString:at]);
    // 7. Python shows in the code box, unwrapped, with Copy.
    SPDFMacChatMarkdownView* code = (SPDFMacChatMarkdownView*)Find(view, @"activityDetail:P");
    NSString* source = [code isKindOfClass:SPDFMacChatMarkdownView.class] ?
        SPDFMacChatMarkdownCopyText(code.textStorage, NSMakeRange(0, code.textStorage.length)) : nil;
    Check([source containsString:@"for month in range(12):\n    print(month,"] && code.wideBlocks.count == 1,
          [@"Python keeps its lines and indentation in the code box" stringByAppendingString:at]);
    // 8. Actions are pills; Install is the primary one.
    NSButton* install = (NSButton*)Find(view, @"activityAction:X:install");
    NSButton* pill = (NSButton*)Find(view, @"activityAction:S:cancel");
    Class pills = NSClassFromString(@"SPDFChatPillButton");
    Check(pills && [install isKindOfClass:pills] && [pill isKindOfClass:pills] &&
          [[install valueForKey:@"primary"] boolValue] && ![[pill valueForKey:@"primary"] boolValue] &&
          NSHeight(pill.frame) == 22,
          [@"activity actions are bordered pills, Install the primary one" stringByAppendingString:at]);
    Check(install.isAccessibilityElement && [install.accessibilityRole isEqual:NSAccessibilityButtonRole] &&
          [install.accessibilityLabel isEqual:@"Install: Install Python for the assistant?"] &&
          [install accessibilityPerformPress] && [fixture.performed containsObject:@"X:install"],
          [@"VoiceOver reads an action as a button naming what it acts on, and can press it"
              stringByAppendingString:at]);
    if (pills && [pill isKindOfClass:pills]) {
        NSPoint inside = NSMakePoint(4, NSHeight(pill.bounds) / 2);
        NSColor* resting = PixelAt(pill, inside);
        [pill mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSZeroPoint
            modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 trackingNumber:0
            userData:NULL]];
        Check(![PixelAt(pill, inside) isEqual:resting], [@"a pill fills on hover" stringByAppendingString:at]);
    }
    // 9. A web step lists its https links, one per row: the title (or address) links, with the address as its
    // tooltip, and the host follows in secondary text, whole even when the title has to give way. Its http result
    // comes last, not as a link (SPDFMacAIChatActivityStepChecks.h); the document citation not at all.
    NSStackView* links = (NSStackView*)Find(view, @"activityLinks:W1");
    NSArray<NSStackView*>* lines = [links isKindOfClass:NSStackView.class] ? (id)links.arrangedSubviews : nil;
    NSTextView* first = lines.count == 3 ? (NSTextView*)lines[0].arrangedSubviews[0] : nil;
    NSTextField* host = lines.count == 3 && lines[0].arrangedSubviews.count == 3 ?
        (NSTextField*)lines[0].arrangedSubviews[1] : nil;
    NSTextView* second = lines.count == 3 ? (NSTextView*)lines[1].arrangedSubviews[0] : nil;
    // An http row is its line of title and host, then "Not a secure page" under it.
    NSStackView* insecure = lines.count == 3 ? (NSStackView*)lines[2].arrangedSubviews.firstObject : nil;
    NSTextView* plain = [insecure isKindOfClass:NSStackView.class] ? (NSTextView*)insecure.arrangedSubviews[0] : nil;
    NSURL* firstURL = first.string.length ? [first.textStorage attribute:NSLinkAttributeName atIndex:0
                                                           effectiveRange:nil] : nil;
    Check([first.string isEqual:kLongLinkTitle] && [host.stringValue isEqual:@"meilin.example"] &&
          [second.string isEqual:@"kenji.example/news"] && lines[1].arrangedSubviews.count == 2 &&
          [firstURL.absoluteString isEqual:@"https://meilin.example/schedule"] &&
          [[first.textStorage attribute:NSToolTipAttributeName atIndex:0 effectiveRange:nil]
              isEqual:@"https://meilin.example/schedule"] &&
          SameColor(host.textColor, SPDFCollectionColor(@"secondary")) && [plain.string isEqual:@"plain.example/"] &&
          ![plain.textStorage attribute:NSLinkAttributeName atIndex:0 effectiveRange:nil],
          [@"a web step lists its https pages as links, each with its host, then its http one"
              stringByAppendingString:at]);
    NSRect hostRect = InTranscript(host, transcript), listRect = InTranscript(links, transcript);
    Check(host && NSWidth(host.frame) >= host.intrinsicContentSize.width - .5 &&
          NSMaxX(hostRect) <= NSMaxX(listRect) + .5 && NSMaxX(listRect) <= NSMaxX(column) + .5 &&
          NSWidth(first.frame) >= 60 && NSWidth(first.frame) < [first.textStorage size].width &&
          NSMaxX(InTranscript(first, transcript)) <= NSMinX(hostRect),
          [@"a long title truncates and its host stays whole beside it" stringByAppendingString:at]);
    __block NSURL* opened = nil;
    view.openLink = ^(NSURL* URL) { opened = URL; };
    if (firstURL) [first.delegate textView:first clickedOnLink:firstURL atIndex:0];
    Check(opened && [opened isEqual:firstURL],
          [@"a step's link opens through the chat's link rules" stringByAppendingString:at]);
    // 10. Text the person approves shows character for character: nothing Markdown would hide, nothing sideways.
    CheckLiteralCard(Find(view, @"activity:L"), (NSTextView*)Find(view, @"activityBody:L"), LiteralMessage(), at);
    NSTextView* quoted = (NSTextView*)Find(view, @"activityBody:Q");
    Check([quoted.string isEqual:@"**not bold** <!-- shown -->"] &&
          ![quoted isKindOfClass:SPDFMacChatMarkdownView.class],
          [@"any card asking for the literal style gets it" stringByAppendingString:at]);
    // 11. Steps in a row sit 4 pt apart, one block before the answer; a card keeps its distance.
    NSRect foldRow = InTranscript(Find(view, @"activity:fold:W1"), transcript);
    NSRect failedRow = InTranscript(Find(view, @"activity:E"), transcript);
    NSRect runningRow = InTranscript(Find(view, @"activity:A"), transcript);
    NSRect tableCard = InTranscript(Find(view, @"activity:T"), transcript);
    CGFloat foldGap = NSMinY(failedRow) - NSMaxY(foldRow), stepGap = NSMinY(runningRow) - NSMaxY(failedRow);
    Check(foldGap >= 4 - .5 && foldGap <= 6 + .5 && stepGap >= 4 - .5 && stepGap <= 6 + .5 &&
          NSMinY(tableCard) - NSMaxY(runningRow) >= 10,
          [NSString stringWithFormat:@"consecutive steps sit 4–6 pt apart (%.1f, %.1f), a card further%@", foldGap,
                                     stepGap, at]);
    // 12. A finished step says nothing more unless its provider wrote a status: "Done" under "Opened …" is noise.
    Check(!Find(view, @"activityStatus:W2") &&
          [[(NSTextField*)Find(view, @"activityStatus:W1") stringValue] isEqual:@"3 results"],
          [@"a finished step shows only a status of its own" stringByAppendingString:at]);
    // Off the window, so its running step's spinner stops animating for the suites after this one.
    window.contentView = [NSView new];
}

static NSUInteger gMarkdownRenders;
@interface SPDFMacChatMarkdownView (ActivityRenderCount)
- (void)activityCountedRenderNow;
@end
@implementation SPDFMacChatMarkdownView (ActivityRenderCount)
- (void)activityCountedRenderNow { gMarkdownRenders++; [self activityCountedRenderNow]; }  // the original, swapped
@end

// A card's Markdown and a step's code render once when their row is built, not a second time at a flush inset.
static void CheckActivityRendersOnce(void) {
    Method original = class_getInstanceMethod(SPDFMacChatMarkdownView.class, @selector(renderNow));
    Method counted = class_getInstanceMethod(SPDFMacChatMarkdownView.class, @selector(activityCountedRenderNow));
    method_exchangeImplementations(original, counted);
    gMarkdownRenders = 0;
    SPDFMacAIChatActivityRow* card = [[SPDFMacAIChatActivityRow alloc] initWithUnit:@{@"entry" : @{@"id" : @"M",
        @"kind" : @"card", @"after" : @0, @"title" : @"Table", @"state" : @"done",
        @"body" : @"| a | b |\n|---|---|\n| 1 | 2 |"}} expanded:[NSSet set] width:320];
    NSUInteger cardRenders = gMarkdownRenders;
    gMarkdownRenders = 0;
    SPDFMacAIChatActivityRow* code = [[SPDFMacAIChatActivityRow alloc] initWithUnit:@{@"entry" : @{@"id" : @"P",
        @"kind" : @"step", @"after" : @0, @"title" : @"Ran Python", @"state" : @"done", @"detailStyle" : @"python",
        @"detail" : @"print(1)"}} expanded:[NSSet setWithObject:@"P"] width:320];
    NSUInteger codeRenders = gMarkdownRenders;
    method_exchangeImplementations(original, counted);
    Check(Find(card, @"activityBody:M") && Find(code, @"activityDetail:P") && cardRenders == 1 && codeRenders == 1,
          [NSString stringWithFormat:@"a card body and a code detail render once (%lu, %lu)",
                                     (unsigned long)cardRenders, (unsigned long)codeRenders]);
}

static void RunChatActivityLayoutChecks(void) {
    CheckActivityRendersOnce();
    NSString* scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"spdf-ai-activity-layout-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    setenv("SPDF_STATE_DIR", scratch.UTF8String, 1);
    NSString* assets = [scratch stringByAppendingPathComponent:@"Chats/layout-assets"];
    NSString* chart = WriteSizedPNG(assets, 640, 400), *page = WriteSizedPNG(assets, 1200, 1600);
    for (NSNumber* width in @[@320, @400]) CheckActivityLayout(chart, page, width.doubleValue);
    // 5. Failure text reads at 4.5:1 or better on the card in both appearances (systemRed: 3.6 and 4.1).
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    ActivityChatFixture* fixture = [ActivityChatFixture new];
    fixture.chat = LayoutChat(chart, page);
    [view displaySession:(id)fixture];
    for (NSString* key in @[@"activityStatus:F", @"activityStatus:E"]) {
        NSColor* red = [(NSTextField*)Find(view, key) textColor];
        double light = ActivityContrast(red, SPDFCollectionColor(@"window"), NSAppearanceNameAqua);
        double dark = ActivityContrast(red, SPDFCollectionColor(@"window"), NSAppearanceNameDarkAqua);
        Check(red && light >= 4.5 && dark >= 4.5, [NSString stringWithFormat:@"failure text contrast %@: %.2f light, "
                                                   "%.2f dark", key, light, dark]);
    }
    // Resizing the dock keeps the rows (they are not rebuilt): their text wraps again and pictures scale again.
    fixture.live = @{@"S" : @[@{@"id" : @"show", @"title" : @"Show"}]};
    [view displaySession:(id)fixture];
    SettleActivity(view);
    NSTextField* status = (NSTextField*)Find(view, @"activityStatus:S");
    // Overlay scroll bars, as without a mouse, so the widths below do not depend on the Mac's setting.
    status.enclosingScrollView.scrollerStyle = NSScrollerStyleOverlay;
    SettleActivity(view);
    CGFloat wide = NSHeight(status.frame), wideLine = status.preferredMaxLayoutWidth;
    [window setContentSize:NSMakeSize(320, 600)];
    SettleActivity(view);
    NSView* row = Find(view, @"activity:S");
    NSRect aligned = [status alignmentRectForFrame:status.frame];
    Check(Find(view, @"activityStatus:S") == status && NSWidth(window.contentView.frame) == 320 &&
          NSHeight(status.frame) > wide && status.preferredMaxLayoutWidth < wideLine - 40 &&
          fabs(status.preferredMaxLayoutWidth - NSWidth(aligned)) < 1 &&
          NSMaxX([status.superview convertRect:aligned toView:row]) <= NSWidth(row.frame) - 12 + .5 &&
          NSWidth(Find(view, @"activityImage:I").frame) <= NSWidth(row.frame),
          @"narrowing the dock re-wraps a card's status and scales its picture, without widening the panel");
    window.contentView = [NSView new];
    [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
    unsetenv("SPDF_STATE_DIR");
}
