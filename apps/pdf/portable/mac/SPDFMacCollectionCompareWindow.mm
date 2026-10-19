#import "SPDFMacCollectionCompareViews.h"

static PDFPage* blankPage(NSRect size, NSString* message) {
    NSMutableData* data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect box = size;
    CGContextRef context = CGPDFContextCreate(consumer, &box, NULL);
    CGDataConsumerRelease(consumer);
    CGPDFContextBeginPage(context, NULL);
    CGPDFContextEndPage(context);
    CGPDFContextClose(context);
    CGContextRelease(context);
    PDFPage* page = [[[PDFDocument alloc] initWithData:data] pageAtIndex:0];
    PDFAnnotation* label = [[PDFAnnotation alloc] initWithBounds:NSMakeRect(30,NSMidY(size),size.size.width-60,70)
                                                       forType:PDFAnnotationSubtypeFreeText withProperties:nil];
    label.contents = message;
    label.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    label.fontColor = NSColor.darkGrayColor;
    label.color = NSColor.clearColor;
    label.alignment = NSTextAlignmentCenter;
    [page addAnnotation:label];
    return page;
}

static void markPage(PDFPage* page, NSArray<NSValue*>* rects, BOOL removed) {
    NSColor* color = removed ? [NSColor colorWithSRGBRed:.87 green:.12 blue:.15 alpha:1]
                            : [NSColor colorWithSRGBRed:.05 green:.65 blue:.28 alpha:1];
    // These annotations exist only in a private PDFDocument. No save operation
    // is exposed, so comparison cannot mutate either archive or live source.
    for (PDFAnnotation* annotation in page.annotations) annotation.readOnly = YES;
    for (NSValue* value in rects) {
        PDFAnnotation* annotation = [[PDFAnnotation alloc] initWithBounds:value.rectValue
                                                                 forType:PDFAnnotationSubtypeSquare withProperties:nil];
        annotation.color = [color colorWithAlphaComponent:.8];
        annotation.interiorColor = [color colorWithAlphaComponent:.15];
        annotation.contents = removed ? @"Removed content" : @"Added content";
        annotation.readOnly = YES;
        PDFBorder* border = [PDFBorder new]; border.lineWidth = .7; annotation.border = border;
        [page addAnnotation:annotation];
    }
}

// Merge adjacent visual tiles and words into navigable change regions. The
// normalized vertical coordinate pairs corresponding edits after page reflow.
static NSArray<NSDictionary*>* changeRegions(SPDFCollectionPagePair* pair, PDFPage* oldPage, PDFPage* newPage,
                                             NSUInteger slot) {
    NSMutableArray* regions = [NSMutableArray array];
    for (NSUInteger side = 0; side < 2; side++) {
        PDFPage* page = side ? newPage : oldPage;
        NSRect box = [page boundsForBox:kPDFDisplayBoxMediaBox];
        for (NSValue* rectValue in (side ? pair.addedRects : pair.removedRects)) {
            NSRect rect = rectValue.rectValue;
            CGFloat top = (NSMaxY(box)-NSMaxY(rect))/MAX(1,box.size.height);
            CGFloat bottom = (NSMaxY(box)-NSMinY(rect))/MAX(1,box.size.height);
            [regions addObject:@{@"top":@(top),@"bottom":@(bottom),@"side":@(side)}];
        }
    }
    [regions sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"top"] compare:b[@"top"]];
    }];
    NSMutableArray* merged = [NSMutableArray array];
    NSMutableDictionary* current = nil;
    for (NSDictionary* region in regions) {
        CGFloat top = [region[@"top"] doubleValue];
        CGFloat bottom = [region[@"bottom"] doubleValue];
        if (!current || top > [current[@"bottom"] doubleValue]+.025) {
            current = [@{@"slot":@(slot),@"top":@(top),@"bottom":@(bottom)} mutableCopy];
            [merged addObject:current];
        }
        current[@"bottom"] = @(MAX(bottom,[current[@"bottom"] doubleValue]));
        NSString* key = [region[@"side"] boolValue] ? @"newTop" : @"oldTop";
        if (!current[key]) current[key] = @(top);
    }
    return merged;
}

