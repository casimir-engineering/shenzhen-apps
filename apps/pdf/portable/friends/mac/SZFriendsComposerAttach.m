// SZFriendsComposerView's attachment pickers: Attach files (the paperclip and the system's open panel) and Paste
// (Cmd+V). Both make chips, as a drop on the composer does; nothing is sent until Send. Files go from where they are,
// as dropped files do: the helper reads them when the message is sent, so a large file is never read here.

#import "mac/SZFriendsComposerInternal.h"

@implementation SZFriendsComposerView (SZFriendsAttach)

- (void)attachItems:(NSArray<SZFriendsAttachableItem *> *)items verdict:(SZFriendsDropVerdict)verdict {
    SZFriendsContext *context = self.composerContext;
    NSString *refusal = SZFriendsDropRefusalKey(verdict);
    if (refusal) {
        // As a drop says it: a folder or a link sends nothing, in the helper's words.
        [self showError:[context string:refusal]];
        [context announce:[context string:refusal]];
        return;
    }
    NSMutableArray<SZFriendsAttachableItem *> *fresh = [NSMutableArray array];
    NSArray<SZFriendsAttachableItem *> *attached = self.attachments;
    for (SZFriendsAttachableItem *item in items) {
        BOOL there = NO;
        for (SZFriendsAttachableItem *old in [attached arrayByAddingObjectsFromArray:fresh])
            there = there || (old.fileURL && [old.fileURL isEqual:item.fileURL]);
        if (!there) [fresh addObject:item];
    }
    [self showError:nil];
    if (fresh.count) [self addAttachments:fresh];
}

- (void)chooseFilesToAttach {
    SZFriendsContext *context = self.composerContext;
    if (!self.takesAttachments || !context.chooseFiles) return;
    __weak SZFriendsComposerView *weakSelf = self;
    context.chooseFiles(self.window, ^(NSArray<NSURL *> *files) {
        SZFriendsComposerView *composer = weakSelf;
        if (!composer || !files.count) return;
        SZFriendsDropVerdict verdict = SZFriendsDropVerdictNone;
        NSArray<SZFriendsAttachableItem *> *items = [SZFriendsDrops itemsForChosenFiles:files verdict:&verdict];
        [composer attachItems:items ?: @[] verdict:verdict];
        [composer.window makeFirstResponder:composer.textView];
    });
}

- (BOOL)canPasteAttachmentsFromPasteboard:(NSPasteboard *)pasteboard {
    return self.takesAttachments && [SZFriendsDrops pasteboardHoldsAttachments:pasteboard
                                                                          host:self.composerContext.host];
}

- (BOOL)pasteAttachmentsFromPasteboard:(NSPasteboard *)pasteboard {
    if (![self canPasteAttachmentsFromPasteboard:pasteboard]) return NO;
    SZFriendsContext *context = self.composerContext;
    SZFriendsDropVerdict verdict = [SZFriendsDrops pasteVerdictForPasteboard:pasteboard host:context.host];
    if (verdict == SZFriendsDropVerdictNone) return NO;
    if (verdict != SZFriendsDropVerdictAccept) {
        [self attachItems:@[] verdict:verdict];
        return YES;
    }
    __weak SZFriendsComposerView *weakSelf = self;
    [SZFriendsDrops readPastedItemsFromPasteboard:pasteboard host:context.host
                                 promiseDirectory:context.promiseDirectory
                                       completion:^(NSArray<SZFriendsAttachableItem *> *items) {
                                           [weakSelf attachItems:items verdict:SZFriendsDropVerdictAccept];
                                       }];
    return YES;
}

@end
