// Shenzhen Friends views tests: a host with the optional parts, the `/` assistant and a Markdown renderer.
//
// The renderer is the test's stand-in for the host's engine (Friends never links the app's): enough Markdown at chat
// scale (13 pt text, 12 pt code, headings 17/15/13 pt) to exercise and show how bubbles lay out what a host returns.

#import "SZFriendsViewsTestSupport.h"

@interface SZFTestAssistantTask : NSObject <SZFriendsAssistantTask>
@property(nonatomic, weak) SZFTestAssistant *owner;
@end

@implementation SZFTestAssistantTask
- (void)cancel {
    self.owner.cancels += 1;
}
@end

@implementation SZFTestAssistant
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _calls = [NSMutableArray array];
    return self;
}
- (NSString *)commandLabel {
    return @"Ask the assistant";
}
- (NSString *)commandPlaceholder {
    return @"Draft a reply or summarize a document";
}
- (BOOL)respondsToSelector:(SEL)selector {
    if (self.plain && (selector == @selector(commandNote) || selector == @selector(proposalEditLabel) ||
                       selector == @selector(proposalSendingStatus)))
        return NO;
    return [super respondsToSelector:selector];
}
- (NSString *)commandNote {
    return @"With this command, the assistant may read this chat and your documents. What it reads goes to "
           @"OpenRouter, with no training and nothing kept.";
}
- (NSString *)proposalEditLabel {
    return @"Edit";
}
- (NSString *)proposalSendingStatus {
    return @"Sending…";
}
- (id<SZFriendsAssistantTask>)runCommand:(NSString *)command conversationID:(NSString *)conversationID
                             attachments:(NSArray<SZFriendsAttachableItem *> *)attachments
                                progress:(void (^)(NSString *))progress
                              completion:(void (^)(SZFriendsAssistantResult *, NSError *))completion {
    [self.calls addObject:@{@"command" : command, @"conversation_id" : conversationID, @"attachments" : attachments}];
    self.progress = progress;
    self.completion = completion;
    SZFTestAssistantTask *task = [SZFTestAssistantTask new];
    task.owner = self;
    return task;
}
@end

@implementation SZFTestProposal
@end

SZFTestProposal *SZFTestProposalWithText(NSString *text, NSArray<SZFriendsAttachableItem *> *attachments) {
    SZFTestProposal *proposal = [SZFTestProposal new];
    SZFriendsAssistantResult *result = [SZFriendsAssistantResult new];
    result.outcome = SZFriendsAssistantOutcomeProposed;
    result.text = text;
    result.attachments = attachments;
    result.note = @"Not sent yet. Check it, then press Send.";
    __weak SZFTestProposal *weak = proposal;
    result.send = ^(void (^done)(NSError *)) {
        weak.sends += 1;
        weak.done = done;
    };
    proposal.result = result;
    return proposal;
}

void SZFTestAnswerProposal(SZFTestProposal *proposal, NSError *error) {
    void (^done)(NSError *) = proposal.done;
    SZFExpect(done != nil, @"the views called send before the host answers it");
    if (done) done(error);
}

@implementation SZFTestAssistantHost {
    BOOL _inPass;
    NSUInteger _passRenders;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _renders = [NSMutableArray array];
    _renderedSources = [NSMutableArray array];
    _passBudget = NSUIntegerMax;
    return self;
}
- (void)friendsBeginMarkdownPass {
    if (_inPass) self.nestedPass = YES;
    _inPass = YES;
    _passRenders = 0;
    self.passBegins += 1;
}
- (void)friendsEndMarkdownPass {
    _inPass = NO;
    self.passEnds += 1;
}
- (id<SZFriendsAssistant>)friendsAssistant {
    return self.assistant;
}
- (NSAttributedString *)friendsRenderMarkdown:(NSString *)markdown width:(CGFloat)width
                                   appearance:(NSAppearance *)appearance {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    [self.renders addObject:[NSString stringWithFormat:@"%.0f|%d", width, dark]];
    if (!_inPass) self.rendersOutsidePass += 1;
    if (self.refusesMarkdown || (_inPass && _passRenders >= self.passBudget)) return nil;
    if (_inPass) _passRenders += 1;
    [self.renderedSources addObject:markdown];
    if (self.renderCost > 0) [NSThread sleepForTimeInterval:self.renderCost];
    return self.renderer ? self.renderer(markdown, width) : SZFTestRenderMarkdown(markdown, width, dark);
}
@end

#pragma mark - The stand-in renderer

static NSColor *SZFRGB(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0 alpha:1];
}

typedef struct {
    NSColor *text, *secondary, *link, *code, *grid, *header, *box;
} SZFPalette;

