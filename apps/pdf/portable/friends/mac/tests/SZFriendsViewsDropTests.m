// Shenzhen Friends views tests: drops on rows, the conversation, the composer and the button (file URLs, the host's
// tab type, file promises, folder refusal, spring-loading); the Settings section; the services for Cmd+K.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"

@interface SZFTestPromiseDelegate : NSObject <NSFilePromiseProviderDelegate>
@end
@implementation SZFTestPromiseDelegate
- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)fileType {
    (void)provider, (void)fileType;
    return @"promised.pdf";
}
- (void)filePromiseProvider:(NSFilePromiseProvider *)provider writePromiseToURL:(NSURL *)url
          completionHandler:(void (^)(NSError *))completionHandler {
    (void)provider;
    [@"%PDF-1.4" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    completionHandler(nil);
}
@end

static NSUInteger SZFSendFiles(SZFTestFakeHelper *fake, NSString *conversationID) {
    NSUInteger count = 0;
    for (NSDictionary *frame in [fake framesOfType:@"send_files"])
        if ([frame[@"conversation_id"] isEqualToString:conversationID]) count++;
    return count;
}

static SZFTestDraggingInfo *SZFDragOf(NSArray<id<NSPasteboardWriting>> *objects) {
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard writeObjects:objects];
    return [[SZFTestDraggingInfo alloc] initWithPasteboard:pasteboard];
}

