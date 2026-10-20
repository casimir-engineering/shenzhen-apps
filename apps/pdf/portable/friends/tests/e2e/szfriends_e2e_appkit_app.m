// friends-one-identity-check: the app that plays ShenzhenPDF with the real AppKit Friends views.
//
// It hosts Friends as ShenzhenPDF does: at launch a background connect-or-spawn of the helper its bundle embeds
// (Contents/Helpers/Shenzhen Friends.app), then the real helper link, dropdown controller and its pages, with no state
// directory of its own, so the client library's default (the person's Friends home under $HOME) decides where the
// helper is. Nothing reaches the screen: the process is never made a foreground app (activation policy prohibited),
// and the dropdown's presenter puts its content in a borderless window that is never ordered in. The scenario copies
// this program into a test app bundle (ShenzhenPDF.app/Contents/MacOS/) and drives it over stdin and stdout, one JSON
// object per line, with the lines of szfriends_e2e_client_app.c plus the ones that work the real views:
//
//   {"cmd":"ui_type","conversation_id":..,"text":..,"tag":..}  opens the conversation in the dropdown, types the text
//                                                              into its composer and presses Return
//   {"cmd":"ui_texts","conversation_id":..,"tag":..}           the messages the conversation page shows, in order
//   {"cmd":"ui_list","tag":..}                                  the words the list page shows (rows and footer)
//   {"cmd":"profile"} {"cmd":"intent","type":..,"fields":..,"tag":..}
//
// Usage: szfriends-e2e-appkit-app <embedded helper executable> <helper version> <helper build number>

#import <AppKit/AppKit.h>

#import <libproc.h>
#import <sys/socket.h>
#import <sys/un.h>

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDropdownController.h"
#import "mac/SZFriendsDropdownInternal.h"
#import "mac/SZFriendsHelperLink.h"
#import "mac/SZFriendsHost.h"
#import "mac/SZFriendsListPage.h"

#include "client/szfriends_client.h"

static void SZFOEmit(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    if (data == nil) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// The helper at the other end of one of this process's Unix sockets: the client library keeps exactly one connected
// socket to it, so the first peer whose executable is a Friends helper is the one this app is ready on.
static pid_t SZFOHelperPeer(void) {
    for (int fd = 0; fd < 1024; fd++) {
        pid_t pid = 0;
        socklen_t length = sizeof pid;
        if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) != 0 || pid <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0 && [@(path).lastPathComponent isEqualToString:@"Shenzhen Friends"])
            return pid;
    }
    return 0;
}

@interface SZFOHost : NSObject <SZFriendsHost>
@property(nonatomic, copy) NSString *helperPath;
@property(nonatomic, strong) NSWindow *buttonWindow;
@end

@implementation SZFOHost
- (NSString *)friendsAppID { return @"com.intuition.shenzhenpdf"; }
- (NSString *)friendsAppName { return @"ShenzhenPDF"; }
- (NSString *)friendsAppVersion { return @"26.10.20"; }
- (NSString *)friendsRevealInName { return @"Finder"; }
- (NSString *)friendsHelperPath { return self.helperPath; }
- (void)friendsInstallButton:(NSView *)button { [self.buttonWindow.contentView addSubview:button]; }
- (void)friendsRemoveButton:(NSView *)button { [button removeFromSuperview]; }
- (NSArray<NSPasteboardType> *)friendsExtraPasteboardTypes { return @[]; }
- (NSArray<SZFriendsAttachableItem *> *)friendsItemsFromPasteboard:(NSPasteboard *)pasteboard {
    (void)pasteboard;
    return @[];
}
- (void)friendsAttachableItemsMatching:(NSString *)query
                            completion:(void (^)(NSArray<SZFriendsAttachableItem *> *))completion {
    (void)query;
    completion(@[]);
}
- (NSString *)friendsAttachPlaceholder { return @"Search open documents"; }
- (NSSet<NSString *> *)friendsFormatsOpenedInPlace { return [NSSet setWithObject:@"pdf"]; }
- (void)friendsOpenReceivedFileAtURL:(NSURL *)fileURL { (void)fileURL; }
- (void)friendsRevealFileAtURL:(NSURL *)fileURL { (void)fileURL; }
- (SZFriendsAppearance *)friendsAppearance { return [[SZFriendsAppearance alloc] init]; }
@end

