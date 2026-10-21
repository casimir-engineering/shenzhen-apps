#import "SPDFMacAIChatActivityView.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAIChatViewParts.h"
#import "SPDFMacAIChatMarkdown.h"
#import "SPDFMacChatMarkdownView.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacCollectionStyle.h"

// The disclosure, and where text under a step's title starts (the disclosure plus the header's spacing).
static const CGFloat kDisclosure = 24, kIndent = 30;
// Tall enough for a chart, short enough that a portrait picture leaves the answer in view.
static const CGFloat kImageMaxHeight = 320;

NSImage* SPDFMacAIChatStoredImage(NSString* path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return nil;
    NSString* root = SPDFMacAIChatStore.defaultDirectory.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString* resolved = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (![resolved hasPrefix:[root stringByAppendingString:@"/"]] ||
        ![resolved.pathExtension.lowercaseString isEqual:@"png"]) return nil;
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:resolved error:nil];
    if (!attributes.fileSize || attributes.fileSize > 8 * 1024 * 1024) return nil;
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:resolved];
    return image.size.width > 0 && image.size.height > 0 ? image : nil;
}

void SPDFMacAIChatSaveStoredImage(NSWindow* window, NSString* path, NSString* caption) {
    if (!SPDFMacAIChatStoredImage(path) || !window) return;
    NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@"/:\\"];
    NSString* name = [[[caption componentsSeparatedByCharactersInSet:separators] componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length > 80) name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:
                                                           NSMakeRange(0, 80)]];
    if ([name.pathExtension.lowercaseString isEqual:@"png"]) name = name.stringByDeletingPathExtension;
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [(name.length ? name : @"Image") stringByAppendingPathExtension:@"png"];
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSURL* target = [panel.URL.pathExtension.lowercaseString isEqual:@"png"] ? panel.URL :
            [panel.URL URLByAppendingPathExtension:@"png"];
        NSError* error = nil;
        NSData* data = [NSData dataWithContentsOfFile:path options:0 error:&error];
        if (!data || ![data writeToURL:target options:NSDataWritingAtomic error:&error]) [window presentError:error];
    }];
}

// Done or stopped, with nothing left to press: the steps a fold may hide.
static BOOL Foldable(NSDictionary* row) {
    NSDictionary* entry = row[@"entry"];
    NSString* state = entry[SPDFMacAIActivityStateKey];
    return [entry[SPDFMacAIActivityKindKey] isEqual:SPDFMacAIActivityKindStep] && ![row[@"actions"] count] &&
        ([state isEqual:SPDFMacAIActivityStateDone] || [state isEqual:SPDFMacAIActivityStateStopped]);
}

NSArray<NSDictionary*>* SPDFMacAIChatActivityUnits(NSArray<NSDictionary*>* rows) {
    NSMutableArray* units = [NSMutableArray array], *run = [NSMutableArray array];
    void (^flush)(void) = ^{
        if (run.count >= 2) [units addObject:@{@"fold" : [run copy], @"entry" : run.firstObject[@"entry"]}];
        else [units addObjectsFromArray:run];
        [run removeAllObjects];
    };
    for (NSDictionary* row in rows) {
        id anchor = row[@"entry"][SPDFMacAIActivityAnchorKey];
        // A message between two steps ends the run: a fold never hides where the steps happened.
        if (!Foldable(row) || (run.count && ![run.firstObject[@"entry"][SPDFMacAIActivityAnchorKey] isEqual:anchor]))
            flush();
        if (Foldable(row)) [run addObject:row];
        else [units addObject:row];
    }
    flush();
    return units;
}

NSString* SPDFMacAIChatActivityUnitKey(NSDictionary* unit) {
    NSString* identifier = unit[@"entry"][SPDFMacAIActivityIDKey] ?: @"";
    return unit[@"fold"] ? [@"fold:" stringByAppendingString:identifier] : identifier;
}