static SZFPalette SZFPaletteFor(BOOL dark) {
    // Concrete colours per appearance, as the contract asks (the bubble asks again when it changes).
    return dark ? (SZFPalette){SZFRGB(0xeceef1), SZFRGB(0xb3b7be), SZFRGB(0xa1c9ed), SZFRGB(0x1f2023),
                               SZFRGB(0x55595f), SZFRGB(0x33363a), SZFRGB(0x2c3a55)}
                : (SZFPalette){SZFRGB(0x26282b), SZFRGB(0x61666d), SZFRGB(0x286398), SZFRGB(0xf1f2f3),
                               SZFRGB(0xc9cdd2), SZFRGB(0xf6f8fa), SZFRGB(0xdbe7f5)};
}

static NSTextAttachment *SZFImageAttachment(NSSize size, CGFloat baseline, BOOL (^draw)(NSRect rect)) {
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = [NSImage imageWithSize:size flipped:YES drawingHandler:draw];
    attachment.bounds = NSMakeRect(0, baseline, size.width, size.height);
    return attachment;
}

// A table at its natural width: header band, hairline grid, 12 pt cells.
static NSTextAttachment *SZFTable(NSArray<NSArray<NSString *> *> *rows, SZFPalette palette) {
    NSFont *font = [NSFont systemFontOfSize:12], *bold = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    NSUInteger columns = 0;
    for (NSArray *row in rows) columns = MAX(columns, row.count);
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    for (NSUInteger column = 0; column < columns; column++) {
        CGFloat width = 0;
        for (NSArray<NSString *> *row in rows)
            if (column < row.count)
                width = MAX(width, [row[column] sizeWithAttributes:@{NSFontAttributeName : bold}].width);
        [widths addObject:@(ceil(width) + 16)];
    }
    CGFloat total = 0;
    for (NSNumber *width in widths) total += width.doubleValue;
    NSSize size = NSMakeSize(total + 1, rows.count * 22 + 1);
    return SZFImageAttachment(size, 0, ^BOOL(NSRect rect) {
        (void)rect;
        [palette.header setFill];
        NSRectFill(NSMakeRect(0, 0, size.width, 22));
        [palette.grid setFill];
        for (NSUInteger row = 0; row <= rows.count; row++) NSRectFill(NSMakeRect(0, row * 22, size.width, 1));
        CGFloat x = 0;
        for (NSUInteger column = 0; column <= columns; column++) {
            NSRectFill(NSMakeRect(x, 0, 1, size.height));
            if (column < columns) x += widths[column].doubleValue;
        }
        for (NSUInteger row = 0; row < rows.count; row++) {
            x = 0;
            for (NSUInteger column = 0; column < columns; column++) {
                NSString *cell = column < rows[row].count ? rows[row][column] : @"";
                [cell drawAtPoint:NSMakePoint(x + 8, row * 22 + 4)
                   withAttributes:@{NSFontAttributeName : row ? font : bold, NSForegroundColorAttributeName :
                                                                             palette.text}];
                x += widths[column].doubleValue;
            }
        }
        return YES;
    });
}

// A left-to-right flowchart, one box per arrow-separated name, labels at 12 pt (never below 11).
static NSTextAttachment *SZFFlowchart(NSArray<NSString *> *names, SZFPalette palette) {
    NSFont *font = [NSFont systemFontOfSize:12];
    CGFloat boxWidth = 104, gap = 34;
    NSSize size = NSMakeSize(names.count * boxWidth + (names.count - 1) * gap + 2, 58);
    return SZFImageAttachment(size, 0, ^BOOL(NSRect rect) {
        (void)rect;
        for (NSUInteger index = 0; index < names.count; index++) {
            NSRect box = NSMakeRect(1 + index * (boxWidth + gap), 12, boxWidth, 34);
            NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6];
            [palette.box setFill];
            [shape fill];
            [palette.grid setStroke];
            [shape stroke];
            NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : palette.text};
            NSSize label = [names[index] sizeWithAttributes:attributes];
            [names[index] drawAtPoint:NSMakePoint(NSMidX(box) - label.width / 2, NSMidY(box) - label.height / 2)
                       withAttributes:attributes];
            if (index + 1 == names.count) continue;
            NSBezierPath *arrow = [NSBezierPath bezierPath];
            [arrow moveToPoint:NSMakePoint(NSMaxX(box) + 4, NSMidY(box))];
            [arrow lineToPoint:NSMakePoint(NSMaxX(box) + gap - 4, NSMidY(box))];
            [arrow moveToPoint:NSMakePoint(NSMaxX(box) + gap - 9, NSMidY(box) - 4)];
            [arrow lineToPoint:NSMakePoint(NSMaxX(box) + gap - 4, NSMidY(box))];
            [arrow lineToPoint:NSMakePoint(NSMaxX(box) + gap - 9, NSMidY(box) + 4)];
            [palette.secondary setStroke];
            arrow.lineWidth = 1.3;
            [arrow stroke];
        }
        return YES;
    });
}

