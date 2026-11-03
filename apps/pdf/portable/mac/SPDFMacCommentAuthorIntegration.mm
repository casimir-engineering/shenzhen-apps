// Your name on comments, changed from a byline (SPDFMacCommentAuthorName.h) or in Settings: stored as Settings stores
// it (commentAuthor in settings.yaml, empty for the Mac's name), then shown at once in the Comments panel, an open
// comment box and Settings, here and in the reader's other windows (a detached tab is a process of its own). Comments
// already written keep the name they were written with; only new ones carry the new name.

#import "SPDFMacCommentActions.h"
#import "SPDFMacCommentAuthorName.h"
#import "SPDFMacCommentEditor.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSupport.h"

#import <unistd.h>

// Posted to the reader's other processes, with the state folder it is about: test copies with a folder of their own
// never move the user's windows.
static NSString* const kAuthorChanged = @"ShenzhenPDFCommentAuthorChanged";

@interface ShenzhenMacDelegate (SPDFMacCommentAuthorHost)
- (SPDFMacCommentEditorView*)commentEditor;
- (id)stateObjectFromFile:(NSString*)name;
- (void)refreshCommentAuthorInSettings;
@end

@implementation ShenzhenMacDelegate (SPDFMacCommentAuthor)

+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification* note) {
                                                  (void)note;
                                                  id reader = NSApp.delegate;
                                                  if ([reader isKindOfClass:ShenzhenMacDelegate.class])
                                                      [(ShenzhenMacDelegate*)reader observeCommentAuthorChanges];
                                                }];
}

- (void)observeCommentAuthorChanges {
    __weak ShenzhenMacDelegate* weakSelf = self;
    [NSDistributedNotificationCenter.defaultCenter
        addObserverForName:kAuthorChanged
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                  ShenzhenMacDelegate* reader = weakSelf;
                  if (!reader || [note.userInfo[@"pid"] intValue] == getpid()) return;
                  if (![note.userInfo[@"state"] isEqual:spdf_mac_support_directory().stringByStandardizingPath]) return;
                  [reader reloadCommentAuthor];
                }];
}

// Another window changed it: read what it stored.
- (void)reloadCommentAuthor {
    NSDictionary* settings = [self stateObjectFromFile:@"settings.yaml"];
    id stored = [settings isKindOfClass:NSDictionary.class] ? settings[@"commentAuthor"] : nil;
    if (![stored isKindOfClass:NSString.class] || [stored isEqualToString:_commentAuthor ?: @""]) return;
    _commentAuthor = [stored copy];
    [self showCommentAuthor];
}

- (BOOL)changeCommentAuthorTo:(NSString*)name {
    NSString* author = SPDFCommentAuthorEditedName(name, [self currentCommentAuthor]);
    if (!author) return NO;
    [self rememberCommentAuthor:author];
    [self commentAuthorChanged];
    return YES;
}

- (void)commentAuthorChanged {
    [self showCommentAuthor];
    [NSDistributedNotificationCenter.defaultCenter
        postNotificationName:kAuthorChanged
                      object:nil
                    userInfo:@{@"pid" : @(getpid()), @"state" : spdf_mac_support_directory().stringByStandardizingPath ?: @""}
          deliverImmediately:YES];
}

// Every place the name shows: "your" cards are those under the new name now, a new comment's box shows it, and so
// does Settings.
- (void)showCommentAuthor {
    [self rebuildSidebar];
    SPDFMacCommentEditorView* editor = [self commentEditor];
    if (editor.isOpen && editor.changeAuthor) [editor showAuthor:[self currentCommentAuthor]];
    [self refreshCommentAuthorInSettings];
}

// A new comment's box: its byline is the name the comment will carry, and changing it there changes that name.
- (void)letCommentEditorChangeAuthor:(SPDFMacCommentEditorView*)editor {
    __weak ShenzhenMacDelegate* weakSelf = self;
    editor.changeAuthor = ^(NSString* name) {
      [weakSelf changeCommentAuthorTo:name];
    };
}

@end
