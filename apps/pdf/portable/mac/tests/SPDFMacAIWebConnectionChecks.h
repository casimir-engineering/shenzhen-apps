// The real connector and resolver, on loopback only: the connector refuses private addresses itself before any
// connection, and with its check replaced it connects to exactly the number it is given and names the host in TLS.
#pragma once
#import "SPDFMacAIWebFakes.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

// A loopback listener that counts connections and keeps the first bytes the first one sends.
@interface WebListener : NSObject
@property(nonatomic, readonly) uint16_t port;
@property(atomic) NSUInteger accepted;
@property(atomic) NSData* firstBytes;
- (BOOL)start;
- (void)stop;
@end

@implementation WebListener {
    int _socket;
    BOOL _stopping;
}
- (BOOL)start {
    _socket = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    if (_socket < 0 || bind(_socket, (struct sockaddr*)&address, length) || listen(_socket, 4) ||
        getsockname(_socket, (struct sockaddr*)&address, &length)) return NO;
    _port = ntohs(address.sin_port);
    int listening = _socket;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Bounded: the whole listener gives up after 8 s.
        for (int round = 0; round < 80 && !self->_stopping; round++) {
            struct pollfd wait = {listening, POLLIN, 0};
            if (poll(&wait, 1, 100) <= 0) continue;
            int client = accept(listening, NULL, NULL);
            if (client < 0) continue;
            self.accepted++;
            struct pollfd readable = {client, POLLIN, 0};
            if (!self.firstBytes && poll(&readable, 1, 3000) > 0) {
                uint8_t buffer[4096];
                ssize_t count = recv(client, buffer, sizeof(buffer), 0);
                if (count > 0) self.firstBytes = [NSData dataWithBytes:buffer length:(NSUInteger)count];
            }
            close(client);
        }
    });
    return YES;
}
- (void)stop {
    _stopping = YES;
    if (_socket >= 0) close(_socket);
    _socket = -1;
}
@end

static NSError* WebExchange(id<SPDFMacAIWebConnecting> connector, NSString* address, uint16_t port, NSString* name) {
    __block NSError* outcome = nil;
    __block BOOL done = NO;
    dispatch_queue_t queue = dispatch_queue_create("ShenzhenPDF.AI.Web.Tests", DISPATCH_QUEUE_SERIAL);
    [connector exchangeRequest:[@"GET / HTTP/1.1\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] address:address
                          port:port serverName:name queue:queue
                              receive:^BOOL(NSData* bytes) { (void)bytes; return YES; }
                      finished:^(NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{ outcome = error; done = YES; });
    }];
    CHECK(WebWait(^BOOL { return done; }, 8), "the exchange finishes");
    return outcome;
}

static void CheckRealConnector(void) {
    WebListener* listener = [WebListener new];
    CHECK([listener start], "a loopback listener starts");
    SPDFMacAIWebTLSConnector* connector = [SPDFMacAIWebTLSConnector new];
    connector.connectTimeout = 3;
    for (NSString* address in @[@"127.0.0.1", @"::ffff:127.0.0.1", @"::1", @"0.0.0.0", @"2130706433"]) {
        NSError* error = WebExchange(connector, address, listener.port, @"pages.example.com");
        CHECK(error.code == SPDFMacAIWebErrorPrivateAddress,
              "the connector refuses a private address itself, whoever calls it");
    }
    WebWait(^BOOL { return NO; }, 0.3);
    CHECK(listener.accepted == 0, "no connection ever reached the listener");

    // With the check replaced (tests only), the connection goes to the number given, and the name it was told
    // travels only in TLS: "pinned.example.com" does not exist, so it was never resolved.
    SPDFMacAIWebTLSConnector* open = [[SPDFMacAIWebTLSConnector alloc] initWithAddressCheck:^NSString*(NSString* a) {
        (void)a;
        return nil;
    }];
    open.connectTimeout = 3;
    NSError* error = WebExchange(open, @"127.0.0.1", listener.port, @"pinned.example.com");
    CHECK(listener.accepted == 1 && error.code == SPDFMacAIWebErrorUnreachable,
          "a connection to the given address, failing cleanly when the server hangs up");
    NSData* hello = listener.firstBytes;
    NSData* name = [@"pinned.example.com" dataUsingEncoding:NSASCIIStringEncoding];
    CHECK(hello.length > 5 && ((const uint8_t*)hello.bytes)[0] == 0x16 &&
          [hello rangeOfData:name options:0 range:NSMakeRange(0, hello.length)].location != NSNotFound,
          "a TLS ClientHello carrying the host name (SNI)");
    [listener stop];

    __block NSArray* addresses = nil;
    __block BOOL resolved = NO;
    [[SPDFMacAIWebSystemResolver new] resolveHost:@"localhost" completion:^(NSArray* found, NSError* failure) {
        (void)failure;
        dispatch_async(dispatch_get_main_queue(), ^{ addresses = found; resolved = YES; });
    }];
    CHECK(WebWait(^BOOL { return resolved; }, 5) && ([addresses containsObject:@"127.0.0.1"] ||
          [addresses containsObject:@"::1"]), "the system resolver answers with numeric addresses");
    for (NSString* address in addresses)
        CHECK(SPDFMacAIWebAddressRefusal(address) != nil, "which the address check then refuses");
}