// Inline math at text size on the text baseline.
static NSTextAttachment *SZFMath(NSString *tex, SZFPalette palette) {
    NSString *shown = [[tex stringByReplacingOccurrencesOfString:@"^2" withString:@"²"]
        stringByReplacingOccurrencesOfString:@"\\cdot" withString:@"·"];
    NSFont *font = [NSFont fontWithName:@"Times New Roman Italic" size:14] ?: [NSFont systemFontOfSize:13];
    NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : palette.text};
    NSSize size = [shown sizeWithAttributes:attributes];
    size = NSMakeSize(ceil(size.width) + 2, ceil(font.ascender - font.descender));
    return SZFImageAttachment(size, floor(font.descender), ^BOOL(NSRect rect) {
        (void)rect;
        [shown drawAtPoint:NSMakePoint(1, 0) withAttributes:attributes];
        return YES;
    });
}

static NSAttributedString *SZFInline(NSString *line, NSDictionary *base, SZFPalette palette) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSFont *font = base[NSFontAttributeName];
    NSScanner *scanner = [NSScanner scannerWithString:line];
    scanner.charactersToBeSkipped = nil;
    NSCharacterSet *marks = [NSCharacterSet characterSetWithCharactersInString:@"*`[$"];
    while (!scanner.isAtEnd) {
        NSString *plain = nil;
        if ([scanner scanUpToCharactersFromSet:marks intoString:&plain])
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:base]];
        if (scanner.isAtEnd) break;
        NSMutableDictionary *attributes = [base mutableCopy];
        NSString *inner = nil, *url = nil;
        NSUInteger start = scanner.scanLocation;
        if ([scanner scanString:@"**" intoString:NULL] && [scanner scanUpToString:@"**" intoString:&inner] &&
            [scanner scanString:@"**" intoString:NULL]) {
            attributes[NSFontAttributeName] = [NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold];
        } else if ((scanner.scanLocation = start, [scanner scanString:@"`" intoString:NULL]) &&
                   [scanner scanUpToString:@"`" intoString:&inner] && [scanner scanString:@"`" intoString:NULL]) {
            attributes[NSFontAttributeName] = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
            attributes[NSBackgroundColorAttributeName] = palette.code;
        } else if ((scanner.scanLocation = start, [scanner scanString:@"$" intoString:NULL]) &&
                   [scanner scanUpToString:@"$" intoString:&inner] && [scanner scanString:@"$" intoString:NULL]) {
            NSMutableDictionary *math = [base mutableCopy];
            math[NSAttachmentAttributeName] = SZFMath(inner, palette);
            math[SZFriendsMarkdownSourceAttributeName] = [NSString stringWithFormat:@"$%@$", inner];
            [out appendAttributedString:[[NSAttributedString alloc]
                                            initWithString:[NSString stringWithFormat:@"%C", (unichar)0xFFFC]
                                                attributes:math]];
            continue;
        } else if ((scanner.scanLocation = start, [scanner scanString:@"[" intoString:NULL]) &&
                   [scanner scanUpToString:@"](" intoString:&inner] && [scanner scanString:@"](" intoString:NULL] &&
                   [scanner scanUpToString:@")" intoString:&url] && [scanner scanString:@")" intoString:NULL]) {
            attributes[NSLinkAttributeName] = [NSURL URLWithString:url] ?: url;
            attributes[NSForegroundColorAttributeName] = palette.link;
        } else if ((scanner.scanLocation = start, [scanner scanString:@"*" intoString:NULL]) &&
                   [scanner scanUpToString:@"*" intoString:&inner] && [scanner scanString:@"*" intoString:NULL]) {
            attributes[NSFontAttributeName] = [NSFontManager.sharedFontManager convertFont:font
                                                                                toHaveTrait:NSItalicFontMask];
        } else {
            scanner.scanLocation = start + 1;
            inner = [line substringWithRange:NSMakeRange(start, 1)];
        }
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:inner ?: @"" attributes:attributes]];
    }
    return out;
}