// Preparation runs only after an explicit comparison request, on its worker
// queue. PDF serialization must not block the main thread for large versions.
static NSDictionary* preparePresentation(SPDFCollectionComparison* result) {
    if (!result) return nil;
    PDFDocument* oldAligned = [PDFDocument new];
    PDFDocument* newAligned = [PDFDocument new];
    NSMutableArray* removed = [NSMutableArray array];
    NSMutableArray* added = [NSMutableArray array];
    NSMutableArray* changed = [NSMutableArray array];
    NSMutableArray* oldIndices = [NSMutableArray array];
    NSMutableArray* newIndices = [NSMutableArray array];
    for (SPDFCollectionPagePair* pair in result.pairs) {
        NSUInteger slot = oldAligned.pageCount;
        PDFPage* oldPage = pair.oldIndex < 0 ? nil : [[result.oldDocument pageAtIndex:pair.oldIndex] copy];
        PDFPage* newPage = pair.newIndex < 0 ? nil : [[result.updatedDocument pageAtIndex:pair.newIndex] copy];
        NSRect size = [(oldPage ?: newPage) boundsForBox:kPDFDisplayBoxMediaBox];
        if (!oldPage) oldPage = blankPage(size,@"No old page\nPage added in the new version");
        if (!newPage) newPage = blankPage(size,@"No new page\nPage removed from the old version");
        markPage(oldPage,pair.removedRects,YES);
        markPage(newPage,pair.addedRects,NO);
        [oldAligned insertPage:oldPage atIndex:slot];
        [newAligned insertPage:newPage atIndex:slot];
        [oldIndices addObject:@(pair.oldIndex)]; [newIndices addObject:@(pair.newIndex)];
        for (NSDictionary* change in changeRegions(pair,oldPage,newPage,slot)) {
            if (change[@"oldTop"]) [removed addObject:@(slot+[change[@"oldTop"] doubleValue])];
            if (change[@"newTop"]) [added addObject:@(slot+[change[@"newTop"] doubleValue])];
            [changed addObject:change];
        }
    }
    // PDFPage.copy preserves the source CGPDFPageRef. Reparenting that page
    // into a new PDFDocument does not give PDFKit's tagged accessibility tree
    // a coherent document owner. Serialize the assembled pages, annotations
    // and blanks, then reopen independent backing documents before any PDFView
    // can query them. This preserves selectable text and vector content.
    NSData* oldData = oldAligned.dataRepresentation;
    NSData* newData = newAligned.dataRepresentation;
    oldAligned = oldData ? [[PDFDocument alloc] initWithData:oldData] : nil;
    newAligned = newData ? [[PDFDocument alloc] initWithData:newData] : nil;
    if (oldAligned.pageCount != result.pairs.count || newAligned.pageCount != result.pairs.count) {
        return nil;
    }
    return @{@"oldDocument":oldAligned,@"newDocument":newAligned,
        @"oldIndices":oldIndices,@"newIndices":newIndices,@"removed":removed,@"added":added,@"changes":changed};
}

@interface SPDFCollectionCompareController : NSWindowController <NSWindowDelegate>
- (void)loadOld:(NSURL*)oldURL new:(NSURL*)newURL;
@end

