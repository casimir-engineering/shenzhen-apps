// Shenzhen Friends views tests: links and special files dragged in (PROTOCOL.md § Static strings, drop_not_a_file).
// Each file URL is classified without following links, as the GTK views do: a link to a folder is refused as a
// folder, any other link, FIFO, socket or device with drop_not_a_file, on rows, the conversation, the composer and
// the Friends button, before any intent. A row says the sentence only while the list above does not already say it.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static SZFTestDraggingInfo *SZFDragOfPaths(NSArray<NSString *> *paths) {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *path in paths) [urls addObject:[NSURL fileURLWithPath:path]];
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard writeObjects:urls];
    return [[SZFTestDraggingInfo alloc] initWithPasteboard:pasteboard];
}

static SZFriendsDropVerdict SZFVerdict(NSArray<NSString *> *paths) {
    return [SZFriendsDrops verdictForPasteboard:SZFDragOfPaths(paths).draggingPasteboard host:nil];
}

static BOOL SZFShows(NSView *root, NSString *text) {
    [root layoutSubtreeIfNeeded];
    for (NSTextField *field in SZFTestSubviews(root, NSTextField.class))
        if (!field.hidden && [field.stringValue isEqualToString:text]) return YES;
    return NO;
}

static NSString *SZFMakeSocket(NSString *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (fd < 0 || strlen(path.fileSystemRepresentation) >= sizeof address.sun_path) {
        if (fd >= 0) close(fd);
        return nil;
    }
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof address.sun_path);
    BOOL bound = bind(fd, (struct sockaddr *)&address, sizeof address) == 0;
    close(fd);
    return bound ? path : nil;
}

static void SZFTestVerdicts(NSString *directory, NSDictionary<NSString *, NSString *> *made) {
    SZFExpect(SZFVerdict(@[ made[@"file"] ]) == SZFriendsDropVerdictAccept, @"a regular file is accepted");
    SZFExpect(SZFVerdict(@[ made[@"missing"] ]) == SZFriendsDropVerdictAccept,
              @"a file that vanished is left to the helper's file_missing");
    SZFExpect(SZFVerdict(@[ made[@"folder"] ]) == SZFriendsDropVerdictRefuseFolder, @"a folder is a folder");
    SZFExpect(SZFVerdict(@[ made[@"folderLink"] ]) == SZFriendsDropVerdictRefuseFolder,
              @"a link to a folder is refused as a folder");
    for (NSString *kind in @[ @"fileLink", @"dangling", @"fifo", @"socket" ])
        if (made[kind])
            SZFExpect(SZFVerdict(@[ made[kind] ]) == SZFriendsDropVerdictRefuseNotAFile, @"%@ is not a file", kind);
    SZFExpect(made[@"socket"] != nil, @"a socket to drag in %@", directory);
    SZFExpect(SZFVerdict(@[ @"/dev/null" ]) == SZFriendsDropVerdictRefuseNotAFile, @"a device is not a file");
    SZFExpect(SZFVerdict(@[ made[@"file"], made[@"fileLink"] ]) == SZFriendsDropVerdictRefuseNotAFile,
              @"one link refuses the whole drop");
    SZFExpect(SZFVerdict(@[ made[@"fileLink"], made[@"folder"] ]) == SZFriendsDropVerdictRefuseFolder,
              @"with a folder too, the folder's words win");
    SZFExpect([SZFriendsDropRefusalKey(SZFriendsDropVerdictRefuseNotAFile) isEqualToString:@"drop_not_a_file"] &&
                  [SZFriendsDropRefusalKey(SZFriendsDropVerdictRefuseFolder) isEqualToString:@"drop_folders_refused"] &&
                  !SZFriendsDropRefusalKey(SZFriendsDropVerdictAccept),
              @"each refusal has its words");
    __block NSArray *read = nil;
    __block BOOL called = NO;
    [SZFriendsDrops readItemsFromPasteboard:SZFDragOfPaths(@[ made[@"fileLink"] ]).draggingPasteboard host:nil
                           promiseDirectory:directory
                                 completion:^(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder) {
                                     (void)refusedFolder;
                                     read = items;
                                     called = YES;
                                 }];
    SZFExpect(called && read.count == 0, @"a link resolves to nothing to send: %@", read);
}