void SZFTestDrops(NSString *stateDirectory) {
    setenv("SZFRIENDS_STATE_DIR", stateDirectory.fileSystemRepresentation, 1);
    SZFTestFakeHelper *fake = [[SZFTestFakeHelper alloc] initWithStateDirectory:stateDirectory];
    SZFExpect(fake != nil, @"fake helper started");
    if (!fake) return;
    NSString *files = [stateDirectory stringByAppendingPathComponent:@"files"];
    NSString *folder = [files stringByAppendingPathComponent:@"Site visit"];
    NSString *pdf = [files stringByAppendingPathComponent:@"Supplier contract v3.pdf"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
            error:nil];
    [@"%PDF-1.4" writeToFile:pdf atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSURL *pdfURL = [NSURL fileURLWithPath:pdf], *folderURL = [NSURL fileURLWithPath:folder isDirectory:YES];

    SZFTestHost *host = [SZFTestHost new];
    SZFriendsHelperLink *link = [[SZFriendsHelperLink alloc] initWithHost:host];
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:link presenter:[SZFTestPresenter new]];
    controller.context.promiseDirectory = [stateDirectory stringByAppendingPathComponent:@"promises"];
    [controller install];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return link.state == SZFriendsLinkStateReady; }), @"link ready");
    [controller toggle];
    SZFriendsDropdownContent *content = controller.content;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return content.listPage.rows.count == 7; }), @"rows");
    SZFriendsRowView *mei = content.listPage.rows[1], *lena = content.listPage.rows[0];

    // A file on a friend's row sends at once, one offer per file.
    SZFTestDraggingInfo *fileDrag = SZFDragOf(@[ pdfURL ]);
    SZFExpect([mei draggingEntered:fileDrag] == NSDragOperationCopy
            && mei.dropHighlight == SZFriendsDropHighlightAccept,
              @"row accepts a file URL");
    SZFExpect([mei performDragOperation:fileDrag], @"row takes the drop");
    [mei concludeDragOperation:fileDrag];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFSendFiles(fake, @"c_mei") == 1; }), @"send_files to Mei");
    NSDictionary *sent = [fake framesOfType:@"send_files"].lastObject;
    SZFExpect([sent[@"files"][0][@"path"] isEqualToString:pdf] && [sent[@"client_token"] length] >= 16,
              @"send_files fields: %@", sent);

    // Folders are refused while dragging, before any intent.
    SZFTestDraggingInfo *folderDrag = SZFDragOf(@[ folderURL ]);
    SZFExpect([mei draggingEntered:folderDrag] == NSDragOperationNone
            && mei.dropHighlight == SZFriendsDropHighlightRefuse,
              @"row refuses a folder");
    SZFExpect(![mei performDragOperation:folderDrag], @"folder drop not taken");
    [mei draggingExited:folderDrag];
    SZFExpect([SZFriendsDrops verdictForPasteboard:SZFDragOf(@[ pdfURL, folderURL ]).draggingPasteboard host:host] ==
                  SZFriendsDropVerdictRefuseFolder,
              @"one folder refuses the whole drop");
    // A pending request's row takes nothing.
    SZFExpect([lena draggingEntered:fileDrag] == NSDragOperationNone, @"request row refuses drops");

    // The host's own tab type carries the exact revision.
    NSPasteboard *tabBoard = [NSPasteboard pasteboardWithUniqueName];
    [tabBoard declareTypes:@[ SZFTestTabPasteboardType ] owner:nil];
    [tabBoard setString:pdf forType:SZFTestTabPasteboardType];
    SZFTestDraggingInfo *tabDrag = [[SZFTestDraggingInfo alloc] initWithPasteboard:tabBoard];
    SZFExpect([mei draggingEntered:tabDrag] == NSDragOperationCopy, @"row accepts a host tab");
    [mei performDragOperation:tabDrag];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFSendFiles(fake, @"c_mei") == 2; }), @"tab sent");
    NSDictionary *tabSent = [fake framesOfType:@"send_files"].lastObject;
    SZFExpect([tabSent[@"files"][0][@"revision"][@"revision_id"] isEqualToString:@"r_1"], @"revision bound: %@",
            tabSent);

    // File promises are accepted while dragging; a promised folder is refused. (Fulfilling a promise needs a real
    // drag session with the source app, so receiving runs on the hardware matrix.)
    SZFTestPromiseDelegate *promiseDelegate = [SZFTestPromiseDelegate new];
    NSFilePromiseProvider *promise = [[NSFilePromiseProvider alloc] initWithFileType:@"com.adobe.pdf"
                                                                            delegate:promiseDelegate];
    SZFTestDraggingInfo *promiseDrag = SZFDragOf(@[ promise ]);
    SZFExpect([mei draggingEntered:promiseDrag] == NSDragOperationCopy, @"row accepts a file promise");
    SZFExpect([SZFriendsDrops fileCountForPasteboard:promiseDrag.draggingPasteboard host:host] == 1,
            @"one promised file");
    [mei draggingExited:promiseDrag];
    NSFilePromiseProvider *folderPromise = [[NSFilePromiseProvider alloc] initWithFileType:@"public.folder"
                                                                                  delegate:promiseDelegate];
    SZFExpect([mei draggingEntered:SZFDragOf(@[ folderPromise ])] == NSDragOperationNone,
            @"a promised folder is refused");
    [mei draggingExited:fileDrag];

    // The open conversation sends; the composer only adds chips.
    [mei performClick:nil];
    SZFriendsConversationPage *page = (SZFriendsConversationPage *)content.topPage;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return page.itemViews.count == 6; }), @"conversation");
    SZFExpect([page.messageList draggingEntered:fileDrag] == NSDragOperationCopy, @"message list accepts");
    [page.messageList performDragOperation:fileDrag];
    [page.messageList concludeDragOperation:fileDrag];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFSendFiles(fake, @"c_mei") == 3; }), @"message list sends at once");
    SZFExpect([page.messageList draggingEntered:folderDrag] == NSDragOperationNone &&
                  page.messageList.dropHighlight == SZFriendsDropHighlightRefuse,
              @"message list refuses a folder");
    [page.messageList draggingExited:folderDrag];
    NSUInteger before = SZFSendFiles(fake, @"c_mei");
    SZFExpect([page.composer draggingEntered:fileDrag] == NSDragOperationCopy, @"composer accepts");
    [page.composer performDragOperation:fileDrag];
    [page.composer concludeDragOperation:fileDrag];
    SZFExpect(page.composer.attachments.count == 1 && page.composer.chipButtons.count == 1, @"composer added a chip");
    SZFExpect([page.composer draggingEntered:folderDrag] == NSDragOperationNone, @"composer refuses a folder");
    BOOL refusal = NO;
    for (NSTextField *field in SZFTestSubviews(page.composer, NSTextField.class))
        refusal = refusal || (!field.hidden && [field.stringValue isEqualToString:@"Folders can’t be sent yet"]);
    SZFExpect(refusal, @"composer says folders can't be sent yet");
    [page.composer draggingExited:folderDrag];
    SZFTestSpin(0.05);
    SZFExpect(SZFSendFiles(fake, @"c_mei") == before, @"chips send nothing yet");
    // `#` picks from the host's items into a chip, binding nothing until Send.
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = @"Supplier pricing.md";
    item.kindLabel = @"MD";
    item.fileURL = pdfURL;
    host.attachableItems = @[ item ];
    [page.composer.textView insertText:@"#" replacementRange:NSMakeRange(0, 0)];
    SZFExpect(page.attachPicker != nil, @"`#` opened the picker");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return page.attachPicker.items.count == 1; }), @"host items listed");
    SZFExpect([page.attachPicker.searchField.placeholderString isEqualToString:@"Search open and Collection documents"],
              @"host placeholder");
    [page.attachPicker chooseSelected];
    SZFExpect(page.attachPicker == nil && page.composer.attachments.count == 2, @"chip added, picker closed");
    SZFExpect(![page.composer.textView.string containsString:@"#"], @"the `#` became the chip");
    [page.composer removeAttachmentAtIndex:0];
    [page.composer removeAttachmentAtIndex:0];
    [content popToList];
    [controller close];

    // The button: spring-loading opens the list with the hint; a drop on it opens "Send 1 file to…".
    SZFriendsTitleButton *button = (SZFriendsTitleButton *)controller.button;
    SZFExpect([button draggingEntered:fileDrag] == NSDragOperationCopy
            && button.dropHighlight == SZFriendsDropHighlightAccept,
              @"button accepts files");
    SZFExpect([button springLoadingEntered:fileDrag] == NSSpringLoadingEnabled, @"button spring-loads");
    [button springLoadingActivated:YES draggingInfo:fileDrag];
    SZFExpect(controller.shown && controller.currentView == SZFriendsDropdownViewList,
            @"spring-loaded open on the list");
    BOOL hint = NO;
    for (NSTextField *field in SZFTestSubviews(content.listPage, NSTextField.class))
        hint = hint || (!field.hidden && [field.stringValue hasPrefix:@"Drop on a friend to send."]);
    SZFExpect(hint, @"drop hint shown while dragging");
    [button performDragOperation:fileDrag];
    [button concludeDragOperation:fileDrag];
    BOOL picker = NO;
    for (NSTextField *field in SZFTestSubviews(content.listPage, NSTextField.class))
        // "Send 1 file to…", or with the file's name from a helper that sends the named form.
        picker = picker || (!field.hidden && [field.stringValue hasPrefix:@"Send "] &&
                            [field.stringValue hasSuffix:@" to…"]);
    SZFExpect(picker, @"send picker title");
    NSUInteger toKenji = SZFSendFiles(fake, @"c_kenji");
    [content.listPage.rows[2] performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFSendFiles(fake, @"c_kenji") == toKenji + 1; }),
              @"the next friend clicked receives the file");
    SZFExpect(content.pendingSendFiles == nil, @"send picker finished");
    // Escape cancels a send picker before it closes anything.
    [controller beginSendPickerWithItems:@[ item ]];
    [content friendsHandleEscape];
    SZFExpect(content.pendingSendFiles == nil && controller.shown, @"Escape cancelled the send picker only");
    [controller close];
    host.vetoDrags = YES;
    SZFExpect([button draggingEntered:fileDrag] == NSDragOperationNone && [button springLoadingEntered:fileDrag] ==
                                                                              NSSpringLoadingDisabled,
              @"the host can veto a drag it is handling");
    host.vetoDrags = NO;
    [button draggingExited:fileDrag];
    [controller uninstall];
    [link stopDisablingFriends:NO];
    [fake stop];
}