NSAttributedString *SZFTestRenderMarkdown(NSString *markdown, CGFloat width, BOOL dark) {
    (void)width;
    SZFPalette palette = SZFPaletteFor(dark);
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSArray<NSString *> *lines = [markdown componentsSeparatedByString:@"\n"];
    NSMutableParagraphStyle *body = [NSMutableParagraphStyle new];
    body.paragraphSpacing = 6;
    NSDictionary *text = @{NSFontAttributeName : [NSFont systemFontOfSize:13],
                           NSForegroundColorAttributeName : palette.text, NSParagraphStyleAttributeName : body};
    NSString *const object = [NSString stringWithFormat:@"%C", (unichar)0xFFFC];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = lines[index];
        if (out.length) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:text]];
        if ([line hasPrefix:@"```"]) {
            NSString *language = [line substringFromIndex:3];
            NSMutableArray *code = [NSMutableArray array];
            while (++index < lines.count && ![lines[index] hasPrefix:@"```"]) [code addObject:lines[index]];
            NSString *source = [NSString stringWithFormat:@"%@\n%@\n```", line, [code componentsJoinedByString:@"\n"]];
            if ([language isEqualToString:@"mermaid"]) {
                NSString *chart = [code.lastObject stringByReplacingOccurrencesOfString:@" " withString:@""];
                NSArray *names = [chart componentsSeparatedByString:@"-->"];
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:object attributes:@{
                    NSAttachmentAttributeName : SZFFlowchart(names, palette), NSParagraphStyleAttributeName : body,
                    SZFriendsMarkdownSourceAttributeName : source}]];
                continue;
            }
            NSMutableParagraphStyle *block = [body mutableCopy];
            block.lineBreakMode = NSLineBreakByCharWrapping; // long code wraps in a bubble rather than clipping
            [out appendAttributedString:[[NSAttributedString alloc]
                                            initWithString:[code componentsJoinedByString:@"\n"]
                                                attributes:@{NSFontAttributeName : [NSFont
                                                                 monospacedSystemFontOfSize:12
                                                                                     weight:NSFontWeightRegular],
                                                             NSForegroundColorAttributeName : palette.text,
                                                             NSBackgroundColorAttributeName : palette.code,
                                                             NSParagraphStyleAttributeName : block}]];
            continue;
        }
        if ([line hasPrefix:@"|"]) {
            NSMutableArray *rows = [NSMutableArray array], *source = [NSMutableArray array];
            for (; index < lines.count && [lines[index] hasPrefix:@"|"]; index++) {
                [source addObject:lines[index]];
                if ([lines[index] rangeOfString:@"---"].location != NSNotFound) continue;
                NSMutableArray *cells = [NSMutableArray array];
                for (NSString *cell in [lines[index] componentsSeparatedByString:@"|"]) {
                    NSString *trimmed = [cell stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (trimmed.length) [cells addObject:trimmed];
                }
                [rows addObject:cells];
            }
            index--;
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:object attributes:@{
                NSAttachmentAttributeName : SZFTable(rows, palette), NSParagraphStyleAttributeName : body,
                SZFriendsMarkdownSourceAttributeName : [source componentsJoinedByString:@"\n"]}]];
            continue;
        }
        NSMutableDictionary *attributes = [text mutableCopy];
        NSString *content = line;
        NSArray<NSNumber *> *headings = @[ @17, @15, @13 ];
        for (NSUInteger level = 3; level >= 1; level--) {
            NSString *marker = [[@"" stringByPaddingToLength:level withString:@"#" startingAtIndex:0]
                stringByAppendingString:@" "];
            if (![line hasPrefix:marker]) continue;
            content = [line substringFromIndex:marker.length];
            attributes[NSFontAttributeName] = [NSFont systemFontOfSize:headings[level - 1].doubleValue
                                                                weight:NSFontWeightSemibold];
            break;
        }
        NSRange numbered = [line rangeOfString:@"^[0-9]+\\. " options:NSRegularExpressionSearch];
        if ([line hasPrefix:@"- "] || numbered.location != NSNotFound) {
            NSMutableParagraphStyle *item = [body mutableCopy];
            item.headIndent = 18;
            item.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:18 options:@{}] ];
            item.paragraphSpacing = 2;
            attributes[NSParagraphStyleAttributeName] = item;
            NSString *bullet = numbered.location != NSNotFound ? [line substringToIndex:numbered.length - 1] : @"•";
            content = [line substringFromIndex:numbered.location != NSNotFound ? numbered.length : 2];
            [out appendAttributedString:[[NSAttributedString alloc]
                                            initWithString:[bullet stringByAppendingString:@"\t"]
                                                attributes:attributes]];
        }
        [out appendAttributedString:SZFInline(content, attributes, palette)];
    }
    return out;
}