// Web pages: https ones as links, as links in chat Markdown open, then http ones, which never open from the chat but
// are still results the step counted. A document or Friends citation has no place in a list of web pages.
static NSArray<NSDictionary*>* ShownLinks(NSDictionary* entry) {
    NSMutableArray* links = [NSMutableArray array], *insecure = [NSMutableArray array];
    for (id link in entry[SPDFMacAIActivityLinksKey]) {
        BOOL titled = [link isKindOfClass:NSDictionary.class];
        NSURL* URL = [NSURL URLWithString:titled ? link[@"url"] : link];
        NSString* scheme = URL.scheme.lowercaseString;
        // A PDF the assistant downloaded (SPDFMacAIWebPDF.h) opens in the reader; it is on no site, so it has no host.
        BOOL app = [scheme isEqual:@"spdf-ai"] && [URL.host isEqual:@"web-document"];
        BOOL secure = ([scheme isEqual:@"https"] || app) && SPDFMacAIChatLinkAllowed(URL);
        if ((!secure && ![scheme isEqual:@"http"]) || !URL.host.length) continue;
        NSString* host = app ? @"" : titled && link[@"host"] ? link[@"host"] : URL.host;
        NSString* title = titled ? link[@"title"] : nil;
        NSMutableDictionary* row = [@{@"url" : URL, @"host" : host} mutableCopy];
        if (title && ![title isEqual:host]) row[@"title"] = title;  // else the address said twice
        if (!secure) row[@"insecure"] = @YES;
        [secure ? links : insecure addObject:row];
    }
    return [links arrayByAddingObjectsFromArray:insecure];
}

@interface SPDFMacAIChatActivityRow () <NSTextViewDelegate>
@end

@implementation SPDFMacAIChatActivityRow {
    NSDictionary* _entry;
    NSSet<NSString*>* _open;
    BOOL _card;
}

- (instancetype)initWithUnit:(NSDictionary*)unit expanded:(NSSet<NSString*>*)expanded width:(CGFloat)width {
    width = MAX(160, width);
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, width, 24)])) return nil;
    _unit = [unit copy];
    _entry = unit[@"entry"] ?: @{};
    _entryID = [SPDFMacAIChatActivityUnitKey(unit) copy];
    _open = [expanded copy] ?: [NSSet set];
    self.identifier = [@"activity:" stringByAppendingString:_entryID];
    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 2;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    NSString* kind = _entry[SPDFMacAIActivityKindKey];
    if (unit[@"fold"]) [self buildFold:unit[@"fold"] width:width];
    else if ([kind isEqual:SPDFMacAIActivityKindCard]) [self buildCard:unit[@"actions"] width:width];
    else if ([kind isEqual:SPDFMacAIActivityKindImage]) [self buildImage:width];
    else [self buildStep:unit[@"actions"] width:width];
    return self;
}

- (void)addFullWidth:(NSView*)view {
    [self addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:self.widthAnchor constant:-(self.edgeInsets.left + self.edgeInsets.right)]
        .active = YES;
}

- (NSView*)gap:(CGFloat)width {
    NSView* gap = [NSView new];
    gap.translatesAutoresizingMaskIntoConstraints = NO;
    [gap.widthAnchor constraintEqualToConstant:width].active = YES;
    return gap;
}

// Under the title: a step's status, detail and links, a fold's steps.
- (void)addIndented:(NSView*)view {
    NSStackView* line = [NSStackView stackViewWithViews:@[[self gap:kIndent - 6], view]];
    line.spacing = 6;
    line.alignment = NSLayoutAttributeTop;
    line.distribution = NSStackViewDistributionFill;
    [self addFullWidth:line];
}

- (NSStackView*)header:(NSArray<NSView*>*)views height:(CGFloat)height {
    NSStackView* header = [NSStackView stackViewWithViews:views];
    header.spacing = 6;
    header.distribution = NSStackViewDistributionFill;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header.heightAnchor constraintEqualToConstant:height].active = YES;
    return header;
}

