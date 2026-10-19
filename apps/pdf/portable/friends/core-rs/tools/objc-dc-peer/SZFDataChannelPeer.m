// The Objective-C helper's online transport as the far end of a Rust data-channel peer: the helper's own
// SZFriendsOnlineDataChannelTransport (service/online/transport/) in its testing configuration (bound to 127.0.0.1,
// loopback candidates accepted), as a friend's direct connection, echoing every byte of the stream it opens. It
// answers the Rust side's offer, or with the argument "offer" makes the offer and applies the Rust side's answer.
// crates/szfriends-datachannel-sys/tests/objc_interop.rs drives it; core-rs.mk builds it
// (friends-datachannel-rs-check). Production transport sources, not copies.
//
// Signalling is one line per message, hex fields, on stdin and stdout; the test stands in for the host and the
// authenticated exchange that carries descriptions and candidates between helpers:
//   in:  offer <sdp> <fingerprint>      the offer and its SHA-256 certificate fingerprint (32 bytes), or
//        answer <sdp> <fingerprint>     the answer, when this side offered
//        candidate <candidate line>     one remote candidate
//        close                          end the connection and exit 0
//   out: answer|offer <sdp> <fingerprint>
//        candidate <candidate line> <technique>
//        open <technique>               the data channel's stream opened; the echo runs from here
//        closed                         the stream closed under the echo
//        failed <reason>                and exit 1
// Nothing else is written to stdout. Everything stays on 127.0.0.1.

#import <Foundation/Foundation.h>

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface SZFDCRequest : NSObject <SZFriendsOnlineConnectionRequest>
@property(nonatomic) SZFriendsOnlinePurpose purpose;
@property(nonatomic) SZFriendsOnlineRole role;
@property(nonatomic) SZFriendsOnlineConnectionKind kind;
@property(nonatomic, copy) NSData *peer;
@property(nonatomic, copy, nullable) NSString *stunURI;
@property(nonatomic, nullable) id<SZFriendsOnlineRelayCredentials> relay;
@property(nonatomic) uint16_t localPort;
@property(nonatomic, copy, nullable) NSString *remoteOfferSDP;
@property(nonatomic, copy, nullable) NSData *remoteFingerprint;
@end

@implementation SZFDCRequest
@end

static NSString *Hex(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSData *_Nullable Unhex(NSString *hex) {
    if (hex.length % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i * 2, 2)]];
        if (![scanner scanHexInt:&value]) return nil;
        bytes[i] = (uint8_t)value;
    }
    return data;
}

static NSString *_Nullable UnhexString(NSString *hex) {
    NSData *data = Unhex(hex);
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static void Say(NSString *line) {
    printf("%s\n", line.UTF8String);
    fflush(stdout);
}

static void Fail(NSString *reason) {
    Say([@"failed " stringByAppendingString:reason]);
    exit(1);
}

@interface SZFDCPeer : NSObject <SZFriendsOnlineConnectionDelegate>
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, strong, nullable) id<SZFriendsOnlineConnection> connection;
@property(nonatomic, strong, nullable) id<SZFriendsByteStream> stream;
@property(nonatomic) BOOL offerer;
@end

@implementation SZFDCPeer

- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("szfriends.dc-peer", DISPATCH_QUEUE_SERIAL);
    return self;
}

// An answerer passes the Rust side's offer; an offerer passes nil.
- (void)openWithTransport:(SZFriendsOnlineDataChannelTransport *)transport
                    offer:(nullable NSString *)offer
              fingerprint:(nullable NSData *)fingerprint {
    SZFDCRequest *request = [[SZFDCRequest alloc] init];
    request.purpose = SZFriendsOnlinePurposeFriend;
    request.role = offer ? SZFriendsOnlineRoleAnswerer : SZFriendsOnlineRoleOfferer;
    request.kind = SZFriendsOnlineConnectionDirect;
    request.peer = [NSMutableData dataWithLength:32]; // a friend's key; the transport only checks its length
    request.remoteOfferSDP = offer;
    request.remoteFingerprint = fingerprint;
    NSError *error = nil;
    self.connection = [transport openConnection:request delegate:self queue:self.queue error:&error];
    if (self.connection == nil) Fail([NSString stringWithFormat:@"openConnection: %@", error]);
}

