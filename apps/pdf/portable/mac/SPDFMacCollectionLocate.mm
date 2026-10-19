#import "SPDFMacCollectionWindow.h"
#import "SPDFMacCollectionStore.h"
@interface SPDFCollectionLocator : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property(nonatomic, copy) void (^onClose)(void);
@property(nonatomic) SPDFMacCollectionStore* store;
@property(nonatomic) NSString* documentID;
@property(nonatomic) NSString* missingPath;
@property(nonatomic, copy) void (^completion)(NSString*);
@property(nonatomic, copy) void (^preview)(NSString*);
@property(nonatomic) NSTableView* table;
@property(nonatomic) NSTextField* status;
@property(nonatomic) NSArray<NSDictionary*>* candidates;
@property(atomic) BOOL cancelled;
@property(atomic) NSUInteger searchGeneration;
@end
@implementation SPDFCollectionLocator
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return _candidates.count; }
- (id)tableView:(NSTableView*)table objectValueForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column; NSDictionary* candidate = _candidates[(NSUInteger)row];
    NSString* date = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[candidate[@"modifiedAt"] doubleValue]]
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    return [NSString stringWithFormat:@"%@\n%@ · %@ · %@", candidate[@"path"], date,
        [NSByteCountFormatter stringFromByteCount:[candidate[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile], self.documentID ? @"Exact content match" : @"Same filename — check before linking"];
}
- (void)windowWillClose:(NSNotification*)note { (void)note; self.cancelled = YES; if (_onClose) _onClose(); }
- (void)cancel:(id)sender { (void)sender; self.cancelled = YES; [self close]; }
- (void)linkPath:(NSString*)path allowMismatch:(BOOL)mismatch {
    if (!self.documentID) { self.cancelled=YES; self.completion(path); [self close]; return; }
    NSError* error = nil;
    if (![_store linkDocumentID:_documentID toPath:path allowMismatch:mismatch error:&error]) {
        [self.window presentError:error]; return;
    }
    self.cancelled = YES; _completion(path); [self close];
}
- (void)useSelected:(id)sender {
    (void)sender; NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_candidates.count) { NSBeep(); return; }
    [self linkPath:_candidates[(NSUInteger)row][@"path"] allowMismatch:NO];
}
- (void)previewSelected:(id)sender {
    (void)sender; NSInteger row = _table.selectedRow;
    if (row >= 0 && row < (NSInteger)_candidates.count) _preview(_candidates[(NSUInteger)row][@"path"]);
}
- (void)chooseManually:(id)sender {
    (void)sender; NSOpenPanel* panel = [NSOpenPanel openPanel]; panel.title = @"Locate the Original Document";
    panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        if (!self.documentID) { [self linkPath:panel.URL.path allowMismatch:NO]; return; }
        NSError* error = nil;
        if ([self.store linkDocumentID:self.documentID toPath:panel.URL.path allowMismatch:NO error:&error]) {
            self.completion(panel.URL.path); [self close]; return;
        }
        if (![error.domain isEqual:@"SPDFCollection"] || error.code != 12) { [self.window presentError:error]; return; }
        NSAlert* alert = [[NSAlert alloc] init]; alert.messageText = @"This file differs from the protected original";
        alert.informativeText = @"It is not an exact content match. Link this different revision to the existing history only if you recognize it as the same document.";
        [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:@"Link Different Revision"];
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse answer) {
            if (answer == NSAlertSecondButtonReturn) [self linkPath:panel.URL.path allowMismatch:YES];
        }];
    }];
}
- (void)search:(id)sender {
    (void)sender; NSUInteger generation = ++self.searchGeneration; self.cancelled = NO; _status.stringValue = @"Searching accessible files… Exact matches will be sorted oldest to newest. Cancel stops the search.";
    NSMutableArray<NSURL*>* roots = [NSMutableArray arrayWithObject:[NSURL fileURLWithPath:NSHomeDirectory()]];
    NSArray* volumes = [NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeIsLocalKey] options:0];
    for (NSURL* volume in volumes) {
        NSNumber* local = nil; [volume getResourceValue:&local forKey:NSURLVolumeIsLocalKey error:nil];
        if (local.boolValue && ![volume.path isEqual:@"/"] && ![volume.path hasPrefix:@"/System"]) [roots addObject:volume];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* error = nil;
        NSArray* candidates;
        if (self.documentID) candidates = [self.store locateCandidatesForDocumentID:self.documentID roots:roots
            cancelled:^BOOL { return self.cancelled || generation != self.searchGeneration; } error:&error];
        else {
            NSMutableArray* names=[NSMutableArray array]; NSUInteger checked=0;
            for (NSURL* root in roots) {
                NSDirectoryEnumerator* files=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLContentModificationDateKey,NSURLFileSizeKey]
                    options:NSDirectoryEnumerationSkipsHiddenFiles|NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
                for (NSURL* file in files) {
                    if (self.cancelled || generation!=self.searchGeneration || ++checked>500000) break;
                    if (![file.lastPathComponent isEqual:self.missingPath.lastPathComponent] || [self.store isArchivePath:file.path]) continue;
                    NSDictionary* values=[file resourceValuesForKeys:@[NSURLIsRegularFileKey,NSURLContentModificationDateKey,NSURLFileSizeKey] error:nil];
                    if ([values[NSURLIsRegularFileKey] boolValue]) [names addObject:@{@"path":file.path,@"size":values[NSURLFileSizeKey] ?: @0,
                        @"modifiedAt":@([values[NSURLContentModificationDateKey] timeIntervalSince1970])}];
                }
                if (self.cancelled || generation!=self.searchGeneration || checked>500000) break;
            }
            candidates=[names sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"modifiedAt" ascending:YES]]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelled || generation != self.searchGeneration) return;
            self.candidates = candidates ?: @[]; [self.table reloadData];
            if (!self.documentID) { self.status.stringValue=[NSString stringWithFormat:@"%lu filename candidates, oldest to newest. These are not verified content matches. Choose manually if the document was renamed.",(unsigned long)candidates.count]; return; }
            self.status.stringValue = [NSString stringWithFormat:@"%lu exact matches · oldest to newest. Protected hash is the latest saved version. Unavailable, private and unmounted locations were not searched.%@",
                (unsigned long)candidates.count, error ? [@"\n" stringByAppendingString:error.localizedDescription] : @""];
        });
    });
}
@end
void SPDFMacLocateCollectionOriginal(SPDFMacCollectionStore* store, NSString* documentID,
                                    NSWindow* parent, void (^preview)(NSString*), void (^completion)(NSString*)) {
    if (!documentID.length) return;
    static NSMutableArray* controllers;
    if (!controllers) controllers = [NSMutableArray array];
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 840, 490)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Locate Original"; window.releasedWhenClosed = NO;
    SPDFCollectionLocator* controller = [[SPDFCollectionLocator alloc] initWithWindow:window];
    controller.store = store; controller.documentID = documentID.isAbsolutePath ? nil : documentID; controller.missingPath=documentID.isAbsolutePath ? documentID : nil; controller.completion = completion; controller.preview = preview;
    controller.candidates = @[]; [controllers addObject:controller];
    window.delegate = controller;
    __weak SPDFCollectionLocator* weakController = controller;
    controller.onClose = ^{ if (weakController) [controllers removeObject:weakController]; };
    NSStackView* root = [NSStackView stackViewWithViews:@[]]; root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading; root.spacing = 12; root.frame = window.contentView.bounds;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; root.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
    [window.contentView addSubview:root];
    NSDictionary* reference = [store versionsForDocumentID:documentID].lastObject;
    NSString* date = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[reference[@"capturedAt"] doubleValue]]
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    controller.status = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:
        @"Find an exact match for the version protected %@. SHA-256: %@\nSearch accessible local files or choose manually. No result is linked automatically.", date, reference[@"hash"] ?: @"unavailable"]];
    if (!controller.documentID) controller.status.stringValue=@"Search accessible local files for the same filename, or choose a file manually. No saved content hash is available, so review candidates before choosing one.";
    [root addArrangedSubview:controller.status];
    NSScrollView* scroll = [[NSScrollView alloc] init]; scroll.hasVerticalScroller = YES;
    controller.table = [[NSTableView alloc] init]; controller.table.headerView = nil;
    controller.table.rowHeight = 44; controller.table.dataSource = controller; controller.table.delegate = controller;
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"match"]; column.width = 780;
    [controller.table addTableColumn:column]; scroll.documentView = controller.table; [root addArrangedSubview:scroll];
    [scroll.heightAnchor constraintEqualToConstant:300].active = YES;
    [scroll.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-36].active = YES;
    NSStackView* actions = [NSStackView stackViewWithViews:@[]]; actions.spacing = 8;
    NSArray* names = @[@"Search This Computer", @"Choose File Manually…", @"Preview", @"Use Selected File", @"Cancel"];
    NSArray* selectors = @[@"search:", @"chooseManually:", @"previewSelected:", @"useSelected:", @"cancel:"];
    for (NSUInteger i = 0; i < names.count; i++)
        [actions addArrangedSubview:[NSButton buttonWithTitle:names[i] target:controller action:NSSelectorFromString(selectors[i])]];
    [root addArrangedSubview:actions];
    if (parent) [window setFrameTopLeftPoint:NSMakePoint(NSMinX(parent.frame) + 40, NSMaxY(parent.frame) - 60)];
    [window makeKeyAndOrderFront:nil];
}
