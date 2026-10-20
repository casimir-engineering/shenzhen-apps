// Intents about this person's own profile and visibility: name, picture, the ID notice, the 5 minutes.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

// PROTOCOL.md § Limits.
static const NSUInteger SZFriendsNameMax = 40;

// Characters a name may not contain: C0 and C1 controls, line and paragraph separators, and the bidirectional
// overrides and isolates, which can make a name display as something else. Format characters such as the
// zero-width joiner stay allowed, since emoji sequences need them.
static NSCharacterSet *SZFriendsForbiddenNameCharacters(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *forbidden = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x00, 0x20)];
        [forbidden addCharactersInRange:NSMakeRange(0x7f, 0x21)];
        [forbidden addCharactersInRange:NSMakeRange(0x2028, 2)];
        [forbidden addCharactersInRange:NSMakeRange(0x202a, 5)];
        [forbidden addCharactersInRange:NSMakeRange(0x2066, 4)];
        set = [forbidden copy];
    });
    return set;
}

// Characters as people count them (composed sequences), so an accented letter or an emoji counts once.
static NSUInteger SZFriendsVisibleLength(NSString *text) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences |
                                     NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void)substring, (void)range, (void)enclosing, (void)stop;
                              count++;
                          }];
    return count;
}

@implementation SZFriendsIntentRouter (Profile)

- (void)intent_set_name:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                  reply:(SZFriendsIntentReply)reply {
    NSString *name = intent[@"name"];
    if (!SZFriendsJSONIsString(name)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"name"} connection:connection];
        return;
    }
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length > 0 && trimmed.length == 0) {
        [self fail:reply code:@"name_invalid" details:@{@"field" : @"name"} connection:connection];
        return;
    }
    if (trimmed.length > 0 && (SZFriendsVisibleLength(trimmed) > SZFriendsNameMax ||
                               [trimmed rangeOfCharacterFromSet:SZFriendsForbiddenNameCharacters()].location !=
                                   NSNotFound)) {
        [self fail:reply code:@"name_invalid" details:@{@"field" : @"name"} connection:connection];
        return;
    }
    // "" clears the name: friends then see the Friends ID (PROTOCOL.md set_name).
    self.services.store.profileName = trimmed.length > 0 ? trimmed : nil;
    [self.services.nearby profileChanged];
    [self succeed:reply result:nil];
}

- (void)intent_set_picture:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                     reply:(SZFriendsIntentReply)reply {
    // The avatars area parses, limits, decodes, crops, re-encodes and stores the picture, and names the protocol
    // error for anything it refuses, so the rules for untrusted images live in one place.
    NSError *error = nil;
    SZFriendsPicture *picture =
        [SZFriendsPicturePipeline pictureFromIntentPicture:intent[@"picture"] ?: [NSNull null]
                                                 animalSet:self.services.resources.animalSet
                                         picturesDirectory:self.services.paths.picturesDirectory
                                                     error:&error];
    if (picture == nil) {
        NSString *code = error.userInfo[SZFriendsPictureErrorCodeKey] ?: @"picture_invalid";
        NSMutableDictionary *details = [NSMutableDictionary dictionary];
        details[@"field"] = error.userInfo[SZFriendsPictureErrorFieldKey];
        details[@"path"] = error.userInfo[NSFilePathErrorKey];
        // The pipeline's description is written for the person choosing a picture ("This picture is too large...");
        // the catalog's generic words are the fallback.
        NSString *message = error.localizedDescription.length > 0 ? error.localizedDescription : nil;
        if (message == nil || [code isEqualToString:@"internal"]) {
            [self fail:reply code:code details:details connection:connection];
        } else {
            reply(nil, code, message, details);
        }
        return;
    }
    self.services.store.profilePicture = picture;
    [self.services.nearby profileChanged];
    [self succeed:reply result:nil];
}

- (void)intent_dismiss_banner:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                        reply:(SZFriendsIntentReply)reply {
    if (![intent[@"kind"] isEqual:@"id_changed"]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"kind"} connection:connection];
        return;
    }
    // Told once: the notice does not come back, and the new ID reads as simply reserved from now on (ADR 0006).
    SZFriendsStore *store = self.services.store;
    SZFriendsIDStatus *status = [[SZFriendsIDStatus alloc] initWithFriendsID:store.friendsID ?: @""
                                                                       state:(SZFriendsIDState)store.friendsIDState
                                                                  previousID:store.previousFriendsID
                                                            collisionsInARow:store.idCollisionsInARow];
    SZFriendsIDStatus *dismissed = [status statusAfterNoticeDismissed];
    store.friendsIDState = dismissed.state;
    store.previousFriendsID = dismissed.previousID;
    [self succeed:reply result:nil];
}

- (void)intent_start_visibility:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                          reply:(SZFriendsIntentReply)reply {
    // Repeating never extends a running deadline (PROTOCOL.md start_visibility); the public entry goes on the air
    // on both adapters at once.
    NSDate *deadline = nil;
    if (self.services.nearby != nil) {
        deadline = [self.services.nearby startVisibility];
    } else {
        SZFriendsStore *store = self.services.store;
        deadline = store.visibilityDeadline;
        if (deadline == nil || deadline.timeIntervalSinceNow <= 0) {
            deadline = [NSDate dateWithTimeIntervalSinceNow:SZFriendsVisibilityDuration];
            store.visibilityDeadline = deadline;
        }
    }
    [self succeed:reply result:@{@"deadline" : SZFriendsRFC3339(deadline)}];
}

- (void)intent_stop_visibility:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    if (self.services.nearby != nil) [self.services.nearby stopVisibility];
    else self.services.store.visibilityDeadline = nil;
    [self succeed:reply result:nil];
}

// The folder received files go to on this computer (PROTOCOL.md § Views, settings). The next settings snapshot, sent
// before the reply, shows it.
- (void)intent_set_received_folder:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                             reply:(SZFriendsIntentReply)reply {
    NSString *path = intent[@"path"];
    if (!SZFriendsJSONIsString(path) || path.length == 0 || path.length > 4096) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"path"} connection:connection];
        return;
    }
    NSError *error = nil;
    // Worded for the folder the person just picked, not for a file being sent.
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    NSDictionary *folder = @{@"field" : @"received_folder"};
    switch (SZFriendsSetReceivedFolder(self.services.paths.stateDirectory, path, &error)) {
    case SZFriendsReceivedFolderOK:
        [self succeed:reply result:nil];
        return;
    case SZFriendsReceivedFolderInvalidPath:
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"path"} connection:connection];
        return;
    case SZFriendsReceivedFolderMissing:
        reply(nil, @"file_missing", [strings messageForErrorCode:@"file_missing" details:folder], @{@"path" : path});
        return;
    case SZFriendsReceivedFolderNotAllowed:
        reply(nil, @"not_allowed", [strings messageForErrorCode:@"not_allowed" details:folder], @{});
        return;
    case SZFriendsReceivedFolderFailed: break;
    }
    NSLog(@"Friends: cannot save the received folder: %@", error.localizedDescription);
    [self fail:reply code:@"internal" details:nil connection:connection];
}

@end
