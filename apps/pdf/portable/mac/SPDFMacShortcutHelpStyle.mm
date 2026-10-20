#import "SPDFMacShortcutHelpStyle.h"
#import "SPDFKeycapLabel.h"

NSArray<NSDictionary*>* SPDFShortcutHelpCatalog(void) {
    return @[
        @{@"category":@"New!", @"highlighted":@YES, @"items":@[
            @{@"title":@"New document chat", @"subtitle":@"Press Command-K, then Return with the search field empty"},
            @{@"title":@"Send a chat message", @"subtitle":@"Shift-Return adds a new line", @"keys":@[@"Enter"]},
            @{@"title":@"Groups", @"subtitle":@"See your groups and their documents", @"keys":@[@"Cmd",@"G"]},
            @{@"title":@"Version history", @"keys":@[@"Cmd",@"H"]},
            @{@"title":@"Previous document", @"subtitle":@"Press again to return to this document", @"keys":@[@"Cmd",@"D"]},
            @{@"title":@"Open or close Friends", @"keys":@[@"Cmd",@"J"]}]},
        @{@"category":@"Search", @"items":@[
            @{@"title":@"Search this document", @"keys":@[@"Cmd",@"F"]},
            @{@"title":@"Search documents, groups and Collection", @"subtitle":@"Start with col: to search only Collection", @"keys":@[@"Cmd",@"K"]},
            @{@"title":@"Next result", @"keys":@[@"Enter"]},
            @{@"title":@"Previous result", @"keys":@[@"Cmd",@"Enter"]},
            @{@"title":@"Leave search and return to your panel", @"keys":@[@"Esc"]},
            @{@"title":@"Start searching while reading", @"subtitle":@"Just type when you are outside a text field"}]},
        @{@"category":@"Documents & tabs", @"items":@[
            @{@"title":@"Open a document", @"keys":@[@"Cmd",@"O"]},
            @{@"title":@"Open a file or folder by path", @"keys":@[@"Cmd",@"Shift",@"O"]},
            @{@"title":@"Previous or next tab", @"keys":@[@"Cmd",@"← / →"]},
            @{@"title":@"Reopen last closed document", @"keys":@[@"Cmd",@"Shift",@"T"]},
            @{@"title":@"Document properties", @"keys":@[@"Opt",@"I"]},
            @{@"title":@"Reorder, group or detach tabs", @"subtitle":@"Drag a tab; right-click for more options"}]},
        @{@"category":@"Pages", @"items":@[
            @{@"title":@"Go to a page", @"keys":@[@"Cmd",@"L"]},
            @{@"title":@"First or last page", @"keys":@[@"Opt",@"↑ / ↓"]},
            @{@"title":@"Previous or next page", @"subtitle":@"Always jumps a page", @"keys":@[@"Opt",@"← / →"]},
            @{@"title":@"Previous or next page", @"subtitle":@"Keeps zoom and position", @"keys":@[@"Cmd",@"↑ / ↓"]},
            @{@"title":@"Previous or next page", @"subtitle":@"Scrolls horizontally when zoomed wider", @"keys":@[@"← / →"]},
            @{@"title":@"Turn pages anywhere in the window", @"subtitle":@"Option + scroll wheel"},
            @{@"title":@"Jump a page", @"keys":@[@"Shift",@"Arrow"]},
            @{@"title":@"Scroll up or down", @"keys":@[@"↑ / ↓"]}]},
        @{@"category":@"Zoom & appearance", @"items":@[
            @{@"title":@"Zoom in or out", @"keys":@[@"Cmd",@"+ / −"]},
            @{@"title":@"Fit page", @"keys":@[@"Cmd",@"1"]},
            @{@"title":@"Fit width", @"keys":@[@"Cmd",@"2"]},
            @{@"title":@"Fit height", @"keys":@[@"Cmd",@"3"]},
            @{@"title":@"Actual size", @"keys":@[@"Cmd",@"4"]},
            @{@"title":@"Light or dark reading theme", @"keys":@[@"Cmd",@"I"]},
            @{@"title":@"Invert images with the page", @"subtitle":@"Off by default to preserve photographs", @"keys":@[@"Cmd",@"Shift",@"I"]},
            @{@"title":@"Rotate clockwise", @"keys":@[@"Cmd",@"R"]},
            @{@"title":@"Rotate anticlockwise", @"keys":@[@"Cmd",@"Shift",@"R"]},
            @{@"title":@"Presentation mode", @"subtitle":@"F5 also enters presentation mode", @"keys":@[@"Cmd",@"Shift",@"F"]},
            @{@"title":@"Leave presentation mode", @"keys":@[@"Esc"]}]},
        @{@"category":@"Favorites & panels", @"items":@[
            @{@"title":@"Favorite current page", @"keys":@[@"Cmd",@"B"]},
            @{@"title":@"Favorite current document", @"keys":@[@"Cmd",@"Shift",@"B"]},
            @{@"title":@"Show or hide the side panel", @"subtitle":@"Use the side-panel button or the View menu"},
            @{@"title":@"Show or hide the map", @"subtitle":@"Use the map button or the View menu"}]}];
}

