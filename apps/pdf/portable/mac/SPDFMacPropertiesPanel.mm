#import "SPDFMacPropertiesPanel.h"

#import "SPDFMacPassword.h"
#import "SPDFMacPropertiesFormat.h"
#import "SPDFMacPropertiesModel.h"

// Panel subclass so Escape and Cmd+W close the panel itself (Cmd+W would
// otherwise fall through to the File > Close menu item and close the active
// tab). sendEvent: catches Escape regardless of which field is first
// responder; performKeyEquivalent: runs before the main menu gets the event.
@interface SPDFPropertiesPanel : NSPanel
@end

@implementation SPDFPropertiesPanel

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (void)sendEvent:(NSEvent*)event {
    if (event.type == NSEventTypeKeyDown && event.keyCode == 53) {
        [self close];
        return;
    }
    [super sendEvent:event];
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers isEqualToString:@"w"]) {
        [self close];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end

// Flipped host for the scroll view so the grid pins to the top.
@interface SPDFPropertiesContentView : NSView
@end

@implementation SPDFPropertiesContentView

- (BOOL)isFlipped {
    return YES;
}

@end

static const CGFloat kPropertiesPanelWidth = 560.0;
static const CGFloat kPropertiesValueMaxWidth = 360.0;
static const CGFloat kPropertiesMaxScrollHeight = 520.0;

@interface SPDFPropertiesPanelController () <NSWindowDelegate>
@property(atomic) BOOL wordCountCancelled;
@end

@implementation SPDFPropertiesPanelController {
    NSPanel* _panel;
    // Section model driving both the grid and Copy All. Each section is
    // @{@"title", @"rows"}; each row is a mutable @{@"label", @"value"} plus
    // optional @"tooltip" and @"middleTruncate". The text-stats row is mutated
    // in place when the async count lands.
    NSArray<NSDictionary*>* _sections;
    NSMutableDictionary* _textStatsRow;
    NSTextField* _textStatsField;
    NSButton* _copyAllButton;
}

// Keeps controllers alive while their panel is visible (the delegate holds no
// reference; the panel is rebuilt fresh on every open).
static NSMutableSet<SPDFPropertiesPanelController*>* spdf_properties_visible_controllers(void) {
    static NSMutableSet* controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSMutableSet set]; });
    return controllers;
}

