// Shenzhen Friends views tests: list rows are reused by position, so a snapshot arriving mid-drag or mid-press can
// put someone else in the row under the pointer. The drop is refused and the click dropped; nothing reaches whoever
// arrived. Presses go through AppKit's own tracking (-mouseDown: runs until the release), with the snapshot applied
// from the main queue in between, as a snapshot from the helper arrives.

#import "SZFriendsViewsTestSupport.h"

// "Send 2 files to…" waiting: a click on a friend's row sends them there (SZFriendsListPage -rowPressed:).
@interface SZFPickerNavigator : SZFTestNavigator
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *files;
@end
@implementation SZFPickerNavigator
- (NSArray<NSDictionary *> *)pendingSendFiles {
    return self.files;
}
@end

static NSArray<NSDictionary *> *SZFSentIntents(SZFTestTransport *transport, NSString *type) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSDictionary *frame in transport.sent)
        if ([frame[@"type"] isEqualToString:type]) [found addObject:frame];
    return found;
}

// The list with the rows at `first` and `second` swapped.
static NSDictionary *SZFSwapped(NSDictionary *list, NSUInteger first, NSUInteger second) {
    NSMutableDictionary *data = [list mutableCopy];
    NSMutableArray *rows = [list[@"rows"] mutableCopy];
    [rows exchangeObjectAtIndex:first withObjectAtIndex:second];
    data[@"rows"] = rows;
    return data;
}

// A mouse press on `button` as AppKit tracks it: down, then `during` from the main queue while the button tracks,
// then the release, all at the button's centre.
static void SZFPressDuring(NSButton *button, void (^_Nullable during)(void)) {
    [button.window.contentView layoutSubtreeIfNeeded];
    NSPoint point = [button convertPoint:NSMakePoint(NSMidX(button.bounds), NSMidY(button.bounds)) toView:nil];
    NSInteger windowNumber = button.window.windowNumber;
    NSEvent * (^mouse)(NSEventType) = ^NSEvent *(NSEventType type) {
        return [NSEvent mouseEventWithType:type location:point modifierFlags:0
                                 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:windowNumber context:nil
                               eventNumber:0 clickCount:1 pressure:1];
    };
    __block BOOL released = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (during) during();
        released = YES;
        [NSApp postEvent:mouse(NSEventTypeLeftMouseUp) atStart:NO];
    });
    // Bounded: should the tracking loop never run the queue, a release from another thread ends it within 5 s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * (int64_t)NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                       if (!released) [NSApp postEvent:mouse(NSEventTypeLeftMouseUp) atStart:NO];
                   });
    [button mouseDown:mouse(NSEventTypeLeftMouseDown)];
    SZFExpect(released, @"the press was tracked until the release");
}

