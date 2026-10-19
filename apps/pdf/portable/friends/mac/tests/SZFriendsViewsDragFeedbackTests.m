// Shenzhen Friends views tests: while files are on their way in, rows that cannot receive them fade and say why
// under the pointer; "Send … to…" names the files, lists them all in its tooltip and has Cancel; dragging a reader
// tab over the list never resolves (hashes) it before the drop; a refused folder is spoken; and a promised file's
// copy goes once the helper has answered the send.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"

static NSString *const SZFRefusal = @"Lena isn’t your friend yet";

static SZFriendsListPage *SZFListWithRefusal(SZFriendsContext *context, NSWindow **window) {
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
    NSMutableArray *rows = [data[@"rows"] mutableCopy];
    NSMutableDictionary *lena = [rows[0] mutableCopy];
    lena[@"drop_refusal"] = SZFRefusal;
    rows[0] = lena;
    data[@"rows"] = rows;
    [page applySnapshot:data];
    [page layoutSubtreeIfNeeded];
    return page;
}

static void SZFTestDimmingWhileDragging(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    NSWindow *window = nil;
    SZFriendsListPage *page = SZFListWithRefusal(context, &window);
    SZFriendsRowView *lena = page.rows[0], *mei = page.rows[1], *jonas = page.rows.lastObject;
    SZFExpect(!lena.dimmed && !jonas.dimmed, @"nothing fades before files come in");
    [page setDropHint:[context string:@"drop_hint"]];
    SZFExpect(lena.dimmed && jonas.dimmed && !mei.dimmed,
              @"with the drop hint up, the request and the blocked row fade (Lena %d, Jonas %d, Mei %d)", lena.dimmed,
              jonas.dimmed, mei.dimmed);
    SZFExpect(lena.refusalText == nil, @"no reason until the pointer is on the row");
    // Lena's waiting bar fades with her row: it marks something to answer, not a place to drop.
    NSPoint bar = NSMakePoint(NSMidX([lena waitingBarRect]), NSMidY([lena waitingBarRect]));
    uint32_t accent = SZFTestResolved(context.appearance.accentColor, NSAppearanceNameAqua);
    SZFExpect(!SZFTestSameColor(SZFTestPixelAt(lena, bar), accent, 10), @"the faded row's bar fades too: %06x",
              SZFTestPixelAt(lena, bar));
    lena.hovered = YES;
    SZFExpect([lena.refusalText isEqualToString:SZFRefusal], @"under the pointer it says why: %@", lena.refusalText);
    SZFExpect(jonas.refusalText == nil, @"a row without the helper's words only fades");
    // The reason is drawn at full strength over the faded row: the warning colour where the pill sits.
    uint32_t pill = SZFTestPixelAt(lena, NSMakePoint(NSWidth(lena.bounds) - 12, NSMidY(lena.bounds) - 8));
    uint32_t warning = SZFTestResolved(context.appearance.warningColor, NSAppearanceNameAqua);
    SZFExpect(SZFTestSameColor(pill, warning, 12), @"the refusal pill is not faded: %06x vs %06x", pill, warning);
    lena.hovered = NO;
    [page setDropHint:nil];
    SZFExpect(!lena.dimmed && !jonas.dimmed, @"and comes back when the drag ends");

    // During a real drag the row hears it (it registers even though it refuses) and says why, taking nothing.
    SZFExpect(lena.registeredDraggedTypes.count > 0, @"a refusing row with words listens to drags");
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    [board clearContents];
    [board writeObjects:@[ [NSURL fileURLWithPath:@"/tmp/Site photos.pdf"] ]];
    SZFTestDraggingInfo *drag = [[SZFTestDraggingInfo alloc] initWithPasteboard:board];
    SZFExpect([lena draggingEntered:drag] == NSDragOperationNone && [lena.refusalText isEqualToString:SZFRefusal],
              @"dragged over: refused, with the reason");
    SZFExpect(![lena performDragOperation:drag], @"and the drop is not taken");
    [lena draggingExited:drag];
    SZFExpect(lena.refusalText == nil, @"leaving clears it");
    (void)window;
}