static NSString* spdf_properties_grouped(NSUInteger value) {
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    return [formatter stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%lu", (unsigned long)value];
}

+ (void)presentForDocument:(spdf_document*)doc
                sourcePath:(NSString*)sourcePath
               workingPath:(NSString*)workingPath
                 pageIndex:(NSInteger)pageIndex
              outlineCount:(NSInteger)outlineCount
           annotationCount:(NSInteger)annotationCount
                  textInfo:(NSDictionary*)textInfo
              parentWindow:(NSWindow*)parentWindow {
    if (!sourcePath.length) return;

    // One properties panel at a time: a fresh open replaces (and cancels) the
    // previous one so the panel always reflects the active tab at open time.
    for (SPDFPropertiesPanelController* controller in [spdf_properties_visible_controllers() copy])
        [controller close];

    SPDFPropertiesPanelController* controller = [[SPDFPropertiesPanelController alloc] init];
    controller->_sections = SPDFPropertiesSections(doc,sourcePath,workingPath,pageIndex,outlineCount,annotationCount,textInfo);
    for (NSDictionary* section in controller->_sections) for (NSMutableDictionary* row in section[@"rows"])
        if ([row[@"label"] isEqual:@"Text"]) controller->_textStatsRow = row;
    [controller buildPanelWithSourcePath:sourcePath parentWindow:parentWindow];
    [spdf_properties_visible_controllers() addObject:controller];
    [controller->_panel makeKeyAndOrderFront:nil];
    if (controller->_textStatsRow) {
        if (textInfo[@"text"]) [controller startWordCountForText:textInfo[@"text"]];
        else [controller startWordCountForPath:workingPath.length ? workingPath : sourcePath sourcePath:sourcePath];
    }
}

- (NSTextField*)valueFieldForRow:(NSDictionary*)row {
    NSString* value = row[@"value"] ?: @"";
    NSTextField* field;
    if ([row[@"middleTruncate"] boolValue]) {
        field = [NSTextField labelWithString:value];
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    } else {
        field = [NSTextField wrappingLabelWithString:value];
        field.preferredMaxLayoutWidth = kPropertiesValueMaxWidth;
        field.maximumNumberOfLines = [row[@"fullPath"] boolValue] ? 0 : 6;
        field.cell.truncatesLastVisibleLine = ![row[@"fullPath"] boolValue];
        if ([row[@"fullPath"] boolValue]) field.lineBreakMode = NSLineBreakByCharWrapping;
    }
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.selectable = YES;
    field.editable = NO;
    field.font = [NSFont systemFontOfSize:13];
    field.textColor = NSColor.labelColor;
    NSString* tooltip = row[@"tooltip"];
    field.toolTip = tooltip.length ? tooltip : nil;
    [field.widthAnchor constraintLessThanOrEqualToConstant:kPropertiesValueMaxWidth].active = YES;
    return field;
}

- (void)buildPanelWithSourcePath:(NSString*)sourcePath parentWindow:(NSWindow*)parentWindow {
    _panel = [[SPDFPropertiesPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, kPropertiesPanelWidth, 400)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _panel.title = @"Document Properties";
    _panel.releasedWhenClosed = NO;
    _panel.floatingPanel = YES;
    _panel.hidesOnDeactivate = YES;
    _panel.level = NSModalPanelWindowLevel;
    _panel.collectionBehavior =
        NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.delegate = self;

    NSView* content = [[NSView alloc] initWithFrame:NSZeroRect];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.contentView = content;

    // Header: file icon, display name, short format/size subtitle.
    NSImageView* iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = sourcePath.length ? [NSWorkspace.sharedWorkspace iconForFile:sourcePath]
                                       : [NSImage imageNamed:NSImageNameMultipleDocuments];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:iconView];

    NSString* displayName = sourcePath.lastPathComponent;
    if (!displayName.length) displayName = @"Untitled";
    NSTextField* nameField = [NSTextField labelWithString:displayName];
    nameField.translatesAutoresizingMaskIntoConstraints = NO;
    nameField.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    nameField.textColor = NSColor.labelColor;
    nameField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    nameField.selectable = YES;
    nameField.toolTip = sourcePath.length ? sourcePath : nil;
    [nameField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [content addSubview:nameField];

    NSTextField* subtitleField = [NSTextField labelWithString:[self headerSubtitle]];
    subtitleField.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleField.font = [NSFont systemFontOfSize:12];
    subtitleField.textColor = NSColor.secondaryLabelColor;
    [content addSubview:subtitleField];

    NSBox* headerSeparator = [[NSBox alloc] initWithFrame:NSZeroRect];
    headerSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    headerSeparator.boxType = NSBoxSeparator;
    [content addSubview:headerSeparator];

    // Sections grid inside a scroll view (tall metadata sets stay usable on
    // small screens).
    NSGridView* grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.rowSpacing = 5.0;
    grid.columnSpacing = 12.0;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    BOOL firstSection = YES;
    for (NSDictionary* section in _sections) {
        NSTextField* header = [NSTextField labelWithString:[section[@"title"] uppercaseString]];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        header.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        header.textColor = NSColor.secondaryLabelColor;
        NSGridRow* headerRow = [grid addRowWithViews:@[ header ]];
        [headerRow mergeCellsInRange:NSMakeRange(0, 2)];
        // The merged cell inherits the label column's trailing placement.
        [grid cellForView:header].xPlacement = NSGridCellPlacementLeading;
        headerRow.topPadding = firstSection ? 0.0 : 18.0;
        headerRow.bottomPadding = 2.0;
        firstSection = NO;

        for (NSDictionary* row in section[@"rows"]) {
            NSTextField* label = [NSTextField labelWithString:row[@"label"] ?: @""];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.font = [NSFont systemFontOfSize:13];
            label.textColor = NSColor.secondaryLabelColor;
            label.alignment = NSTextAlignmentRight;
            NSTextField* value = [self valueFieldForRow:row];
            if (row == _textStatsRow) _textStatsField = value;
            [grid addRowWithViews:@[ label, value ]];
        }
    }

    SPDFPropertiesContentView* gridHost = [[SPDFPropertiesContentView alloc] initWithFrame:NSZeroRect];
    gridHost.translatesAutoresizingMaskIntoConstraints = NO;
    [gridHost addSubview:grid];

    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.documentView = gridHost;
    [content addSubview:scrollView];

    NSBox* footerSeparator = [[NSBox alloc] initWithFrame:NSZeroRect];
    footerSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    footerSeparator.boxType = NSBoxSeparator;
    [content addSubview:footerSeparator];

    _copyAllButton = [NSButton buttonWithTitle:@"Copy All" target:self action:@selector(copyAll:)];
    _copyAllButton.translatesAutoresizingMaskIntoConstraints = NO;
    _copyAllButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:_copyAllButton];

    NSButton* doneButton = [NSButton buttonWithTitle:@"Done" target:self action:@selector(closePanel:)];
    doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    doneButton.bezelStyle = NSBezelStyleRounded;
    doneButton.keyEquivalent = @"\r";
    [content addSubview:doneButton];

    // Fit the panel to its content, capped so huge metadata scrolls.
    CGFloat gridHeight = grid.fittingSize.height;
    CGFloat scrollHeight = MIN(gridHeight + 4.0, kPropertiesMaxScrollHeight);

    [NSLayoutConstraint activateConstraints:@[
        [content.widthAnchor constraintEqualToConstant:kPropertiesPanelWidth],
        [iconView.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [iconView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
        [nameField.topAnchor constraintEqualToAnchor:content.topAnchor constant:19],
        [nameField.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [nameField.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-20],
        [subtitleField.topAnchor constraintEqualToAnchor:nameField.bottomAnchor constant:1],
        [subtitleField.leadingAnchor constraintEqualToAnchor:nameField.leadingAnchor],
        [subtitleField.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-20],
        [headerSeparator.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:14],
        [headerSeparator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [headerSeparator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:headerSeparator.bottomAnchor constant:14],
        [scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scrollView.heightAnchor constraintEqualToConstant:scrollHeight],
        [gridHost.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor],
        [grid.topAnchor constraintEqualToAnchor:gridHost.topAnchor],
        [grid.leadingAnchor constraintEqualToAnchor:gridHost.leadingAnchor constant:20],
        [grid.trailingAnchor constraintLessThanOrEqualToAnchor:gridHost.trailingAnchor constant:-20],
        [grid.bottomAnchor constraintEqualToAnchor:gridHost.bottomAnchor],
        [footerSeparator.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:12],
        [footerSeparator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footerSeparator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_copyAllButton.topAnchor constraintEqualToAnchor:footerSeparator.bottomAnchor constant:12],
        [_copyAllButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [_copyAllButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [doneButton.centerYAnchor constraintEqualToAnchor:_copyAllButton.centerYAnchor],
        [doneButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [doneButton.widthAnchor constraintGreaterThanOrEqualToConstant:76],
    ]];

    [content layoutSubtreeIfNeeded];
    [_panel setContentSize:content.fittingSize];

    if (parentWindow) {
        [parentWindow addChildWindow:_panel ordered:NSWindowAbove];
        NSRect windowFrame = parentWindow.frame;
        NSRect panelFrame = _panel.frame;
        panelFrame.origin.x = NSMidX(windowFrame) - NSWidth(panelFrame) * 0.5;
        panelFrame.origin.y = NSMidY(windowFrame) - NSHeight(panelFrame) * 0.5;
        [_panel setFrame:panelFrame display:NO];
    } else {
        [_panel center];
    }
}

- (NSString*)headerSubtitle {
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    for (NSDictionary* section in _sections) {
        if (![section[@"title"] isEqualToString:@"File"]) continue;
        for (NSDictionary* row in section[@"rows"]) {
            NSString* label = row[@"label"];
            if ([label isEqualToString:@"Format"]) [parts insertObject:row[@"value"] atIndex:0];
            if ([label isEqualToString:@"Size"]) {
                // "2.4 MB (2,437,120 bytes)" -> "2.4 MB" for the compact header.
                NSString* size = row[@"value"];
                NSRange parenthesis = [size rangeOfString:@" ("];
                if (parenthesis.location != NSNotFound) size = [size substringToIndex:parenthesis.location];
                [parts addObject:size];
            }
        }
    }
    for (NSDictionary* section in _sections) {
        if (![section[@"title"] isEqualToString:@"Statistics"]) continue;
        for (NSDictionary* row in section[@"rows"]) {
            if (![row[@"label"] isEqualToString:@"Pages"]) continue;
            NSString* pages = row[@"value"];
            [parts addObject:[pages isEqualToString:@"1"] ? @"1 page"
                                                          : [NSString stringWithFormat:@"%@ pages", pages]];
        }
    }
    return [parts componentsJoinedByString:@" · "];
}

// Word/character count runs on its own document instance opened from the
// working path (the core's one-thread-per-document contract), checking the
// cancellation flag between pages so closing the panel stops the walk quickly
// even on 1000-page documents.
- (void)startWordCountForPath:(NSString*)path sourcePath:(NSString*)sourcePath {
    if (!path.length || !sourcePath.length || !_textStatsField) {
        [self finishWordCountWithValue:@"Unavailable"];
        return;
    }
    __weak SPDFPropertiesPanelController* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      @autoreleasepool {
          char err[1024];
          spdf_document* doc = SPDFOpenDocumentWithStoredCredential(path, sourcePath, NULL, NULL, err, sizeof(err));
          if (!doc) {
              dispatch_async(dispatch_get_main_queue(),
                             ^{ [weakSelf finishWordCountWithValue:@"Unavailable"]; });
              return;
          }
          NSUInteger words = 0;
          NSUInteger chars = 0;
          BOOL cancelled = NO;
          NSInteger pageCount = spdf_page_count(doc);
          for (NSInteger page = 0; page < pageCount; ++page) {
              SPDFPropertiesPanelController* strongSelf = weakSelf;
              if (!strongSelf || strongSelf.wordCountCancelled) {
                  cancelled = YES;
                  break;
              }
              @autoreleasepool {
                  spdf_text_lines lines;
                  memset(&lines, 0, sizeof(lines));
                  if (spdf_extract_page_text_lines(doc, (int)page, &lines, err, sizeof(err))) {
                      for (int i = 0; i < lines.count; ++i) {
                          if (!lines.items[i].text) continue;
                          NSString* text = [NSString stringWithUTF8String:lines.items[i].text];
                          spdf_properties_count_text(text, &words, &chars);
                      }
                  }
                  spdf_free_text_lines(&lines);
              }
          }
          spdf_close(doc);
          if (cancelled) return;
          NSString* value = words == 0 && chars == 0
                                ? @"No text"
                                : [NSString stringWithFormat:@"%@ words · %@ characters",
                                                             spdf_properties_grouped(words),
                                                             spdf_properties_grouped(chars)];
          dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishWordCountWithValue:value]; });
      }
    });
}

- (void)startWordCountForText:(NSString*)text {
    NSString* snapshot = [text copy];
    __weak SPDFPropertiesPanelController* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        if (!weakSelf || weakSelf.wordCountCancelled) return;
        NSUInteger words = 0, characters = 0;
        spdf_properties_count_text(snapshot,&words,&characters);
        NSString* value = [NSString stringWithFormat:@"%@ words · %@ characters",
            spdf_properties_grouped(words),spdf_properties_grouped(characters)];
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishWordCountWithValue:value]; });
    });
}