- (NSButton*)disclosure:(NSString*)key help:(NSArray<NSString*>*)help about:(NSString*)about {
    BOOL open = [_open containsObject:key];
    NSButton* toggle = SPDFChatMakeSymbolButton(open ? @"chevron.down" : @"chevron.right",
        [@"activityToggle:" stringByAppendingString:key], self, @selector(clicked:), kDisclosure);
    toggle.toolTip = help[open ? 1 : 0];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", toggle.toolTip, about ?: @""];
    return toggle;
}

- (NSTextField*)status:(NSString*)text wraps:(BOOL)wraps width:(CGFloat)width {
    BOOL failed = [_entry[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateFailed];
    NSTextField* status = SPDFChatLabel(text, 12, NSFontWeightRegular,
        failed ? SPDFChatFailureColor() : SPDFCollectionColor(@"secondary"), wraps, width);
    status.identifier = [@"activityStatus:" stringByAppendingString:_entryID];
    status.accessibilityLabel = text;
    return status;
}

- (NSArray<NSButton*>*)actionButtons:(NSArray<NSDictionary*>*)actions {
    NSMutableArray* buttons = [NSMutableArray array];
    for (NSDictionary* action in actions) {
        NSString* identifier = [NSString stringWithFormat:@"activityAction:%@:%@", _entryID, action[@"id"]];
        BOOL primary = [action[@"primary"] isEqual:@YES] || [action[@"id"] isEqual:@"install"];
        NSButton* button = SPDFChatMakePill(action[@"title"], identifier, self, @selector(clicked:), primary);
        button.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", action[@"title"],
                                     _entry[SPDFMacAIActivityTitleKey] ?: @""];
        [buttons addObject:button];
    }
    return buttons;
}

// Selectable text measured to its height, like a chat message.
- (NSTextView*)textBlock:(NSAttributedString*)text width:(CGFloat)width identifier:(NSString*)identifier {
    SPDFChatMessageView* view = [[SPDFChatMessageView alloc] initWithFrame:NSMakeRect(0, 0, MAX(100, width), 20)];
    view.identifier = identifier;
    view.editable = NO; view.selectable = YES; view.drawsBackground = NO; view.delegate = self;
    view.verticallyResizable = NO; view.horizontallyResizable = NO;
    view.backgroundColor = NSColor.clearColor;
    view.textContainerInset = NSMakeSize(0, 0); view.textContainer.lineFragmentPadding = 0;
    view.textContainer.widthTracksTextView = YES;
    [view.textStorage setAttributedString:text];
    view.textContainer.containerSize = NSMakeSize(MAX(100, width), CGFLOAT_MAX);
    [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
    CGFloat height = ceil(NSMaxY([view.layoutManager usedRectForTextContainer:view.textContainer]));
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.contentHeight = [view.heightAnchor constraintEqualToConstant:MAX(16, height)];
    view.contentHeight.active = YES;
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return view;
}

// The chat's Markdown renderer, as replies use it: a table, code block or diagram wider than the row keeps its size
// and scrolls sideways inside it instead of wrapping a few letters per line.
- (SPDFMacChatMarkdownView*)markdownBlock:(NSString*)markdown width:(CGFloat)width identifier:(NSString*)identifier {
    SPDFMacChatMarkdownOptions* options = [SPDFMacChatMarkdownOptions new];
    options.links = SPDFMacChatMarkdownLinksAssistant;
    // Flush with the title above it, as a chat bubble's inset would indent it; rendered once, with that inset.
    SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:markdown width:width
                                                                              options:options textInset:NSZeroSize];
    view.contentHeight.active = YES;
    view.identifier = identifier;
    view.delegate = self;
    view.backgroundColor = SPDFCollectionColor(@"window");  // the card's, which a sideways strip fades into
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return view;
}

