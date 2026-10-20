// Shenzhen Friends strings: reply error messages and the Add by ID reply.
//
// error.message is shown to the person who tried something, so it says what happened to their action and what they
// can do, never the mechanism. Protocol errors (a view or library bug) get no text: there is nothing useful to say
// to the person, and the view shows its generic failure. Neither do the client-side codes (not_ready,
// connection_lost): the helper never sends them, and the host shows its own connection line instead.

#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsStrings (SZFriendsMessages)

- (NSString *)errorMessageForCode:(NSString *)code details:(NSDictionary<NSString *, id> *)details {
    static NSSet<NSString *> *silent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      silent = [NSSet setWithArray:@[
          @"bad_frame", @"frame_too_large", @"hello_required", @"protocol_unsupported", @"unknown_intent",
          @"too_many_subscriptions", @"not_ready", @"connection_lost"
      ]];
    });
    if (!code.length || [silent containsObject:code]) return nil;

    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    id path = details[@"path"], fileName = details[@"file_name"], name = details[@"name"];
    if ([fileName isKindOfClass:NSString.class] && [fileName length]) values[@"file"] = fileName;
    else if ([path isKindOfClass:NSString.class] && [path length]) values[@"file"] = [path lastPathComponent];
    if ([name isKindOfClass:NSString.class] && [name length]) values[@"name"] = name;
    id needed = details[@"needed_bytes"];
    if ([needed isKindOfClass:NSNumber.class])
        values[@"size"] = [self sizeLabelForBytes:[needed unsignedLongLongValue]];
    id retryAfter = details[@"retry_after_seconds"];
    if ([retryAfter isKindOfClass:NSNumber.class] && [retryAfter longValue] > 0)
        values[@"seconds"] = [NSString stringWithFormat:@"%ld", [retryAfter longValue]];
    id maximum = details[@"max"];
    if ([maximum isKindOfClass:NSNumber.class]) values[@"max"] = [maximum stringValue];
    id field = details[@"field"];

    // The more specific wording when the details allow it, the general one otherwise.
    if ([code isEqualToString:@"invalid_field"]) {
        if ([field isEqual:@"text"]) return [self text:@"error.invalid_field.text"];
        if ([field isEqual:@"query"]) return [self text:@"error.invalid_field.query"];
        if ([field isEqual:@"payload"]) return [self text:@"error.invalid_field.payload"];
        return nil; // any other field is a view bug; nothing the person can fix
    }
    // cancel_message lost the race: the message had already left, so the reply says where it is, not "changed".
    // `name` and `friends_id` name the friend; only the words carry them, the wire details keep `field` and `state`.
    id state = details[@"state"];
    if ([code isEqualToString:@"stale"] && [field isEqual:@"message_id"] &&
        ([state isEqual:@"delivered"] || [state isEqual:@"sending"] || [state isEqual:@"sent"])) {
        id friendsID = details[@"friends_id"];
        NSString *first = [self firstNameForName:values[@"name"]
                                       friendsID:[friendsID isKindOfClass:NSString.class] ? friendsID : nil];
        return [self text:[@"error.stale.message_" stringByAppendingString:state] values:@{@"first" : first}];
    }
    // set_received_folder: the folder the person picked in Settings (the router passes this field for the words).
    if ([field isEqual:@"received_folder"] && [code isEqualToString:@"file_missing"])
        return [self text:@"error.received_folder.missing"];
    if ([field isEqual:@"received_folder"] && [code isEqualToString:@"not_allowed"])
        return [self text:@"error.received_folder.not_allowed"];
    // A link that was revoked, expired or reset (PROTOCOL.md § Links).
    if ([code isEqualToString:@"not_found"] && [field isEqual:@"payload"]) return [self text:@"error.not_found.link"];
    if ([code isEqualToString:@"rate_limited"])
        return [self text:values[@"seconds"] ? @"error.rate_limited.seconds" : @"error.rate_limited" values:values];
    if ([code isEqualToString:@"too_many_files"])
        return [self text:values[@"max"] ? @"error.too_many_files.max" : @"error.too_many_files" values:values];
    if ([code isEqualToString:@"disk_full"]) {
        // file_name names an incoming offer (accepting it needs space); a path is a file being sent, which needs
        // space for its snapshot. The remedy differs, so the sentence does too.
        BOOL receiving = [fileName isKindOfClass:NSString.class] && [fileName length];
        NSString *key = receiving ? (values[@"size"] ? @"error.disk_full.file_size" : @"error.disk_full.file")
                      : values[@"file"] ? @"error.disk_full.sending"
                      : values[@"size"] ? @"error.disk_full.size"
                                        : @"error.disk_full";
        return [self text:key values:values];
    }
    // A reset that stopped before changing anything, because the old identity could not be removed.
    if ([code isEqualToString:@"internal"] && [details[@"reason"] isEqual:@"identity_not_removed"])
        return [self text:@"error.internal.identity_not_removed"];
    NSArray<NSString *> *personal = @[ @"already_friends", @"blocked", @"not_friends", @"mention_mismatch" ];
    NSArray<NSString *> *withFile = @[ @"file_missing", @"folder_not_supported", @"source_changed" ];
    NSString *key = [@"error." stringByAppendingString:code];
    if ([personal containsObject:code] && values[@"name"]) key = [key stringByAppendingString:@".name"];
    if ([withFile containsObject:code] && values[@"file"]) key = [key stringByAppendingString:@".file"];
    if (!SZFriendsEnglishCatalog()[key]) return [self text:@"error.internal"];
    return [self text:key values:values];
}

- (NSString *)addByIDMessageForID:(NSString *)friendsID {
    // Nearby only (online not offered yet): the sentence must not promise delivery over the Internet.
    return [self text:@"add_by_id.sent" values:@{@"id" : [self displayID:friendsID]}];
}

@end