- (void)finishWordCountWithValue:(NSString*)value {
    if (self.wordCountCancelled) return;
    _textStatsRow[@"value"] = value;
    _textStatsField.stringValue = value;
}

- (void)copyAll:(id)sender {
    (void)sender;
    NSMutableString* text = [NSMutableString string];
    for (NSDictionary* section in _sections) {
        if (text.length) [text appendString:@"\n"];
        [text appendFormat:@"%@\n", section[@"title"]];
        for (NSDictionary* row in section[@"rows"])
            [text appendFormat:@"  %@: %@\n", row[@"label"], row[@"value"]];
    }
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:text forType:NSPasteboardTypeString];

    _copyAllButton.title = @"Copied";
    __weak SPDFPropertiesPanelController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SPDFPropertiesPanelController* strongSelf = weakSelf;
      if (strongSelf) strongSelf->_copyAllButton.title = @"Copy All";
    });
}

- (void)closePanel:(id)sender {
    (void)sender;
    [self close];
}

- (void)close {
    [_panel close];
}

- (void)windowWillClose:(NSNotification*)notification {
    (void)notification;
    self.wordCountCancelled = YES;
    [_panel.parentWindow removeChildWindow:_panel];
    [spdf_properties_visible_controllers() removeObject:self];
}

@end