// The dropdown's content goes into a window that is never ordered in, instead of an NSPopover.
@interface SZFOPresenter : NSObject <SZFriendsDropdownPresenter>
@property(nonatomic, strong) NSWindow *window;
@end

@implementation SZFOPresenter
@synthesize onDismiss = _onDismiss;
@synthesize presented = _presented;
- (void)presentView:(NSView *)view size:(NSSize)size fromButton:(NSView *)button {
    (void)button;
    if (self.window == nil) {
        self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        self.window.releasedWhenClosed = NO;
    }
    [self.window setContentSize:size];
    self.window.contentView = view;
    [view layoutSubtreeIfNeeded];
    _presented = YES;
}
- (void)resizeTo:(NSSize)size { [self.window setContentSize:size]; }
- (void)dismiss {
    _presented = NO;
    if (self.onDismiss) self.onDismiss();
}
@end

@interface SZFOApp : NSObject
@property(nonatomic, strong) SZFOHost *host;
@property(nonatomic, strong) SZFOPresenter *presenter;
@property(nonatomic, strong) SZFriendsHelperLink *link;
@property(nonatomic, strong) SZFriendsDropdownController *dropdown;
@property(nonatomic, strong) NSMutableData *input;
@end

static void SZFOSpin(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL SZFOWait(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow < 0) return NO;
        SZFOSpin(0.02);
    }
    return YES;
}

static void SZFOCollectTexts(NSView *view, NSMutableArray<NSString *> *texts) {
    if (view.isHidden) return;
    NSString *text = nil;
    if ([view isKindOfClass:[NSTextView class]]) text = ((NSTextView *)view).string;
    else if ([view isKindOfClass:[NSTextField class]]) text = ((NSTextField *)view).stringValue;
    else if ([view isKindOfClass:[NSButton class]]) {
        // A button's words as a person sees them (its title: the footer's name) and as VoiceOver reads them (a row).
        text = ((NSButton *)view).title;
        NSString *spoken = view.accessibilityLabel;
        if (spoken.length > 0 && ![spoken isEqualToString:text]) [texts addObject:spoken];
    }
    if (text.length > 0) [texts addObject:text];
    for (NSView *child in view.subviews) SZFOCollectTexts(child, texts);
}

@implementation SZFOApp

- (SZFriendsDropdownContent *)content {
    return self.dropdown.content;
}

- (SZFriendsConversationPage *)showConversation:(NSString *)conversationID {
    SZFriendsConversationPage *(^current)(void) = ^SZFriendsConversationPage * {
        id page = self.content.topPage;
        return [page isKindOfClass:[SZFriendsConversationPage class]] &&
                       [[page conversationID] isEqualToString:conversationID]
                   ? page
                   : nil;
    };
    if (current() == nil) [self.dropdown showConversation:conversationID highlightMessage:nil];
    if (!SZFOWait(10, ^BOOL { return current() != nil; })) return nil;
    SZFriendsConversationPage *page = current();
    [page layoutSubtreeIfNeeded];
    return page;
}

- (NSArray<NSString *> *)messageTexts:(SZFriendsConversationPage *)page {
    [page layoutSubtreeIfNeeded];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (SZFriendsItemView *item in page.itemViews) {
        if (![item.itemKind isEqualToString:@"message"]) continue;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSView *child in item.subviews) SZFOCollectTexts(child, parts);
        // The bubble's text comes first; the labels after it are its time and status.
        [texts addObject:parts.firstObject ?: @""];
    }
    return texts;
}