void SZFTestSettingsAndServices(NSString *stateDirectory) {
    setenv("SZFRIENDS_STATE_DIR", stateDirectory.fileSystemRepresentation, 1);
    SZFTestFakeHelper *fake = [[SZFTestFakeHelper alloc] initWithStateDirectory:stateDirectory];
    SZFExpect(fake != nil, @"fake helper started");
    if (!fake) return;
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsHelperLink *link = [[SZFriendsHelperLink alloc] initWithHost:host];
    [link start];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return link.state == SZFriendsLinkStateReady; }), @"link ready");
    SZFriendsSettingsSection *section = [[SZFriendsSettingsSection alloc] initWithHost:host link:link];
    section.context.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    __block NSUInteger asked = 0;
    __block BOOL answer = NO;
    __block NSDictionary *question = nil;
    section.context.presentConfirmation = ^(NSDictionary *confirm, void (^onConfirm)(void)) {
        question = confirm;
        asked++;
        if (answer) onConfirm();
    };
    [section sectionWillAppear];
    SZFExpect(section.holdsSubscription, @"settings subscribed while on screen");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return [section.nameField.stringValue isEqualToString:@"Raph"]; }),
              @"settings rendered from the helper");
    [section.buttons[0] performClick:nil];
    SZFExpect([[section.context.pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"cottage-violet"],
              @"Copy copies the ID");
    [section.buttons[1] performClick:nil];
    SZFExpect([host.revealedFiles.lastObject.path hasSuffix:@"Shenzhen Friends/received"],
            @"Show in Finder via the host");
    [section.buttons[2] performClick:nil];
    [section.autoAcceptSwitches[2] performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  for (NSDictionary *f in [fake framesOfType:@"set_auto_accept"])
                      if ([f[@"conversation_id"] isEqualToString:@"c_kenji"] && [f[@"enabled"] boolValue]) return YES;
                  return NO;
              }), @"per-friend switch");
    [section.buttons[3] performClick:nil];
    SZFTestSpin(0.1);
    SZFExpect(asked == 1 && [fake framesOfType:@"delete_history"].count == 0, @"declined confirmation sends nothing");
    // The helper's question as it wrote it: what goes and what stays, for every chat.
    SZFExpect([question[@"body"] isEqualToString:@"Your messages and file history with every friend are deleted from "
                                                 @"this computer, and anything still waiting to go won’t be sent. You "
                                                 @"keep your friends, and they keep their own copies of your chats. "
                                                 @"Files you received stay in Received files."] &&
                  [question[@"title"] isEqualToString:@"Delete all conversation history?"],
              @"Delete history says what goes and what stays: %@", question);
    answer = YES;
    [section.buttons[3] performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return [fake framesOfType:@"delete_history"].count == 1; }),
            @"delete_history");
    SZFExpect([fake framesOfType:@"delete_history"].lastObject[@"conversation_id"] == nil,
            @"all history: no conversation");
    [section.buttons[4] performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return [[fake framesOfType:@"reset_friends"].lastObject[@"confirm"] isEqualToString:@"reset"];
              }), @"reset_friends carries confirm=reset");
    [section sectionDidDisappear];
    SZFExpect(!section.holdsSubscription, @"released when Settings closes");

    // Services: Cmd+K search through the helper, citations open the dropdown at the message.
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:link presenter:[SZFTestPresenter new]];
    [controller install];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return host.services != nil; }), @"services available");
    __block NSArray<SZFriendsSearchResult *> *results = nil;
    [host.services searchMessages:@"pages" limit:20
            completion:^(NSArray<SZFriendsSearchResult *> *found) { results = found; }];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return results != nil; }) && results.count == 2, @"two results");
    SZFExpect([results.firstObject.conversationTitle isEqualToString:@"Mei Lin"]
            && results.firstObject.excerpt.count == 3,
              @"result fields");
    [host.services showMessage:@"m_a4109f52" inConversation:@"c_mei"];
    SZFExpect(controller.shown && controller.currentView == SZFriendsDropdownViewConversation, @"citation opened");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  for (NSDictionary *f in [fake framesOfType:@"open_conversation"])
                      if ([f[@"message_id"] isEqualToString:@"m_a4109f52"]) return YES;
                  return NO;
              }), @"open_conversation with the message");
    __block NSError *scopeError = nil;
    [host.services openChatScopeForConversations:nil completion:^(id<SZFriendsChatScope> scope, NSError *error) {
        (void)scope;
        scopeError = error;
    }];
    SZFExpect([scopeError.userInfo[@"code"] isEqualToString:@"not_allowed"],
            @"no chat access without the host's claim");
    SZFExpect([fake framesOfType:@"assistant_open_scope"].count == 0, @"the helper was not even asked");

    // A link released while connected closes its connection and delivers nothing to the freed transport.
    size_t clients = szfriends_fake_helper_client_count(fake.fake);
    @autoreleasepool {
        SZFriendsHelperLink *transient = [[SZFriendsHelperLink alloc] initWithHost:host];
        [transient start];
        SZFExpect(SZFTestWaitUntil(10, ^BOOL { return transient.state == SZFriendsLinkStateReady; }), @"second link");
        [transient subscribeToView:@"badge" params:nil handler:^(NSDictionary *data, NSInteger rev) {
            (void)data, (void)rev;
        }];
    }
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return szfriends_fake_helper_client_count(fake.fake) == clients; }),
              @"released link disconnected");
    SZFTestSpin(0.1);
    // Friends turned off in this app: `disable` reaches the helper, and the link is idle at once.
    SZFriendsHelperLink *disabling = [[SZFriendsHelperLink alloc] initWithHost:host];
    [disabling start];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return disabling.state == SZFriendsLinkStateReady; }), @"third link");
    [disabling stopDisablingFriends:YES];
    SZFExpect(disabling.state == SZFriendsLinkStateIdle, @"idle after stop");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return [fake framesOfType:@"disable"].count == 1; }), @"disable sent");
    __block NSString *afterStop = nil;
    [disabling sendIntent:@"ping" fields:nil reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        (void)result;
        afterStop = error.code;
    }];
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return afterStop != nil; }) && [afterStop isEqualToString:@"not_ready"],
              @"nothing is sent after stop: %@", afterStop);
    [controller uninstall];
    [link stopDisablingFriends:NO];
    [fake stop];
}