NSArray<NSDictionary*>* SPDFShortcutHelpRows(NSString* query) {
    NSMutableArray* rows = [NSMutableArray array];
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    for (NSDictionary* section in SPDFShortcutHelpCatalog()) {
        NSMutableArray* matches = [NSMutableArray array];
        for (NSDictionary* item in section[@"items"]) {
            NSString* keys = [item[@"keys"] componentsJoinedByString:@" "] ?: @"";
            NSString* haystack = [NSString stringWithFormat:@"%@ %@ %@ %@", section[@"category"],item[@"title"],item[@"subtitle"] ?: @"",keys];
            haystack = [[haystack stringByReplacingOccurrencesOfString:@"Cmd" withString:@"Cmd Command ⌘"]
                stringByReplacingOccurrencesOfString:@"Opt" withString:@"Opt Option ⌥"];
            haystack = [[haystack stringByReplacingOccurrencesOfString:@"Shift" withString:@"Shift ⇧"]
                stringByReplacingOccurrencesOfString:@"Enter" withString:@"Enter Return ↩"];
            BOOL matched = YES;
            for (NSString* word in [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
                if (word.length && ![haystack.lowercaseString containsString:word]) { matched = NO; break; }
            if (matched) [matches addObject:item];
        }
        if (!matches.count) continue;
        NSNumber* highlighted = section[@"highlighted"] ?: @NO;
        [rows addObject:@{@"kind":@"header",@"title":section[@"category"],@"highlighted":highlighted}];
        for (NSDictionary* item in matches) {
            NSMutableDictionary* row = [item mutableCopy];
            row[@"kind"] = @"shortcut"; row[@"highlighted"] = highlighted;
            [rows addObject:row];
        }
    }
    if (!rows.count) [rows addObject:@{@"kind":@"empty",@"title":@"No matching shortcuts",@"subtitle":@"Try an action such as search, groups or zoom."}];
    return rows;
}

@interface SPDFShortcutSurface : NSView
@property BOOL highlighted;
@end
@implementation SPDFShortcutSurface
- (void)drawRect:(NSRect)rect {
    [NSColor.windowBackgroundColor setFill]; NSRectFill(rect);
    if (self.highlighted) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:.09] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,0,1) xRadius:6 yRadius:6] fill];
    }
}
@end
NSView* SPDFShortcutHelpSurface(NSRect frame) { return [[SPDFShortcutSurface alloc] initWithFrame:frame]; }

@interface SPDFShortcutKeycap : SPDFKeycapLabel
@end
@implementation SPDFShortcutKeycap
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:4 yRadius:4];
    [[NSColor.labelColor colorWithAlphaComponent:.055] setFill]; [path fill];
    [[NSColor.labelColor colorWithAlphaComponent:.12] setStroke]; [path stroke];
    [super drawRect:dirtyRect];
}
@end

NSView* SPDFShortcutHelpKeycaps(NSArray<NSString*>* keys) {
    NSStackView* stack = [NSStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY; stack.spacing = 4;
    if (!keys.count) [stack.widthAnchor constraintEqualToConstant:0].active = YES;
    NSDictionary* symbols = @{@"Cmd":@"⌘",@"Opt":@"⌥",@"Shift":@"⇧",@"Enter":@"↩",@"Esc":@"esc"};
    for (NSString* key in keys) {
        NSTextField* cap = [SPDFShortcutKeycap labelWithString:symbols[key] ?: key];
        cap.translatesAutoresizingMaskIntoConstraints = NO;
        cap.alignment = NSTextAlignmentCenter;
        cap.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; cap.textColor = NSColor.labelColor;
        cap.accessibilityLabel = key; cap.toolTip = key;
        [cap.widthAnchor constraintEqualToConstant:MAX(24,ceil(cap.intrinsicContentSize.width)+12)].active = YES;
        [cap.heightAnchor constraintEqualToConstant:24].active = YES;
        [stack addArrangedSubview:cap];
    }
    [stack setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [stack setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return stack;
}

CGFloat SPDFShortcutHelpRowHeight(NSDictionary* row) {
    if ([row[@"kind"] isEqual:@"header"]) return 36;
    return [row[@"subtitle"] length] ? 48 : 34;
}

NSView* SPDFShortcutHelpRowView(NSDictionary* row) {
    SPDFShortcutSurface* view = [[SPDFShortcutSurface alloc] initWithFrame:NSMakeRect(0,0,576,SPDFShortcutHelpRowHeight(row))];
    view.highlighted = [row[@"highlighted"] boolValue];
    BOOL header = [row[@"kind"] isEqual:@"header"];
    NSTextField* title = [NSTextField labelWithString:row[@"title"] ?: @""];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont systemFontOfSize:header ? 12 : 13 weight:header ? NSFontWeightSemibold : NSFontWeightRegular];
    title.textColor = header && view.highlighted ? NSColor.controlAccentColor : NSColor.labelColor;
    title.lineBreakMode = NSLineBreakByTruncatingTail; title.toolTip = row[@"title"];
    [view addSubview:title];
    [title.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:12].active = YES;
    if (header) {
        [title.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:view.highlighted ? 0 : 3].active = YES;
        return view;
    }
    NSArray* keys = row[@"keys"];
    NSView* caps = SPDFShortcutHelpKeycaps(keys);
    [view addSubview:caps];
    [NSLayoutConstraint activateConstraints:@[
        [caps.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-12],
        [caps.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:caps.leadingAnchor constant:-16]]];
    if (![row[@"subtitle"] length]) {
        [title.centerYAnchor constraintEqualToAnchor:view.centerYAnchor].active = YES;
    } else {
        NSTextField* subtitle = [NSTextField labelWithString:row[@"subtitle"]];
        subtitle.translatesAutoresizingMaskIntoConstraints = NO; subtitle.font = [NSFont systemFontOfSize:11];
        subtitle.textColor = NSColor.secondaryLabelColor; subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
        subtitle.toolTip = row[@"subtitle"]; [view addSubview:subtitle];
        [NSLayoutConstraint activateConstraints:@[
            [title.topAnchor constraintEqualToAnchor:view.topAnchor constant:7],
            [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
            [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:caps.leadingAnchor constant:-16]]];
    }
    return view;
}