- (void)reply:(NSString *)tag ok:(BOOL)ok result:(NSDictionary *)result code:(NSString *)code {
    SZFOEmit(@{@"event" : @"reply", @"tag" : tag ?: @"", @"ok" : @(ok), @"result" : result ?: [NSNull null],
               @"code" : code ?: @""});
}

- (void)type:(NSString *)text into:(NSString *)conversationID tag:(NSString *)tag {
    SZFriendsConversationPage *page = [self showConversation:conversationID];
    NSTextView *field = page.composer.textView;
    if (field == nil) {
        [self reply:tag ok:NO result:nil code:@"no_composer"];
        return;
    }
    [field.window makeFirstResponder:field];
    // One character at a time, as the keyboard inserts them, then Return.
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void)range, (void)enclosing, (void)stop;
                              [field insertText:character replacementRange:field.selectedRange];
                          }];
    NSEvent *returnKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                         timestamp:0 windowNumber:field.window.windowNumber context:nil
                                        characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    [field keyDown:returnKey];
    // The composer empties once the helper has taken the message.
    BOOL sent = SZFOWait(10, ^BOOL { return field.string.length == 0; });
    [self reply:tag ok:sent result:@{@"left" : field.string ?: @""} code:sent ? nil : @"not_sent"];
}

- (void)run:(NSDictionary *)command {
    NSString *name = command[@"cmd"], *tag = command[@"tag"], *conversation = command[@"conversation_id"];
    if (![name isKindOfClass:[NSString class]]) return;
    if ([name isEqualToString:@"quit"]) {
        [self.link stopDisablingFriends:NO];
        exit(0);
    } else if ([name isEqualToString:@"list"] || [name isEqualToString:@"profile"]) {
        NSString *view = name;
        [self.link subscribeToView:view params:nil handler:^(NSDictionary *data, NSInteger rev) {
            (void)rev;
            SZFOEmit(@{@"event" : @"snapshot", @"view" : view, @"data" : data});
        }];
    } else if ([name isEqualToString:@"open"] && [conversation isKindOfClass:[NSString class]]) {
        [self.link openConversation:conversation messageID:nil handler:^(NSDictionary *data, NSInteger rev) {
            (void)rev;
            SZFOEmit(@{@"event" : @"snapshot", @"view" : @"conversation", @"data" : data});
        }];
    } else if ([name isEqualToString:@"send"] || [name isEqualToString:@"intent"]) {
        NSString *type = [name isEqualToString:@"send"] ? @"send_message" : command[@"type"];
        NSDictionary *fields = [name isEqualToString:@"send"]
                                   ? @{@"conversation_id" : conversation ?: @"", @"text" : command[@"text"] ?: @"",
                                       @"client_token" : command[@"client_token"] ?: @""}
                                   : command[@"fields"];
        [self.link sendIntent:type fields:fields reply:^(NSDictionary *result, SZFriendsLinkError *error) {
            [self reply:tag ok:error == nil result:result code:error.code];
        }];
    } else if ([name isEqualToString:@"ui_type"] && [conversation isKindOfClass:[NSString class]]) {
        [self type:command[@"text"] ?: @"" into:conversation tag:tag];
    } else if ([name isEqualToString:@"ui_texts"] && [conversation isKindOfClass:[NSString class]]) {
        SZFriendsConversationPage *page = [self showConversation:conversation];
        SZFOSpin(0.1);
        NSMutableArray *items = [NSMutableArray array];
        for (SZFriendsItemView *item in page.itemViews) {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSView *child in item.subviews) SZFOCollectTexts(child, parts);
            [items addObject:@{@"id" : item.itemID ?: @"", @"kind" : item.itemKind ?: @"", @"texts" : parts}];
        }
        [self reply:tag ok:page != nil
             result:@{@"texts" : page ? [self messageTexts:page] : @[], @"items" : items}
               code:nil];
    } else if ([name isEqualToString:@"paths"]) {
        // Where this process's client library looks for Friends: the home and the socket it connects to.
        char state[SZFRIENDS_PATH_CAP], socketPath[SZFRIENDS_PATH_CAP];
        BOOL found = szfriends_default_state_dir(state, sizeof state) == SZFRIENDS_OK &&
                     szfriends_socket_path(state, socketPath, sizeof socketPath, NULL) == SZFRIENDS_OK;
        [self reply:tag ok:found
             result:found ? @{@"state_dir" : @(state), @"socket_path" : @(socketPath)} : nil
               code:nil];
    } else if ([name isEqualToString:@"ui_list"]) {
        if (!self.dropdown.shown) [self.dropdown toggle];
        [self.content popToList];
        SZFOSpin(0.1);
        NSView *list = self.content.listPage;
        [list layoutSubtreeIfNeeded];
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        SZFOCollectTexts(list, texts);
        [self reply:tag ok:YES result:@{@"texts" : texts} code:nil];
    }
}