void SZFTestReusedRows(void) {
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-views-reuse.XXXXXX"];
    char *made = strdup(pattern.fileSystemRepresentation);
    NSString *folder = made && mkdtemp(made) ? @(made) : nil;
    free(made);
    SZFExpect(folder != nil, @"a folder for the dragged file");
    if (!folder) return;
    NSString *pdf = [folder stringByAppendingPathComponent:@"Supplier contract v3.pdf"];
    [@"%PDF-1.4" writeToFile:pdf atomically:YES encoding:NSUTF8StringEncoding error:nil];

    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFPickerNavigator *navigator = [SZFPickerNavigator new];
    context.navigator = navigator;
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    NSDictionary *list = SZFTestSnapshot(@"list"), *swapped = SZFSwapped(list, 1, 3); // Mei and Daniel
    [page applySnapshot:list];
    [page layoutSubtreeIfNeeded];
    SZFriendsRowView *row = page.rows[1];
    SZFExpect([row.conversationID isEqualToString:@"c_mei"], @"Mei's row: %@", row.conversationID);

    // A drag entered over Mei; Daniel moves into the row before the release.
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    [board clearContents];
    [board writeObjects:@[ [NSURL fileURLWithPath:pdf] ]];
    SZFTestDraggingInfo *drag = [[SZFTestDraggingInfo alloc] initWithPasteboard:board];
    SZFExpect([row draggingEntered:drag] == NSDragOperationCopy, @"Mei's row takes the file");
    [page applySnapshot:swapped];
    SZFExpect([row.conversationID isEqualToString:@"c_daniel"] && row.dropHighlight == SZFriendsDropHighlightNone &&
                  [row draggingUpdated:drag] == NSDragOperationNone,
              @"with Daniel moved under the drag, the row offers nothing: %@, highlight %ld", row.conversationID,
              (long)row.dropHighlight);
    SZFExpect(![row prepareForDragOperation:drag] && ![row performDragOperation:drag], @"and refuses the drop");
    [row draggingExited:drag];
    SZFTestSpin(0.05);
    SZFExpect(SZFSentIntents(transport, @"send_files").count == 0, @"nothing went to anyone");
    // Entered again, the row is Daniel's and takes the file for him.
    SZFExpect([row draggingEntered:drag] == NSDragOperationCopy && [row performDragOperation:drag],
              @"entered again, Daniel's row takes the file");
    [row concludeDragOperation:drag];
    NSArray *sent = SZFSentIntents(transport, @"send_files");
    SZFExpect(sent.count == 1 && [sent.lastObject[@"fields"][@"conversation_id"] isEqualToString:@"c_daniel"],
              @"sent to Daniel: %@", sent);

    // A click: the release opens whom the press began on, or nobody when someone else arrived meanwhile.
    [page applySnapshot:list];
    SZFPressDuring(row, nil);
    SZFExpect([navigator.opened isEqualToArray:@[ @"c_mei" ]], @"a press on Mei opens Mei: %@", navigator.opened);
    SZFPressDuring(row, ^{ [page applySnapshot:swapped]; });
    SZFExpect(navigator.opened.count == 1, @"a press Daniel moved under opens nobody: %@", navigator.opened);

    // The send picker: the files go to whom the press began on, or stay waiting.
    [page applySnapshot:list];
    navigator.files = @[ @{@"path" : pdf, @"display_name" : pdf.lastPathComponent} ];
    SZFPressDuring(row, ^{ [page applySnapshot:swapped]; });
    SZFExpect(SZFSentIntents(transport, @"send_files").count == 1 && navigator.opened.count == 1,
              @"no files sent to Daniel for a press that began on Mei: %@", SZFSentIntents(transport, @"send_files"));
    SZFPressDuring(row, nil);
    sent = SZFSentIntents(transport, @"send_files");
    SZFExpect(sent.count == 2 && [sent.lastObject[@"fields"][@"conversation_id"] isEqualToString:@"c_daniel"],
              @"a press on Daniel sends to Daniel: %@", sent);
    navigator.files = nil;

    // A request's Accept: another request with the same buttons takes Lena's row mid-press. The buttons stay (the
    // actions are unchanged), so the press continues on them, and the release must not accept the new person.
    [page applySnapshot:list];
    NSMutableDictionary *ken = [list[@"rows"][0] mutableCopy];
    ken[@"conversation_id"] = @"c_ken";
    ken[@"title"] = @"Ken Ito";
    NSMutableDictionary *withKen = [list mutableCopy];
    NSMutableArray *rows = [list[@"rows"] mutableCopy];
    rows[0] = ken;
    withKen[@"rows"] = rows;
    SZFriendsRowView *request = page.rows[0];
    SZFriendsRowActionButton *accept = request.actionsView.buttons.firstObject;
    SZFExpect([accept.rowAction[@"action"] isEqualToString:@"accept_request"], @"Accept: %@", accept.rowAction);
    SZFPressDuring(accept, ^{ [page applySnapshot:withKen]; });
    SZFExpect([request.conversationID isEqualToString:@"c_ken"] && request.actionsView.buttons.firstObject == accept,
              @"Ken's request in the row, on the same buttons");
    SZFExpect(SZFSentIntents(transport, @"accept_request").count == 0, @"Ken is not accepted by a press on Lena: %@",
              SZFSentIntents(transport, @"accept_request"));
    SZFPressDuring(accept, nil);
    NSArray *accepted = SZFSentIntents(transport, @"accept_request");
    SZFExpect(accepted.count == 1 && [accepted.lastObject[@"fields"][@"conversation_id"] isEqualToString:@"c_ken"],
              @"a press on Ken's Accept accepts Ken: %@", accepted);

    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    (void)window;
}
