#import "SPDFMacPaletteAppearance.h"
#import "SPDFMacCollectionStyle.h"

static BOOL TextMatch(NSDictionary* result) {
    return [result[@"query"] length] && [result[@"subtitle"] length];
}
CGFloat SPDFPaletteResultHeight(NSDictionary* result) {
    NSString* kind = result[@"kind"];
    if ([kind isEqual:@"separator"]) return 0;
    if ([kind isEqual:@"header"]) return 31;
    if ([kind isEqual:@"favorite"]) return 42;
    return TextMatch(result) ? 50 : 30;
}
static NSString* Metadata(NSDictionary* result) {
    NSString* kind = result[@"kind"];
    if ([kind isEqual:@"collectionGroup"]) return [NSString stringWithFormat:@"%@ documents",result[@"count"] ?: @0];
    if ([kind isEqual:@"openDoc"]) {
        // Where it lives, then its tab group unless that is the everyday General one.
        NSDictionary* group = [result[@"group"] isKindOfClass:NSDictionary.class] ? result[@"group"] : nil;
        NSString* name = [group[@"name"] length] ? group[@"name"]
                       : [group[@"id"] isEqual:@"general"] ? nil : group[@"color"];
        NSMutableArray* parts = [NSMutableArray array];
        for (NSString* part in @[result[@"location"] ?: @"", name ?: @""]) if (part.length) [parts addObject:part];
        return [parts componentsJoinedByString:@" \u00B7 "];
    }
    if ([kind isEqual:@"collectionDocument"])
        return TextMatch(result) ? @"Text match" : [result[@"location"] length] ? result[@"location"] : @"Collection";
    if ([kind isEqual:@"collectionOpenText"]) return @"Text match";
    return result[@"shortcut"] ?: result[@"subtitle"] ?: @"";
}
NSView* SPDFPaletteResultView(NSDictionary* result) {
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,526,SPDFPaletteResultHeight(result))];
    view.identifier = @"WorkspacePaletteResult";
    BOOL header = [result[@"kind"] isEqual:@"header"];
    NSTextField* title = SPDFCollectionText(header ? [result[@"title"] uppercaseString] : result[@"title"] ?: @"",
        header ? 10 : 13,NSFontWeightRegular,header || [result[@"kind"] isEqual:@"status"]);
    title.identifier = @"title"; title.translatesAutoresizingMaskIntoConstraints = NO;
    title.maximumNumberOfLines = 1; title.lineBreakMode = NSLineBreakByTruncatingMiddle; [view addSubview:title];
    // The full location is one hover away rather than squeezed into the title.
    NSString* path = [result[@"path"] isKindOfClass:NSString.class] ? result[@"path"] : @"";
    NSString* detail = path.length ? path.stringByAbbreviatingWithTildeInPath : result[@"subtitle"];
    view.toolTip = [@[result[@"title"] ?: @"",detail ?: @""] componentsJoinedByString:@"\n"];
    if (header) {
        [NSLayoutConstraint activateConstraints:@[[title.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:8],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:view.trailingAnchor constant:-8],
            [title.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-5]]];
        return view;
    }
    NSTextField* meta = SPDFCollectionText(Metadata(result),11,NSFontWeightRegular,YES);
    meta.identifier = @"metadata"; meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.maximumNumberOfLines = 1; meta.lineBreakMode = NSLineBreakByTruncatingMiddle;
    meta.alignment = NSTextAlignmentRight; [view addSubview:meta];
    [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[[title.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:8],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:meta.leadingAnchor constant:-12],
        [title.topAnchor constraintEqualToAnchor:view.topAnchor constant:6],
        [meta.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-8],
        [meta.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor multiplier:.35],
        [meta.centerYAnchor constraintEqualToAnchor:title.centerYAnchor]]];
    if (TextMatch(result)) {
        NSTextField* context = SPDFCollectionText(result[@"subtitle"],11,NSFontWeightRegular,YES);
        context.translatesAutoresizingMaskIntoConstraints = NO; context.maximumNumberOfLines = 1;
        context.lineBreakMode = NSLineBreakByTruncatingTail;
        NSMutableAttributedString* text = [context.attributedStringValue mutableCopy];
        NSString* query = result[@"query"]; NSRange remaining = NSMakeRange(0,text.length);
        while (remaining.length) {
            NSRange hit = [text.string rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch range:remaining];
            if (hit.location == NSNotFound || !hit.length) break;
            [text addAttribute:NSBackgroundColorAttributeName value:SPDFCollectionColor(@"highlight") range:hit];
            remaining = NSMakeRange(NSMaxRange(hit),text.length-NSMaxRange(hit));
        }
        context.attributedStringValue = text; [view addSubview:context];
        [NSLayoutConstraint activateConstraints:@[[context.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [context.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-8],
            [context.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3]]];
    }
    return view;
}
@interface SPDFWorkspacePaletteRow : NSTableRowView
@end
@implementation SPDFWorkspacePaletteRow
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect; [SPDFCollectionColor(@"selected") setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
}
@end
NSTableRowView* SPDFPaletteRowView(void) { return [SPDFWorkspacePaletteRow new]; }

NSView* SPDFPaletteContentView(NSSearchField* search,NSTableView* table,id target) {
    NSView* content = SPDFCollectionSurface(@"window");
    table.style = NSTableViewStylePlain;
    // Reuse the reader's inset-aware cell so static text, icon and field editor
    // keep the same baseline when focus moves into the borderless header.
    SPDFCollectionConfigureSearchField(search);
    search.editable = YES; search.selectable = YES;
    search.translatesAutoresizingMaskIntoConstraints = NO;
    search.font = [NSFont systemFontOfSize:13];
    search.bordered = NO; search.bezeled = NO; search.drawsBackground = NO;
    NSButton* close = SPDFCollectionButton(@"Esc",target,NSSelectorFromString(@"closePalette:"),@"quiet");
    close.identifier = @"PaletteClose"; close.accessibilityLabel = @"Close search (Escape)";
    close.toolTip = @"Close search (Escape)"; close.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:close]; [content addSubview:search];
    NSView* divider = SPDFCollectionDivider(); divider.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:divider];
    NSScrollView* scroll = [NSScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder; scroll.drawsBackground = NO;
    scroll.documentView = table; [content addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [search.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [search.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [search.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-66],
        [search.heightAnchor constraintEqualToConstant:30],
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:66],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [close.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [close.centerYAnchor constraintEqualToAnchor:search.centerYAnchor], [close.widthAnchor constraintEqualToConstant:42],
        [divider.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [divider.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [divider.topAnchor constraintEqualToAnchor:content.topAnchor constant:54]]];
    return content;
}