@implementation SPDFCollectionCompareController {
    SPDFCollectionComparePane* _oldPane;
    SPDFCollectionComparePane* _newPane;
    NSButton* _linked;
    NSTextField* _status;
    NSProgressIndicator* _spinner;
    NSProgress* _progress;
    NSOperationQueue* _queue;
    NSArray<NSDictionary*>* _changes;
    NSInteger _changeIndex;
    BOOL _synchronizing;
    id _keepAlive;
}
- (instancetype)initWithOldLabel:(NSString*)oldLabel newLabel:(NSString*)newLabel {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1200,820)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    window.title = @"Version Comparison — Read-only";
    window.minSize = NSMakeSize(980,520);
    window.delegate = self;
    window.releasedWhenClosed = NO;
    [window setFrameAutosaveName:@"CollectionComparisonWindow"];
    _keepAlive = self;
    _oldPane = [[SPDFCollectionComparePane alloc] initWithLabel:oldLabel removed:YES];
    _newPane = [[SPDFCollectionComparePane alloc] initWithLabel:newLabel removed:NO];
    _linked = [NSButton checkboxWithTitle:@"Link scrolling and zoom" target:self action:@selector(linkChanged:)];
    _linked.state = NSControlStateValueOn;
    NSButton* previous = [NSButton buttonWithTitle:@"Previous change" target:self action:@selector(previousChange:)];
    NSButton* next = [NSButton buttonWithTitle:@"Next change" target:self action:@selector(nextChange:)];
    _status = [NSTextField labelWithString:@"Preparing comparison…"];
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    [_spinner startAnimation:nil];
    NSStackView* toolbar = [NSStackView stackViewWithViews:@[previous,next,_linked,_spinner,_status]];
    toolbar.spacing = 12;
    NSBox* separator = [NSBox new]; separator.boxType = NSBoxSeparator;
    NSStackView* readers = [NSStackView stackViewWithViews:@[_oldPane,separator,_newPane]];
    readers.spacing = 0;
    readers.distribution = NSStackViewDistributionFill;
    readers.alignment = NSLayoutAttributeHeight;
    readers.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:toolbar];
    [window.contentView addSubview:readers];
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:14],
        [toolbar.trailingAnchor constraintLessThanOrEqualToAnchor:window.contentView.trailingAnchor constant:-14],
        [toolbar.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:10],
        [readers.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:8],
        [readers.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
        [readers.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
        [readers.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
        [_oldPane.widthAnchor constraintEqualToAnchor:_newPane.widthAnchor],
        [_oldPane.heightAnchor constraintEqualToAnchor:readers.heightAnchor],
        [_newPane.heightAnchor constraintEqualToAnchor:readers.heightAnchor],
        [separator.widthAnchor constraintEqualToConstant:1],
        [separator.heightAnchor constraintEqualToAnchor:readers.heightAnchor]]];
    __weak SPDFCollectionCompareController* weakSelf = self;
    for (SPDFCollectionComparePane* pane in @[_oldPane,_newPane]) {
        pane.navigationChanged = ^(SPDFCollectionComparePane* source) { [weakSelf synchronize:source zoom:NO]; };
        pane.zoomChanged = ^(SPDFCollectionComparePane* source) { [weakSelf synchronize:source zoom:YES]; };
        pane.rail.jump = ^(CGFloat position) { [weakSelf jumpToMarker:position]; };
    }
    _changeIndex = -1;
    return self;
}
- (void)loadOld:(NSURL*)oldURL new:(NSURL*)newURL {
    _progress = [NSProgress progressWithTotalUnitCount:1];
    _queue = [NSOperationQueue new];
    _queue.maxConcurrentOperationCount = 1;
    _queue.qualityOfService = NSQualityOfServiceUserInitiated;
    NSProgress* progress = _progress;
    __weak SPDFCollectionCompareController* weakSelf = self;
    [_queue addOperationWithBlock:^{
        @autoreleasepool {
            NSError* error = nil;
            SPDFCollectionComparison* result = SPDFCollectionBuildComparison(oldURL,newURL,progress,&error);
            if (progress.cancelled) return;
            NSDictionary* presentation = preparePresentation(result);
            if (result && !presentation) error = [NSError errorWithDomain:@"ShenzhenPDF.CollectionComparison" code:1
                userInfo:@{NSLocalizedDescriptionKey:@"Could not prepare the comparison readers."}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress.cancelled) return;
                [weakSelf complete:presentation error:error];
            });
        }
    }];
}
- (void)complete:(NSDictionary*)result error:(NSError*)error {
    [_spinner stopAnimation:nil];
    _spinner.hidden = YES;
    if (!result) {
        _status.stringValue = error.localizedDescription ?: @"Could not compare these documents.";
        _status.toolTip = _status.stringValue;
        return;
    }
    PDFDocument* oldAligned = result[@"oldDocument"];
    PDFDocument* newAligned = result[@"newDocument"];
    NSArray* oldIndices = result[@"oldIndices"];
    NSArray* newIndices = result[@"newIndices"];
    NSArray* removed = result[@"removed"];
    NSArray* added = result[@"added"];
    NSArray* changed = result[@"changes"];
    _synchronizing = YES;
    _oldPane.sourcePages = oldIndices; _newPane.sourcePages = newIndices;
    [_oldPane installDocument:oldAligned]; [_newPane installDocument:newAligned];
    _oldPane.rail.slots = removed; _newPane.rail.slots = added;
    _oldPane.rail.slotCount = oldAligned.pageCount; _newPane.rail.slotCount = newAligned.pageCount;
    _oldPane.rail.needsDisplay = YES; _newPane.rail.needsDisplay = YES;
    _changes = changed;
    _synchronizing = NO;
    _status.stringValue = changed.count ? [NSString stringWithFormat:@"%lu change regions",changed.count]
                                      : @"No visible changes";
    _status.toolTip = @"Red: removed text or visual regions. Green: added text or visual regions. Scans use visual regions.";
}
- (void)synchronize:(SPDFCollectionComparePane*)source zoom:(BOOL)zoom {
    if (_synchronizing || _linked.state != NSControlStateValueOn) return;
    SPDFCollectionComparePane* target = source == _oldPane ? _newPane : _oldPane;
    if (!source.reader.document || !target.reader.document) return;
    _synchronizing = YES;
    PDFDestination* current = source.navigationDestination;
    NSUInteger slot = [source.reader.document indexForPage:current.page];
    if (slot < target.reader.document.pageCount) {
        PDFPage* counterpart = [target.reader.document pageAtIndex:slot];
        NSRect from = [current.page boundsForBox:kPDFDisplayBoxMediaBox];
        NSRect to = [counterpart boundsForBox:kPDFDisplayBoxMediaBox];
        NSPoint point = NSMakePoint(to.origin.x+(current.point.x-from.origin.x)/MAX(1,from.size.width)*to.size.width,
                                   to.origin.y+(current.point.y-from.origin.y)/MAX(1,from.size.height)*to.size.height);
        [target applyLinkedDestination:[[PDFDestination alloc] initWithPage:counterpart atPoint:point]
                           scaleFactor:zoom ? source.reader.scaleFactor : 0];
    }
    _synchronizing = NO;
}
- (void)linkChanged:(id)sender { [self synchronize:_oldPane zoom:YES]; }
- (void)jumpToMarker:(CGFloat)position {
    CGFloat nearest = CGFLOAT_MAX;
    NSInteger index = -1;
    for (NSUInteger i = 0; i < _changes.count; i++) {
        NSDictionary* change = _changes[i];
        CGFloat delta = fabs([change[@"slot"] doubleValue]+[change[@"top"] doubleValue]-position);
        if (delta < nearest) { nearest = delta; index = i; }
    }
    if (index >= 0) { _changeIndex = index; [self showChange]; }
}
- (void)showChange {
    if (_changeIndex < 0 || _changeIndex >= (NSInteger)_changes.count) return;
    NSDictionary* change = _changes[_changeIndex];
    NSUInteger slot = [change[@"slot"] unsignedIntegerValue];
    _synchronizing = YES;
    for (NSUInteger side = 0; side < 2; side++) {
        SPDFCollectionComparePane* pane = side ? _newPane : _oldPane;
        PDFView* reader = pane.reader;
        PDFPage* page = [reader.document pageAtIndex:slot];
        NSRect box = [page boundsForBox:kPDFDisplayBoxMediaBox];
        CGFloat top = [(change[side ? @"newTop" : @"oldTop"] ?: change[@"top"]) doubleValue];
        NSPoint point = NSMakePoint(NSMinX(box),MIN(NSMaxY(box),NSMaxY(box)-top*box.size.height+24));
        [pane goToDestination:[[PDFDestination alloc] initWithPage:page atPoint:point]];
    }
    _synchronizing = NO;
    _status.stringValue = [NSString stringWithFormat:@"Change %ld of %lu · page pair %lu",_changeIndex+1,_changes.count,slot+1];
}
- (void)previousChange:(id)sender {
    if (!_changes.count) return;
    _changeIndex = (_changeIndex <= 0 ? _changes.count : _changeIndex)-1;
    [self showChange];
}
- (void)nextChange:(id)sender {
    if (!_changes.count) return;
    _changeIndex = (_changeIndex+1)%_changes.count;
    [self showChange];
}
- (void)windowWillClose:(NSNotification*)note {
    [_progress cancel]; [_queue cancelAllOperations];
    _oldPane.navigationChanged = nil; _newPane.navigationChanged = nil;
    _keepAlive = nil;
}
@end

void SPDFMacShowCollectionComparison(NSURL* oldURL, NSURL* newURL, NSString* oldLabel,
                                    NSString* newLabel, NSWindow* parent) {
    SPDFCollectionCompareController* controller = [[SPDFCollectionCompareController alloc]
        initWithOldLabel:oldLabel newLabel:newLabel];
    [controller.window center];
    if (parent) [parent addChildWindow:controller.window ordered:NSWindowAbove];
    [controller showWindow:nil];
    [controller.window makeKeyAndOrderFront:nil];
    [controller loadOld:oldURL new:newURL];
}