// The chat's code box, with Copy, unwrapped: code keeps its lines and indentation, which carry meaning in Python.
// The language is its caption; one the highlighter doesn't know ("output") colours nothing, as printed output must not.
- (NSView*)codeBox:(NSString*)code language:(NSString*)language width:(CGFloat)width identifier:(NSString*)identifier {
    NSString* fence = @"```";
    while ([code containsString:fence]) fence = [fence stringByAppendingString:@"`"];
    return [self markdownBlock:[NSString stringWithFormat:@"%@%@\n%@\n%@", fence, language, code, fence] width:width
                    identifier:identifier];
}

- (NSView*)detailView:(NSString*)detail width:(CGFloat)width {
    NSString* identifier = [@"activityDetail:" stringByAppendingString:_entryID];
    NSString* style = _entry[SPDFMacAIActivityDetailStyleKey];
    if (style.length)
        return [self codeBox:detail language:[style isEqual:@"code"] ? @"" : style width:width identifier:identifier];
    return [self textBlock:[[NSAttributedString alloc] initWithString:detail attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary")}] width:width identifier:identifier];
}

- (NSView*)linksView:(NSArray<NSDictionary*>*)links width:(CGFloat)width {
    NSStackView* list = SPDFChatLinkList(links, width, self);
    list.identifier = [@"activityLinks:" stringByAppendingString:_entryID];
    return list;
}

- (void)buildStep:(NSArray<NSDictionary*>*)actions width:(CGFloat)width {
    // Clear of the transcript's overlay scroller, which otherwise takes the right edge of Cancel, and in line with
    // the contents of cards, which keep the same inset inside their border.
    self.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 12);
    CGFloat inner = width - 12;
    NSString* state = _entry[SPDFMacAIActivityStateKey], *title = _entry[SPDFMacAIActivityTitleKey] ?: @"";
    BOOL running = [state isEqual:SPDFMacAIActivityStateRunning], done = [state isEqual:SPDFMacAIActivityStateDone];
    BOOL failed = [state isEqual:SPDFMacAIActivityStateFailed], finished = !running && !failed;
    NSString* detail = _entry[SPDFMacAIActivityDetailKey], *output = _entry[SPDFMacAIActivityOutputKey];
    // Printing usually ends with a line break, which would leave an empty last line in the box.
    if ([output hasSuffix:@"\n"]) output = [output substringToIndex:output.length - 1];
    NSString* note = _entry[SPDFMacAIActivityNoteKey];
    NSArray* links = ShownLinks(_entry);
    BOOL expandable = detail.length || output.length || note.length || links.count;
    NSMutableArray* views = [NSMutableArray arrayWithObject:expandable ?
        [self disclosure:_entryID help:@[@"Show details", @"Hide details"] about:title] : [self gap:kDisclosure]];
    // A finished step steps back behind the answer; a running or failed one keeps the reader's eye.
    NSTextField* label = SPDFChatLabel(title, finished ? 12 : 13, NSFontWeightRegular,
                                       SPDFCollectionColor(finished ? @"secondary" : @"text"), NO, 0);
    label.identifier = [@"activityTitle:" stringByAppendingString:_entryID];
    // The title tells steps apart, so it is the last thing on the line to give way.
    [label setContentCompressionResistancePriority:300 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [views addObject:label];
    NSString* status = SPDFMacAIActivityStatusText(_entry);
    // As on cards, "Done" says nothing a finished step's title has not ("Opened meilin.example"); "3 results" does.
    BOOL quiet = done && ![_entry[SPDFMacAIActivityStatusKey] length];
    if (done && !quiet) [views addObject:[self status:status wraps:NO width:0]];
    if (running) {
        NSProgressIndicator* spinner = [NSProgressIndicator new];
        spinner.style = NSProgressIndicatorStyleSpinning;
        spinner.controlSize = NSControlSizeSmall;
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [spinner.widthAnchor constraintEqualToConstant:16].active = YES;
        [spinner.heightAnchor constraintEqualToConstant:16].active = YES;
        [views addObject:spinner];
        [spinner startAnimation:nil];
    }
    [views addObjectsFromArray:[self actionButtons:actions]];
    [self addFullWidth:[self header:views height:finished ? 24 : 28]];
    // Under the title, where it never squeezes it: a running step's progress on one line; why a step failed, stopped
    // or ran out of time, whole. At 320 pt that word shrank to a few letters beside the title. Not when the title
    // already ends with it: "Stopped" under "Python run stopped" says nothing more.
    BOOL said = [title.lowercaseString hasSuffix:status.lowercaseString];
    if (!done && !said) [self addIndented:[self status:status wraps:!running width:inner - kIndent]];
    if (!expandable || ![_open containsObject:_entryID]) return;
    if (detail.length) [self addIndented:[self detailView:detail width:inner - kIndent]];
    if (output.length)
        [self addIndented:[self codeBox:output language:@"output" width:inner - kIndent
                             identifier:[@"activityOutput:" stringByAppendingString:_entryID]]];
    if (note.length) {
        NSTextField* line = SPDFChatLabel(note, 12, NSFontWeightRegular, SPDFCollectionColor(@"secondary"), YES,
                                          inner - kIndent);
        line.identifier = [@"activityNote:" stringByAppendingString:_entryID];
        [self addIndented:line];
    }
    if (links.count) [self addIndented:[self linksView:links width:inner - kIndent]];
}

- (void)buildFold:(NSArray<NSDictionary*>*)rows width:(CGFloat)width {
    // No inset of its own: its steps keep theirs, so their statuses line up with the steps outside the fold.
    self.edgeInsets = NSEdgeInsetsZero;
    NSMutableArray* titles = [NSMutableArray array];
    NSUInteger stopped = 0;
    for (NSDictionary* row in rows) {
        NSString* title = row[@"entry"][SPDFMacAIActivityTitleKey];
        if (title.length) [titles addObject:title];
        stopped += [row[@"entry"][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped];
    }
    // Folded, stopped work would read as finished; the count stays whole while the titles give way.
    NSString* count = [NSString stringWithFormat:@"%lu steps", (unsigned long)rows.count];
    if (stopped) count = [count stringByAppendingFormat:@" · %lu stopped", (unsigned long)stopped];
    NSString* about = titles.count ? [NSString stringWithFormat:@"%@: %@", count,
                                      [titles componentsJoinedByString:@", "]] : count;
    NSTextField* label = SPDFChatLabel(count, 12, NSFontWeightMedium, SPDFCollectionColor(@"secondary"), NO, 0);
    label.identifier = [@"activityTitle:" stringByAppendingString:_entryID];
    [label setContentCompressionResistancePriority:300 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField* list = SPDFChatLabel(titles.count ? [@"· " stringByAppendingString:[titles componentsJoinedByString:
        @", "]] : @"", 12, NSFontWeightRegular, SPDFCollectionColor(@"secondary"), NO, 0);
    [list setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    list.toolTip = about;
    NSButton* toggle = [self disclosure:_entryID help:@[@"Show these steps", @"Hide these steps"] about:about];
    [self addFullWidth:[self header:@[toggle, label, list, [self gap:6]] height:24]];
    if (![_open containsObject:_entryID]) return;
    __weak SPDFMacAIChatActivityRow* weakSelf = self;
    for (NSDictionary* row in rows) {
        SPDFMacAIChatActivityRow* step = [[SPDFMacAIChatActivityRow alloc] initWithUnit:row expanded:_open
                                                                                  width:width - kIndent];
        step.toggled = ^(NSString* key, BOOL expanded) {
            SPDFMacAIChatActivityRow* fold = weakSelf;
            if (fold.toggled) fold.toggled(key, expanded);
        };
        step.openLink = ^(NSURL* URL) {
            SPDFMacAIChatActivityRow* fold = weakSelf;
            if (fold.openLink) fold.openLink(URL);
        };
        [self addIndented:step];
    }
}

- (void)buildCard:(NSArray<NSDictionary*>*)actions width:(CGFloat)width {
    _card = YES;
    self.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    self.spacing = 8;
    CGFloat inner = MAX(100, width - 24);
    NSTextField* title = SPDFChatLabel(_entry[SPDFMacAIActivityTitleKey], 13, NSFontWeightSemibold,
                                       SPDFCollectionColor(@"text"), YES, inner);
    title.identifier = [@"activityTitle:" stringByAppendingString:_entryID];
    [self addFullWidth:title];
    NSString* body = _entry[SPDFMacAIActivityBodyKey], *bodyID = [@"activityBody:" stringByAppendingString:_entryID];
    if (SPDFMacAIActivityBodyIsLiteral(_entry) && body.length) {
        // Exactly what will be sent, character for character: Markdown would hide comments, reference definitions,
        // link addresses and titles, and a sideways strip would hide the end of a long line.
        BOOL marked = NO;
        NSTextView* literal = SPDFChatLiteralTextView(body, inner, &marked);
        literal.identifier = bodyID;
        [self addFullWidth:literal];
        if (marked) {
            NSTextField* note = SPDFChatLabel(@"Each ‹U+…› marks a character in the message that doesn’t show on "
                "screen.", 12, NSFontWeightRegular, SPDFCollectionColor(@"secondary"), YES, inner);
            note.identifier = [@"activityNote:" stringByAppendingString:_entryID];
            [self addFullWidth:note];
        }
    } else if ((body = [body stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]).length)
        [self addFullWidth:[self markdownBlock:body width:inner identifier:bodyID]];
    for (NSDictionary* attachment in _entry[SPDFMacAIActivityAttachmentsKey]) {
        NSString* text = attachment[@"detail"] ? [NSString stringWithFormat:@"%@ · %@", attachment[@"name"],
                                                  attachment[@"detail"]] : attachment[@"name"];
        NSImageView* icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"doc"
                                                                       accessibilityDescription:nil]];
        icon.contentTintColor = SPDFCollectionColor(@"secondary");
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [icon.widthAnchor constraintEqualToConstant:14].active = YES;
        [icon.heightAnchor constraintEqualToConstant:16].active = YES;
        NSTextField* name = SPDFChatLabel(text, 12, NSFontWeightRegular, SPDFCollectionColor(@"text"), NO, 0);
        NSStackView* row = [NSStackView stackViewWithViews:@[icon, name]];
        row.spacing = 6;
        [self addFullWidth:row];
    }
    // A finished card says nothing more unless its provider wrote a status: "Done" under "Sent to Mei" is noise.
    BOOL quiet = [_entry[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
        ![_entry[SPDFMacAIActivityStatusKey] length];
    // On its own line and wrapped: why something wasn't sent, or when it arrives, is the sentence that matters most.
    if (!quiet) [self addFullWidth:[self status:SPDFMacAIActivityStatusText(_entry) wraps:YES width:inner]];
    if (!actions.count) return;
    NSStackView* footer = [NSStackView new];
    footer.spacing = 8;
    for (NSButton* button in [self actionButtons:actions])
        [footer addView:button inGravity:NSStackViewGravityTrailing];
    [self addFullWidth:footer];
}

- (void)buildImage:(CGFloat)width {
    self.spacing = 6;
    NSDictionary* image = _entry[SPDFMacAIActivityImageKey];
    NSString* caption = image[@"caption"] ?: @"Image";
    NSImage* picture = SPDFMacAIChatStoredImage(image[@"path"]);
    NSTextField* label = SPDFChatLabel(caption, 12, NSFontWeightRegular, SPDFCollectionColor(@"secondary"), NO, 0);
    label.identifier = [@"activityCaption:" stringByAppendingString:_entryID];
    if (!picture) {
        [self addFullWidth:label];
        [self addFullWidth:SPDFChatLabel(@"This image is no longer available.", 12, NSFontWeightRegular,
                                         SPDFCollectionColor(@"secondary"), YES, width)];
        return;
    }
    SPDFChatFramedImageView* view = [SPDFChatFramedImageView imageViewWithImage:picture];
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.accessibilityLabel = caption;
    view.identifier = [@"activityImage:" stringByAppendingString:_entryID];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    // Below the window's stay-put priority: a picture wider than the transcript scales down instead of widening it.
    for (NSNumber* axis in @[@(NSLayoutConstraintOrientationHorizontal), @(NSLayoutConstraintOrientationVertical)]) {
        NSLayoutConstraintOrientation orientation = (NSLayoutConstraintOrientation)axis.integerValue;
        [view setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:orientation];
        [view setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:orientation];
    }
    [self addArrangedSubview:view];
    CGFloat ratio = picture.size.height / picture.size.width;
    [view.widthAnchor constraintLessThanOrEqualToConstant:MIN(picture.size.width, kImageMaxHeight / ratio)]
        .active = YES;
    [view.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor].active = YES;
    [view.heightAnchor constraintEqualToAnchor:view.widthAnchor multiplier:ratio].active = YES;
    // Saved: "Saved to Downloads" with Open and Show in Finder while this chat stays open (SPDFMacAIOutputs.h).
    NSMutableArray* parts = [NSMutableArray arrayWithObject:label];
    NSString* status = _entry[SPDFMacAIActivityStatusKey];
    if (status.length) [parts addObject:[self status:status wraps:NO width:0]];
    NSArray* live = _unit[@"actions"];
    if (live.count) [parts addObjectsFromArray:[self actionButtons:live]];
    else {
        NSButton* save = SPDFChatMakePill(@"Save", [@"activitySave:" stringByAppendingString:_entryID], self,
                                          @selector(clicked:), NO);
        save.accessibilityLabel = [@"Save image: " stringByAppendingString:caption];
        save.toolTip = @"Save this image to your Downloads folder";
        [parts addObject:save];
    }
    NSStackView* line = [NSStackView stackViewWithViews:parts];
    line.spacing = 8;
    line.distribution = NSStackViewDistributionFill;  // the caption takes the room, so Save ends with the picture
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self addArrangedSubview:line];
    // Under the picture, ending where it ends, unless a small picture leaves Save too little room.
    [line.widthAnchor constraintGreaterThanOrEqualToAnchor:view.widthAnchor].active = YES;
    [line.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor].active = YES;
    NSLayoutConstraint* under = [line.widthAnchor constraintEqualToAnchor:view.widthAnchor];
    under.priority = 300;
    under.active = YES;
}

- (void)clicked:(NSButton*)sender {
    NSString* identifier = sender.identifier;
    if ([identifier hasPrefix:@"activityToggle:"]) {
        NSString* key = [identifier substringFromIndex:@"activityToggle:".length];
        if (self.toggled) self.toggled(key, ![_open containsObject:key]);
        return;
    }
    if ([identifier hasPrefix:@"activitySave:"]) {
        NSDictionary* image = _entry[SPDFMacAIActivityImageKey];
        if (!image[@"path"]) return;
        if (self.saveImage) self.saveImage(image[@"path"], image[@"caption"] ?: @"Image");
        else SPDFMacAIChatSaveStoredImage(self.window, image[@"path"], image[@"caption"] ?: @"Image");
        return;
    }
    NSString* prefix = [NSString stringWithFormat:@"activityAction:%@:", _entryID];
    if ([identifier hasPrefix:prefix] && self.perform)
        self.perform(_entryID, [identifier substringFromIndex:prefix.length]);
}

- (BOOL)textView:(NSTextView*)textView clickedOnLink:(id)link atIndex:(NSUInteger)index {
    (void)textView; (void)index;
    NSURL* URL = [link isKindOfClass:NSURL.class] ? link : [NSURL URLWithString:[link description]];
    if (self.openLink && SPDFMacAIChatLinkAllowed(URL)) self.openLink(URL);
    return YES;
}

- (void)drawRect:(NSRect)dirty {
    if (_card) {
        NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5) xRadius:8
                                                              yRadius:8];
        [SPDFCollectionColor(@"window") setFill];
        [shape fill];
        [SPDFCollectionColor(@"line") setStroke];
        [shape stroke];
    }
    [super drawRect:dirty];
}

- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }

@end