static void SZFTestSendStrip(void) {
    // The welcome's strings plus the named forms (a helper that has them).
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableDictionary *strings = [welcome[@"strings"] mutableCopy];
    strings[@"drop_send_file"] = @"Send {name} to…";
    strings[@"drop_send_file_and_more"] = @"Send {name} and {count} more to…";
    welcome[@"strings"] = strings;
    [transport deliver:welcome];
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], link);
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
    NSArray *files = @[ @{@"path" : @"/tmp/a.pdf", @"display_name" : @"Site photos.pdf"},
                        @{@"path" : @"/tmp/Delivery dates.md"} ];
    [content beginSendPickerWithFiles:files];
    [content layoutSubtreeIfNeeded];
    BOOL named = NO;
    NSView *strip = nil;
    for (NSTextField *field in SZFTestSubviews(content.listPage, NSTextField.class))
        if (!field.hidden && [field.stringValue isEqualToString:@"Send Site photos.pdf and 1 more to…"]) {
            named = YES;
            strip = field.superview;
        }
    SZFExpect(named, @"the strip names the first file and counts the rest");
    SZFExpect([strip.toolTip isEqualToString:@"Site photos.pdf\nDelivery dates.md"], @"the tooltip lists them all: %@",
              strip.toolTip);
    SZFriendsButton *cancel = content.listPage.sendPickerCancelButton;
    SZFExpect([cancel.title isEqualToString:@"Cancel"] && SZFTestMissedHits(cancel, window.contentView) == 0,
              @"a Cancel link at the strip's edge");
    [cancel performClick:nil];
    SZFExpect(content.pendingSendFiles == nil && content.listPage.sendPickerCancelButton == nil,
              @"Cancel ends the picker");
    for (SZFriendsRowView *row in content.listPage.rows) SZFExpect(!row.dimmed, @"and no row stays faded");

    // One file: its name alone. A helper without the named forms: the count, never words of the views' own.
    SZFExpect([SZFriendsSendPickerTitle(context, @[ @"Site photos.pdf" ], 1) isEqualToString:
                                                                                @"Send Site photos.pdf to…"],
              @"one file named");
    // The welcome fixture now has the named forms; an older helper's welcome is that one without them.
    SZFTestTransport *olderTransport = nil;
    SZFriendsHelperLink *olderLink = SZFTestReadyLink(&olderTransport);
    NSMutableDictionary *olderWelcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableDictionary *olderStrings = [olderWelcome[@"strings"] mutableCopy];
    [olderStrings removeObjectsForKeys:@[ @"drop_send_file", @"drop_send_file_and_more" ]];
    olderWelcome[@"strings"] = olderStrings;
    [olderTransport deliver:olderWelcome];
    SZFriendsContext *older = SZFTestContext([SZFTestHost new], olderLink);
    SZFExpect([SZFriendsSendPickerTitle(older, @[ @"a.pdf", @"b.pdf" ], 2) isEqualToString:@"Send 2 files to…"],
              @"older helper: the count");
    (void)window;
}

static void SZFTestNoHashingWhileDragging(void) {
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFTestSnapshot(@"list")];
    NSPasteboard *tab = [NSPasteboard pasteboardWithUniqueName];
    [tab declareTypes:@[ SZFTestTabPasteboardType ] owner:nil];
    [tab setString:@"/tmp/Supplier contract v3.pdf" forType:SZFTestTabPasteboardType];
    SZFTestDraggingInfo *drag = [[SZFTestDraggingInfo alloc] initWithPasteboard:tab];
    SZFriendsRowView *mei = page.rows[1];
    SZFExpect([mei draggingEntered:drag] == NSDragOperationCopy && [mei draggingUpdated:drag] == NSDragOperationCopy,
              @"a reader tab is welcome while dragging");
    SZFExpect(host.itemsReads == 0, @"without resolving it (the reader hashes the file): %lu reads",
              (unsigned long)host.itemsReads);
    __block NSArray *sent = nil;
    mei.onDropItems = ^(SZFriendsRowView *row, NSString *conversationID, NSArray<SZFriendsAttachableItem *> *items) {
        (void)row, (void)conversationID;
        sent = items;
    };
    SZFExpect([mei performDragOperation:drag], @"the drop is taken");
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return sent != nil; }) && host.itemsReads >= 1 && sent.count == 1,
              @"and resolved once, on the drop: %lu reads", (unsigned long)host.itemsReads);
    (void)window;
}