- (void)handleLine:(NSString *)line transport:(SZFriendsOnlineDataChannelTransport *)transport {
    NSArray<NSString *> *fields = [line componentsSeparatedByString:@" "];
    if ([fields[0] isEqualToString:@"offer"] && fields.count == 3 && !self.offerer && self.connection == nil) {
        [self openWithTransport:transport offer:UnhexString(fields[1]) fingerprint:Unhex(fields[2])];
    } else if ([fields[0] isEqualToString:@"answer"] && fields.count == 3 && self.offerer && self.connection) {
        NSError *error = nil;
        NSString *sdp = UnhexString(fields[1]);
        NSData *fingerprint = Unhex(fields[2]);
        if (sdp == nil || fingerprint == nil ||
            ![self.connection applyRemoteAnswerSDP:sdp remoteFingerprint:fingerprint error:&error]) {
            Fail([NSString stringWithFormat:@"applyRemoteAnswerSDP: %@", error]);
        }
    } else if ([fields[0] isEqualToString:@"candidate"] && fields.count == 2 && self.connection != nil) {
        NSError *error = nil;
        NSString *candidate = UnhexString(fields[1]);
        if (candidate == nil || ![self.connection addRemoteCandidate:candidate
                                                           technique:SZFriendsOnlineTechniqueHostPrivate
                                                               error:&error]) {
            Fail([NSString stringWithFormat:@"addRemoteCandidate: %@", error]);
        }
    } else if ([fields[0] isEqualToString:@"close"]) {
        [self.stream close];
        [self.connection close];
        exit(0);
    } else {
        Fail([@"unexpected input: " stringByAppendingString:fields[0]]);
    }
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didCreateLocalDescription:(NSString *)sdp
                  fingerprint:(NSData *)fingerprint {
    (void)connection;
    NSString *kind = self.offerer ? @"offer" : @"answer";
    Say([NSString stringWithFormat:@"%@ %@ %@", kind, Hex([sdp dataUsingEncoding:NSUTF8StringEncoding]),
                                   Hex(fingerprint)]);
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didGatherLocalCandidate:(NSString *)candidate
                  technique:(SZFriendsOnlineTechnique)technique {
    (void)connection;
    Say([NSString stringWithFormat:@"candidate %@ %ld", Hex([candidate dataUsingEncoding:NSUTF8StringEncoding]),
                                   (long)technique]);
}

- (void)onlineConnectionDidFinishGathering:(id<SZFriendsOnlineConnection>)connection {
    (void)connection;
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
           didOpenStream:(id<SZFriendsByteStream>)stream
                   route:(SZFriendsOnlineRoute)route {
    (void)connection;
    if (self.stream != nil) {
        [stream close]; // one stream is enough to echo on
        return;
    }
    self.stream = stream;
    __weak id<SZFriendsByteStream> weakStream = stream;
    stream.onData = ^(NSData *data) {
        [weakStream writeData:data
                   completion:^(NSError *error) {
                       if (error) Fail([NSString stringWithFormat:@"echo: %@", error]);
                   }];
    };
    stream.onClose = ^(NSError *error) {
        Say(error ? [NSString stringWithFormat:@"failed stream closed: %@", error.localizedDescription] : @"closed");
    };
    [stream startWithQueue:self.queue];
    Say([NSString stringWithFormat:@"open %ld", (long)route.technique]);
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
                  stream:(id<SZFriendsByteStream>)stream
          didChangeRoute:(SZFriendsOnlineRoute)route {
    (void)connection;
    (void)stream;
    (void)route;
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection didFailWithError:(NSError *)error {
    (void)connection;
    Fail([NSString stringWithFormat:@"connection: %@", error]);
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        SZFriendsOnlineDataChannelTransport *transport =
            [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
        SZFDCPeer *peer = [[SZFDCPeer alloc] init];
        peer.offerer = argc > 1 && strcmp(argv[1], "offer") == 0;
        if (peer.offerer) {
            dispatch_sync(peer.queue, ^{
                [peer openWithTransport:transport offer:nil fingerprint:nil];
            });
        }
        // Lines are read on their own thread and handled on the connection's queue, in order.
        [NSThread detachNewThreadWithBlock:^{
            char buffer[65536];
            while (fgets(buffer, sizeof buffer, stdin) != NULL) {
                NSString *line = [[NSString stringWithUTF8String:buffer]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length == 0) continue;
                dispatch_sync(peer.queue, ^{
                    [peer handleLine:line transport:transport];
                });
            }
            exit(0); // the test ended without "close": nothing more to do
        }];
        dispatch_main();
    }
}