// The refusal over an open conversation sits on a plate of its own: centred, opaque, so whatever message lies under it
// never shows through. Drawn straight over the list, it read as one more line of the conversation (UX verification,
// wave 6d). The same drag over a red and over a blue list: the plate's colour is the same, the list's around it not.
static void SZFTestRefusalPlate(SZFriendsContext *context, SZFTestDraggingInfo *link) {
    uint32_t inside[2] = {0, 0}, outside[2] = {0, 0};
    NSRect plates[2] = {NSZeroRect, NSZeroRect};
    NSArray<NSColor *> *under = @[ NSColor.systemRedColor, NSColor.systemBlueColor ];
    for (NSUInteger i = 0; i < under.count; i++) {
        SZFriendsMessageList *list = [[SZFriendsMessageList alloc] initWithContext:context];
        SZFriendsFlippedView *messages = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
        messages.fillColor = under[i];
        list.documentView = messages;
        list.acceptsDrops = YES;
        NSWindow *window = SZFTestHostWindow(list, NSMakeSize(400, 300), NSAppearanceNameAqua);
        [list draggingEntered:link];
        [list layoutSubtreeIfNeeded];
        (void)SZFTestBitmap(list); // draws once, which places the plate
        plates[i] = list.dropRefusalRect;
        // In the plate's padding, left of the words; and in the list between the plate and the outline.
        inside[i] = SZFTestPixelAt(list, NSMakePoint(NSMinX(plates[i]) + 5, NSMidY(plates[i])));
        outside[i] = SZFTestPixelAt(list, NSMakePoint(NSMidX(plates[i]), NSMinY(plates[i]) - 20));
        [list draggingExited:link];
        (void)window;
    }
    NSRect plate = plates[0];
    SZFExpect(NSWidth(plate) > 100 && NSHeight(plate) > 20 && fabs(NSMidX(plate) - 200) <= 1 &&
                  fabs(NSMidY(plate) - 150) <= 1,
              @"a plate centred in the list: %@", NSStringFromRect(plate));
    SZFExpect(SZFTestSameColor(inside[0], inside[1], 2), @"opaque: %06x over red, %06x over blue", inside[0],
              inside[1]);
    SZFExpect(!SZFTestSameColor(outside[0], outside[1], 30), @"while the list shows around it: %06x, %06x",
              outside[0], outside[1]);
}

static void SZFTestTargets(NSDictionary<NSString *, NSString *> *made) {
    SZFTestHost *host = [SZFTestHost new];
    SZFTestClock *clock = [SZFTestClock new];
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(NULL));
    SZFTestInstallClock(context, clock);
    NSString *notAFile = [context string:@"drop_not_a_file"], *folders = [context string:@"drop_folders_refused"];
    SZFExpect([notAFile isEqualToString:@"Links and special files can’t be sent. Drop the original file instead."],
              @"the helper's words: %@", notAFile);
    SZFTestDraggingInfo *link = SZFDragOfPaths(@[ made[@"fileLink"] ]), *fifo = SZFDragOfPaths(@[ made[@"fifo"] ]);

    // A friend's row: refused, with the sentence while the list above does not say it.
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:SZFTestSnapshot(@"list")];
    [page layoutSubtreeIfNeeded];
    SZFriendsRowView *mei = page.rows[1];
    SZFExpect(mei.dropLabel.length > 0, @"Mei takes files");
    SZFExpect([mei draggingEntered:link] == NSDragOperationNone && mei.dropHighlight == SZFriendsDropHighlightRefuse &&
                  [mei.dropPillText isEqualToString:notAFile],
              @"a link over a row: refused with drop_not_a_file (%@)", mei.dropPillText);
    SZFExpect(![mei prepareForDragOperation:link] && ![mei performDragOperation:link], @"and never taken");
    uint32_t warning = SZFTestResolved(context.appearance.warningColor, NSAppearanceNameAqua);
    NSPoint pillEdge = NSMakePoint(NSWidth(mei.bounds) - 12, NSMidY(mei.bounds));
    SZFExpect(SZFTestSameColor(SZFTestPixelAt(mei, pillEdge), warning, 12), @"the sentence's pill is drawn: %06x",
              SZFTestPixelAt(mei, pillEdge));
    [mei draggingExited:link];
    SZFExpect([mei draggingEntered:fifo] == NSDragOperationNone && [mei.dropPillText isEqualToString:notAFile],
              @"a FIFO too");
    [mei draggingExited:fifo];
    // Once the list above says why, the row shows only the refuse style (lead decision, both apps).
    [page setDropHint:notAFile refusing:YES];
    SZFExpect(mei.dropRefusalShownAbove && SZFShows(page, notAFile), @"the list says it above the rows");
    SZFExpect([mei draggingEntered:link] == NSDragOperationNone && mei.dropHighlight == SZFriendsDropHighlightRefuse &&
                  mei.dropPillText == nil,
              @"the row adds no sentence: %@", mei.dropPillText);
    SZFExpect(!SZFTestSameColor(SZFTestPixelAt(mei, pillEdge), warning, 12), @"and draws no pill: %06x",
              SZFTestPixelAt(mei, pillEdge));
    [mei draggingExited:link];
    [page setDropHint:[context string:@"drop_hint"]];
    SZFExpect(!mei.dropRefusalShownAbove, @"a hint that is not a refusal leaves the rows their words");
    [page setDropHint:nil];

    // The open conversation and the composer.
    SZFriendsMessageList *list = [[SZFriendsMessageList alloc] initWithContext:context];
    list.acceptsDrops = YES;
    SZFExpect([list draggingEntered:link] == NSDragOperationNone &&
              list.dropHighlight == SZFriendsDropHighlightRefuse &&
                  [list.dropRefusal isEqualToString:notAFile],
              @"the conversation says drop_not_a_file: %@", list.dropRefusal);
    [list draggingExited:link];
    SZFExpect([list draggingEntered:SZFDragOfPaths(@[ made[@"folderLink"] ])] == NSDragOperationNone &&
                  [list.dropRefusal isEqualToString:folders],
              @"and a folder's words for a link to a folder: %@", list.dropRefusal);
    [list draggingExited:link];
    SZFExpect(list.dropRefusal.length == 0, @"nothing once the drag leaves");
    SZFTestRefusalPlate(context, link);
    SZFriendsComposerView *composer = [[SZFriendsComposerView alloc] initWithContext:context conversationID:@"c_mei"];
    NSWindow *composerWindow = SZFTestHostWindow(composer, NSMakeSize(400, 140), NSAppearanceNameAqua);
    [composer applyComposer:SZFTestSnapshot(@"conversation-mei")[@"composer"]];
    SZFExpect([composer draggingEntered:link] == NSDragOperationNone && SZFShows(composer, notAFile) &&
                  [clock.spoken.lastObject hasSuffix:notAFile],
              @"the composer shows and speaks drop_not_a_file: %@", clock.spoken);
    [composer draggingExited:link];
    SZFExpect(!SZFShows(composer, notAFile), @"and clears it when the drag leaves");

    // The button springs the list open with the refusal above the rows, which then add no sentence.
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:SZFTestReadyLink(NULL)
                                                presenter:[SZFTestPresenter new]];
    SZFriendsTitleButton *button = (SZFriendsTitleButton *)controller.button;
    SZFExpect([button draggingEntered:link] == NSDragOperationNone, @"the button takes no link");
    [button springLoadingActivated:YES draggingInfo:link];
    [controller.content.listPage applySnapshot:SZFTestSnapshot(@"list")];
    SZFriendsRowView *springMei = controller.content.listPage.rows[1];
    SZFExpect(SZFShows(controller.content.listPage, notAFile) && springMei.dropRefusalShownAbove,
              @"spring-loaded on a link: drop_not_a_file above the rows");
    [springMei draggingEntered:link];
    SZFExpect(springMei.dropHighlight == SZFriendsDropHighlightRefuse && springMei.dropPillText == nil,
              @"the row under it shows only the refuse style");
    [springMei draggingExited:link];
    [button draggingExited:link];
    [controller close];
    (void)window, (void)composerWindow;
}