// A folder dragged over the composer is refused out loud too: the refusal is spoken as it appears.
static void SZFTestFolderRefusalSpoken(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    SZFriendsComposerView *composer = [[SZFriendsComposerView alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *window = SZFTestHostWindow(composer, NSMakeSize(400, 140), NSAppearanceNameAqua);
    [composer applyComposer:SZFTestSnapshot(@"conversation-mei")[@"composer"]];
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-views-folder.XXXXXX"];
    char *path = strdup(pattern.fileSystemRepresentation);
    NSString *folder = path && mkdtemp(path) ? @(path) : nil;
    free(path);
    SZFExpect(folder != nil, @"a folder to drag");
    if (!folder) return;
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    [board clearContents];
    [board writeObjects:@[ [NSURL fileURLWithPath:folder isDirectory:YES] ]];
    SZFTestDraggingInfo *drag = [[SZFTestDraggingInfo alloc] initWithPasteboard:board];
    SZFExpect([composer draggingEntered:drag] == NSDragOperationNone, @"the composer refuses a folder");
    NSString *refusal = [context string:@"drop_folders_refused"];
    SZFExpect(refusal.length && clock.spoken.count == 1 && [clock.spoken.firstObject hasSuffix:refusal],
              @"and says so to VoiceOver: %@", clock.spoken);
    [composer draggingExited:drag];
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    (void)window;
}

// A promised file is sent from a copy the source cannot touch (SZFriendsPromiseCopies.h); once the helper has
// answered the send it holds its own, so the copy goes then instead of an hour later. A failed send keeps it.
static void SZFTestPromiseCopiesGoAfterSending(void) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFTestSnapshot(@"list")];
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-views-copies.XXXXXX"];
    char *path = strdup(pattern.fileSystemRepresentation);
    NSString *base = path && mkdtemp(path) ? @(path) : nil;
    free(path);
    if (!base) return;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString * (^copyFolder)(NSString *) = ^NSString *(NSString *name) {
        NSString *folder = [[base stringByAppendingPathComponent:@"Shenzhen Friends drops"]
            stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"copies"]];
        [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        [@"%PDF-1.4" writeToFile:[folder stringByAppendingPathComponent:@"report.pdf"] atomically:YES
                        encoding:NSUTF8StringEncoding error:nil];
        return folder;
    };
    SZFriendsAttachableItem * (^item)(NSString *) = ^SZFriendsAttachableItem *(NSString *folder) {
        SZFriendsAttachableItem *made = [SZFriendsAttachableItem new];
        made.title = @"report.pdf";
        made.fileURL = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"report.pdf"]];
        return made;
    };
    SZFriendsRowView *mei = page.rows[1];
    NSString *sent = copyFolder(@"A"), *failed = copyFolder(@"B");
    mei.onDropItems(mei, @"c_mei", @[ item(sent) ]);
    [transport deliver:@{@"type" : @"reply", @"re" : transport.sent.lastObject[@"id"], @"ok" : @YES,
                         @"result" : @{}}];
    mei.onDropItems(mei, @"c_mei", @[ item(failed) ]);
    [transport deliver:@{@"type" : @"reply", @"re" : transport.sent.lastObject[@"id"], @"ok" : @NO,
                         @"error" : @{@"code" : @"disk_full", @"message" : @"No space.", @"retryable" : @YES,
                                      @"details" : @{}}}];
    SZFExpect(SZFTestWaitUntil(5, ^BOOL { return ![files fileExistsAtPath:sent]; }),
              @"the sent copy is removed once the helper answered");
    SZFTestSpin(0.1);
    SZFExpect([files fileExistsAtPath:failed], @"a copy whose send failed stays for another try");
    [files removeItemAtPath:base error:nil];
    (void)window;
}

void SZFTestDragFeedback(void) {
    SZFTestFolderRefusalSpoken();
    SZFTestPromiseCopiesGoAfterSending();
    SZFTestDimmingWhileDragging();
    SZFTestSendStrip();
    SZFTestNoHashingWhileDragging();
}
