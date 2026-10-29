// The Objective-C interop peer: state, commands and main() (SZFSessionPeer.h).

#import "SZFSessionPeer.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentityInternal.h"
#import "service/session/SZFriendsSecureChannelInternal.h"

NSString *SZFHex(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

NSData *SZFBytes(id hex) {
    if (![hex isKindOfClass:[NSString class]] || [hex length] % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:[hex length] / 2];
    uint8_t *out = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned value = 0;
        if (sscanf([[hex substringWithRange:NSMakeRange(i * 2, 2)] UTF8String], "%2x", &value) != 1) return nil;
        out[i] = (uint8_t)value;
    }
    return data;
}

static NSData *SZFDerive(NSString *label) {
    NSData *input = [label dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *out = [NSMutableData dataWithLength:32];
    crypto_generichash(out.mutableBytes, 32, input.bytes, input.length, NULL, 0);
    return out;
}

@implementation SZFPeerSession
- (instancetype)init {
    if ((self = [super init])) {
        _senders = [NSMutableDictionary dictionary];
        _sources = [NSMutableDictionary dictionary];
        _doneSent = [NSMutableSet set];
        _receivers = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@implementation SZFPeer {
    uint64_t _nextSession;
    NSLock *_output;
}

- (instancetype)initWithHome:(NSString *)home name:(NSString *)name {
    if ((self = [super init])) {
        _home = [home copy];
        _queue = dispatch_queue_create("szf.peer", DISPATCH_QUEUE_SERIAL);
        _networkQueue = dispatch_queue_create("szf.peer.network", DISPATCH_QUEUE_SERIAL);
        NSMutableData *staticKey = [SZFDerive([name stringByAppendingString:@" static"]) mutableCopy];
        uint8_t *bytes = staticKey.mutableBytes;
        bytes[0] &= 248;
        bytes[31] = (bytes[31] & 127) | 64;
        _identity = [SZFriendsIdentity identityWithSigningSeed:SZFDerive([name stringByAppendingString:@" seed"])
                                              staticPrivateKey:staticKey];
        NSError *error = nil;
        _store = [SZFriendsStore storeInDirectory:home error:&error];
        if (_store == nil) {
            fprintf(stderr, "SZFSessionPeer: store: %s\n", error.localizedDescription.UTF8String);
            exit(1);
        }
        _transfers = [[SZFriendsTransfers alloc] initWithStore:_store stateDirectory:home];
        _sessions = [NSMutableDictionary dictionary];
        _friendKeys = [NSMutableSet set];
        _tokens = [NSMutableSet set];
        _nextSession = 1;
        _output = [[NSLock alloc] init];
    }
    return self;
}

- (uint64_t)nextSessionID {
    return _nextSession++;
}

- (void)emit:(NSDictionary *)event {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    if (json == nil) return;
    [_output lock];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    [_output unlock];
}

- (NSDictionary *)addFriend:(NSDictionary *)command {
    NSData *identityKey = SZFBytes(command[@"identity_key"]), *staticKey = SZFBytes(command[@"static_key"]);
    if (identityKey.length != 32 || staticKey.length != 32) return @{@"error" : @"bad keys"};
    SZFriendsPersonRecord *person = [_store personWithIdentityKey:identityKey] ?: [[SZFriendsPersonRecord alloc] init];
    person.identityKey = identityKey;
    person.staticKey = staticKey;
    person.name = command[@"name"];
    person.picture = person.picture ?: [SZFriendsPicture placeholder];
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = person.lastInteractionAt ?: [NSDate date];
    NSError *error = nil;
    if (![_store savePerson:person error:&error]) return @{@"error" : error.localizedDescription ?: @"save failed"};
    [_friendKeys addObject:identityKey];
    return @{@"conversation" : person.conversationID};
}

- (NSDictionary *)transfer:(NSDictionary *)command {
    SZFriendsTransferRecord *record = [_transfers transferWithID:command[@"id"] ?: @""];
    if (record == nil) return @{@"error" : @"no such transfer"};
    return @{
        @"state" : @(record.state),
        @"verified" : @(record.verifiedBytes),
        @"received_path" : record.receivedPath ?: [NSNull null],
    };
}

- (NSDictionary *)handleCommand:(NSDictionary *)command {
    NSString *name = command[@"cmd"];
    SZFPeerSession *session = _sessions[@([command[@"session"] unsignedLongLongValue])];
    if ([name isEqualToString:@"hello"]) {
        return @{
            @"identity_key" : SZFHex(_identity.publicKey),
            @"static_key" : SZFHex(_identity.staticPublicKey),
            @"session_minor" : @(SZFriendsSessionMinor),
            // `dial` takes "lane_of" (ADR 0018 § 6), and lanes are admitted.
            @"lanes" : @YES,
        };
    } else if ([name isEqualToString:@"listen"]) {
        return [self listenOnAnyInterface:[command[@"any"] boolValue]];
    } else if ([name isEqualToString:@"public_profile"]) {
        self.publicProfile = @{@(SZFriendsFieldName) : [command[@"name"] dataUsingEncoding:NSUTF8StringEncoding]};
        return @{};
    } else if ([name isEqualToString:@"add_friend"]) {
        return [self addFriend:command];
    } else if ([name isEqualToString:@"issue_token"]) {
        NSData *token = SZFBytes(command[@"token"]);
        if (token) [_tokens addObject:token];
        return @{};
    } else if ([name isEqualToString:@"set_rekey"]) {
        self.rekeyAfterBytes = [command[@"bytes"] unsignedLongLongValue];
        return @{};
    } else if ([name isEqualToString:@"dial"]) {
        return [self dialWithCommand:command];
    } else if ([name isEqualToString:@"send"]) {
        NSData *bytes = SZFBytes(command[@"frame"]);
        SZFriendsFrame *frame = bytes ? SZFriendsDecodeFrame(bytes, NULL) : nil;
        return @{@"sent" : (frame != nil && [session.channel sendFrame:frame]) ? @YES : @NO};
    } else if ([name isEqualToString:@"code"]) {
        uint64_t sessionID = session.sessionID;
        [session.channel runComparisonCodeExchange:^(NSString *code, NSError *error) {
            [self emit:code ? @{@"event" : @"code", @"session" : @(sessionID), @"code" : code}
                            : @{@"event" : @"code", @"session" : @(sessionID), @"error" : @(error.code)}];
        }];
        return @{};
    } else if ([name isEqualToString:@"close"]) {
        [session.channel closeWithReason:(SZFriendsCloseReason)[command[@"reason"] unsignedIntValue]];
        return @{};
    } else if ([name isEqualToString:@"request_by_id"]) {
        return [self requestByIDWithCommand:command];
    } else if ([name isEqualToString:@"send_file"]) {
        return [self sendFileWithCommand:command];
    } else if ([name isEqualToString:@"transfer"]) {
        return [self transfer:command];
    } else if ([name isEqualToString:@"online"]) {
        return [self onlineWithCommand:command];
    } else if ([name isEqualToString:@"reach"]) {
        return [self reachWithCommand:command];
    } else if ([name isEqualToString:@"block_direct"]) {
        return [self blockDirectWithCommand:command];
    } else if ([name isEqualToString:@"open_link"]) {
        return [self openLinkWithCommand:command];
    } else if ([name isEqualToString:@"quit"] || [name isEqualToString:@"abort"]) {
        return @{};
    } else if ([name isEqualToString:@"debug"]) {
        // Each session's block exchange as it stands (the bench asks when a transfer stalls).
        NSMutableDictionary *sessions = [NSMutableDictionary dictionary];
        for (NSNumber *key in self.sessions) {
            SZFPeerSession *session = self.sessions[key];
            sessions[key.stringValue] = @{@"lane_of" : session.laneHead ? @(session.laneHead.sessionID) : [NSNull null],
                                          @"blocks" : session.blocks ? [session.blocks debugState] : [NSNull null]};
        }
        return @{@"sessions" : sessions};
    }
    NSDictionary *device = [self deviceCommand:command];
    if (device != nil) return device;
    return @{@"error" : [NSString stringWithFormat:@"unknown command %@", name]};
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFSessionPeer <state directory> <identity name>\n");
            return 2;
        }
        SZFPeer *peer = [[SZFPeer alloc] initWithHome:@(argv[1]) name:@(argv[2])];
        // Commands are read here and run on the peer's queue in order; events go out from that queue meanwhile.
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length;
        while ((length = getline(&line, &capacity, stdin)) > 0) {
            NSData *data = [NSData dataWithBytes:line length:(NSUInteger)length];
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![command isKindOfClass:[NSDictionary class]]) continue;
            __block NSDictionary *reply = nil;
            dispatch_sync(peer.queue, ^{ reply = [peer handleCommand:command]; });
            [peer emit:@{@"reply" : reply ?: @{}}];
            if ([command[@"cmd"] isEqualToString:@"quit"]) break;
        }
        free(line);
        dispatch_sync(peer.queue, ^{
            [peer stopOnline];
            for (SZFPeerSession *session in peer.sessions.allValues) [session.channel close];
            [peer.transfers flushProgressWithError:NULL];
            [peer.store close];
        });
    }
    return 0;
}