- (void)readInput:(NSData *)data {
    if (data.length == 0) exit(0); // the scenario went away: so does the app
    [self.input appendData:data];
    for (;;) {
        NSRange newline = [self.input rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                            range:NSMakeRange(0, self.input.length)];
        if (newline.location == NSNotFound) break;
        NSData *line = [self.input subdataWithRange:NSMakeRange(0, newline.location)];
        [self.input replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        id command = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        if ([command isKindOfClass:[NSDictionary class]]) [self run:command];
    }
}

@end

static NSString *SZFOStateName(SZFriendsLinkState state) {
    switch (state) {
    case SZFriendsLinkStateIdle: return @"idle";
    case SZFriendsLinkStateConnecting: return @"connecting";
    case SZFriendsLinkStateReady: return @"ready";
    case SZFriendsLinkStateWaiting: return @"waiting";
    case SZFriendsLinkStateIncompatible: return @"incompatible";
    }
    return @"unknown";
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: %s <embedded helper> <helper version> <helper build number>\n", argv[0]);
            return 2;
        }
        signal(SIGPIPE, SIG_IGN);
        [NSApplication sharedApplication];
        // Never a foreground app: no Dock icon, no menu bar, never active, whatever the views do.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        SZFOApp *app = [[SZFOApp alloc] init];
        app.input = [NSMutableData data];
        app.host = [[SZFOHost alloc] init];
        app.host.helperPath = @(argv[1]);
        app.host.buttonWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 40)
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
        app.host.buttonWindow.releasedWhenClosed = NO;
        // The launch path: connect-or-spawn in the background, never waited for (SPDFMacFriendsSpawnAtLaunch).
        [SZFriendsHelperLink spawnHelperInBackgroundForHost:app.host];
        app.presenter = [[SZFOPresenter alloc] init];
        app.link = [[SZFriendsHelperLink alloc] initWithHost:app.host];
        app.link.onStateChange = ^(SZFriendsLinkState state) {
            pid_t helper = state == SZFriendsLinkStateReady ? SZFOHelperPeer() : 0;
            SZFOEmit(@{@"event" : @"state", @"state" : SZFOStateName(state), @"helper_pid" : @(helper)});
        };
        app.dropdown = [[SZFriendsDropdownController alloc] initWithHost:app.host link:app.link
                                                               presenter:app.presenter];
        // After first paint, as the reader attaches: the button, the badge, and the link's start.
        [app.dropdown install];
        __weak SZFOApp *weakApp = app;
        NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
        input.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = handle.availableData;
            // A run-loop block, not the main dispatch queue: a command that waits spins the run loop, and the link's
            // dispatch sources on the main queue must run meanwhile, which they cannot from inside a queue block.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ [weakApp readInput:data]; });
            CFRunLoopWakeUp(CFRunLoopGetMain());
        };
        // ARC keeps `app` to the end of this scope, and [NSApp run] never returns.
        [NSApp run];
        (void)app;
    }
    return 0;
}