// Renders for review, light and dark: a link over Mei's row with nothing above the rows (the sentence wraps beside
// the name), the same once the list says it above (the refuse style only), and over the open conversation.
static void SZFRenderLinkDrags(NSString *linkPath) {
    for (NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        NSString *look = [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark";
        for (NSString *name in @[ @"list-drop-link", @"list-drop-link-above", @"conversation-drop-link" ]) {
            SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
            SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
            NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), appearance);
            [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
            SZFTestDraggingInfo *drag = SZFDragOfPaths(@[ linkPath ]);
            if ([name hasPrefix:@"conversation"]) {
                [content openConversation:@"c_mei" highlightMessage:nil];
                [content.topPage applySnapshot:SZFTestSnapshot(@"conversation-mei")];
                [((SZFriendsConversationPage *)content.topPage).messageList draggingEntered:drag];
            } else {
                if ([name hasSuffix:@"above"])
                    [content setDropHint:[context string:@"drop_not_a_file"] refusing:YES];
                [content.listPage.rows[1] draggingEntered:drag];
            }
            [content layoutSubtreeIfNeeded];
            NSString *file = [NSString stringWithFormat:@"%@-%@", name, look];
            SZFExpect(SZFTestRender(window.contentView, file, 2) != nil, @"render %@ written", file);
        }
    }
}

void SZFTestDropRefusals(void) {
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfv-links.XXXXXX"];
    char *buffer = strdup(pattern.fileSystemRepresentation);
    NSString *directory = buffer && mkdtemp(buffer) ? @(buffer) : nil;
    free(buffer);
    SZFExpect(directory != nil, @"a folder for the drags");
    if (!directory) return;
    NSMutableDictionary<NSString *, NSString *> *made = [NSMutableDictionary dictionary];
    for (NSString *name in @[ @"file", @"folder", @"fileLink", @"folderLink", @"dangling", @"fifo", @"missing" ])
        made[name] = [directory stringByAppendingPathComponent:name];
    [@"%PDF-1.4" writeToFile:made[@"file"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    mkdir(made[@"folder"].fileSystemRepresentation, 0700);
    symlink(made[@"file"].fileSystemRepresentation, made[@"fileLink"].fileSystemRepresentation);
    symlink(made[@"folder"].fileSystemRepresentation, made[@"folderLink"].fileSystemRepresentation);
    symlink(made[@"missing"].fileSystemRepresentation, made[@"dangling"].fileSystemRepresentation);
    mkfifo(made[@"fifo"].fileSystemRepresentation, 0600);
    NSString *socketPath = SZFMakeSocket([directory stringByAppendingPathComponent:@"s"]);
    if (socketPath) made[@"socket"] = socketPath;
    SZFTestVerdicts(directory, made);
    SZFTestTargets(made);
    SZFRenderLinkDrags(made[@"fileLink"]);
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}
