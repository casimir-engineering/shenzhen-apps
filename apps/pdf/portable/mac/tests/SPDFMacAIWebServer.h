// A real HTTP server on loopback for SPDFMacAIWebTests, imitating the sites that turned open_page away: a bot filter
// that answers 403 to anything but a browser, redirect chains, a PDF served as application/octet-stream, gzip, deflate
// and br bodies, a page built by scripts, sign-in walls. Requests travel over real sockets and are read by the real
// parser; only TLS is left out, through WebLoopbackConnector, which exists in this test only: production code has no
// plain-HTTP path at all (SPDFMacAIWebTLSConnector is the one connector the app makes).
#pragma once
#import "SPDFMacAIWebFakes.h"
#include <arpa/inet.h>
#include <compression.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>

// One request as the server read it: the request line and headers, names in lower case.
@interface WebServedRequest : NSObject
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* headers;
@property(nonatomic, copy) NSString* raw;
@end
@implementation WebServedRequest
@end

typedef NSData* (^WebRoute)(WebServedRequest* request);

@interface WebHTTPServer : NSObject
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, copy) WebRoute route;
@property(atomic, readonly) NSArray<WebServedRequest*>* requests;
- (BOOL)start;
- (void)stop;
@end

@implementation WebHTTPServer {
    int _socket;
    NSMutableArray* _requests;
    BOOL _stopping;
}
- (NSArray*)requests { @synchronized(self) { return [_requests copy]; } }
- (BOOL)start {
    _requests = [NSMutableArray array];
    _socket = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    if (_socket < 0 || bind(_socket, (struct sockaddr*)&address, length) || listen(_socket, 16) ||
        getsockname(_socket, (struct sockaddr*)&address, &length)) return NO;
    _port = ntohs(address.sin_port);
    int listening = _socket;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Bounded: the server gives up after 60 s even if a check forgets to stop it.
        for (int round = 0; round < 600 && !self->_stopping; round++) {
            struct pollfd wait = {listening, POLLIN, 0};
            if (poll(&wait, 1, 100) <= 0) continue;
            int client = accept(listening, NULL, NULL);
            if (client < 0) continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self serve:client]; });
        }
    });
    return YES;
}
- (void)serve:(int)client {
    NSMutableData* head = [NSMutableData data];
    uint8_t buffer[4096];
    NSData* end = [NSData dataWithBytes:"\r\n\r\n" length:4];
    while (head.length < 16384 && [head rangeOfData:end options:0 range:NSMakeRange(0, head.length)].location ==
           NSNotFound) {
        struct pollfd readable = {client, POLLIN, 0};
        if (poll(&readable, 1, 3000) <= 0) break;
        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
        if (count <= 0) break;
        [head appendBytes:buffer length:(NSUInteger)count];
    }
    NSString* text = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
    NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray<NSString*>* words = [lines.firstObject componentsSeparatedByString:@" "];
    WebServedRequest* request = [WebServedRequest new];
    request.raw = text;
    request.path = words.count > 1 ? words[1] : @"/";
    NSMutableDictionary* headers = [NSMutableDictionary dictionary];
    for (NSString* line in lines) {
        NSRange colon = [line rangeOfString:@": "];
        if (colon.location != NSNotFound && line != lines.firstObject)
            headers[[line substringToIndex:colon.location].lowercaseString] =
                [line substringFromIndex:NSMaxRange(colon)];
    }
    request.headers = headers;
    @synchronized(self) { [_requests addObject:request]; }
    NSData* response = self.route ? self.route(request) : WebResponse(404, @{@"Content-Length" : @"0"}, nil);
    for (NSUInteger sent = 0; sent < response.length;) {
        ssize_t count = send(client, (const uint8_t*)response.bytes + sent, response.length - sent, 0);
        if (count <= 0) break;
        sent += (NSUInteger)count;
    }
    close(client);
}
- (void)stop {
    _stopping = YES;
    if (_socket >= 0) close(_socket);
    _socket = -1;
}
@end

// Test only: the fetcher's connection made in plain TCP to the loopback server, whatever checked public address it is
// handed (recorded, as the scripted connector records it), so the fetch above it runs unchanged.
@interface WebLoopbackConnector : NSObject <SPDFMacAIWebConnecting>
@property(nonatomic) uint16_t port;
@property(nonatomic) NSMutableArray<WebConnection*>* connections;
@end

@implementation WebLoopbackConnector
- (instancetype)init {
    if ((self = [super init])) _connections = [NSMutableArray array];
    return self;
}
- (dispatch_block_t)exchangeRequest:(NSData*)request address:(NSString*)address port:(uint16_t)port
                         serverName:(NSString*)serverName queue:(dispatch_queue_t)queue
                            receive:(BOOL (^)(NSData*))receive finished:(void (^)(NSError*))finished {
    WebConnection* connection = [WebConnection new];
    connection.address = address;
    connection.serverName = serverName;
    connection.port = port;
    connection.request = [[NSString alloc] initWithData:request encoding:NSASCIIStringEncoding];
    @synchronized(self) { [_connections addObject:connection]; }
    __block BOOL over = NO;
    uint16_t local = _port;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in to;
        memset(&to, 0, sizeof(to));
        to.sin_family = AF_INET;
        to.sin_port = htons(local);
        to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        BOOL connected = fd >= 0 && !connect(fd, (struct sockaddr*)&to, sizeof(to)) &&
            send(fd, request.bytes, request.length, 0) == (ssize_t)request.length;
        __block BOOL stop = !connected;
        uint8_t buffer[65536];
        while (!stop) {
            ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
            if (count <= 0) break;
            NSData* chunk = [NSData dataWithBytes:buffer length:(NSUInteger)count];
            dispatch_sync(queue, ^{
                connection.delivered += chunk.length;
                stop = over || !receive(chunk);
            });
        }
        if (fd >= 0) close(fd);
        dispatch_async(queue, ^{
            if (over) return;
            over = YES;
            finished(connected ? nil : SPDFMacAIWebMakeError(SPDFMacAIWebErrorUnreachable, @"unreachable"));
        });
    });
    return ^{
        dispatch_async(queue, ^{
            connection.cancelled = YES;
            if (over) return;
            over = YES;
            finished(SPDFMacAIWebMakeError(SPDFMacAIWebErrorCancelled, @"stopped"));
        });
    };
}
@end

#pragma mark - Fixtures

static NSData* WebGzip(NSData* data, BOOL gzip) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    // 31: a gzip header and trailer; 15: zlib's own two-byte wrapper, which HTTP's "deflate" names.
    deflateInit2(&stream, 6, Z_DEFLATED, gzip ? 31 : 15, 8, Z_DEFAULT_STRATEGY);
    NSMutableData* out = [NSMutableData dataWithLength:deflateBound(&stream, (uLong)data.length) + 64];
    stream.next_in = (Bytef*)data.bytes;
    stream.avail_in = (uInt)data.length;
    stream.next_out = (Bytef*)out.mutableBytes;
    stream.avail_out = (uInt)out.length;
    deflate(&stream, Z_FINISH);
    out.length = stream.total_out;
    deflateEnd(&stream);
    return out;
}

static NSData* WebBrotli(NSData* data) {
    NSMutableData* out = [NSMutableData dataWithLength:data.length + 1024];
    size_t size = compression_encode_buffer((uint8_t*)out.mutableBytes, out.length, (const uint8_t*)data.bytes,
                                            data.length, NULL, COMPRESSION_BROTLI);
    out.length = size;
    return out;
}

static NSData* WebEncoded(NSString* type, NSString* encoding, NSData* body) {
    return WebResponse(200, @{@"Content-Type" : type, @"Content-Encoding" : encoding,
                              @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)body.length]},
                       body);
}

// A PDF written out by hand: Helvetica text at page coordinates, one array of {x, y, text} per page, in the order
// given (a table can be written column by column, as datasheet generators often do), with a title.
static NSData* WebFixturePDF(NSArray<NSArray<NSArray*>*>* pages, NSString* title) {
    NSMutableArray<NSString*>* objects = [NSMutableArray array];
    NSMutableString* kids = [NSMutableString string];
    NSUInteger font = 3 + pages.count * 2, info = font + 1;
    for (NSUInteger index = 0; index < pages.count; index++) [kids appendFormat:@"%lu 0 R ", 3 + index * 2];
    [objects addObject:@"<< /Type /Catalog /Pages 2 0 R >>"];
    [objects addObject:[NSString stringWithFormat:@"<< /Type /Pages /Kids [%@] /Count %lu >>", kids,
                        (unsigned long)pages.count]];
    for (NSArray<NSArray*>* items in pages) {
        NSMutableString* content = [NSMutableString string];
        for (NSArray* item in items)
            [content appendFormat:@"BT /F1 11 Tf %@ %@ Td (%@) Tj ET\n", item[0], item[1], item[2]];
        [objects addObject:[NSString stringWithFormat:@"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                            "/Resources << /Font << /F1 %lu 0 R >> >> /Contents %lu 0 R >>", (unsigned long)font,
                            (unsigned long)objects.count + 2]];
        [objects addObject:[NSString stringWithFormat:@"<< /Length %lu >>\nstream\n%@endstream",
                            (unsigned long)content.length, content]];
    }
    [objects addObject:@"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"];
    [objects addObject:[NSString stringWithFormat:@"<< /Title (%@) >>", title]];
    NSMutableString* pdf = [NSMutableString stringWithString:@"%PDF-1.4\n"];
    NSMutableArray<NSNumber*>* offsets = [NSMutableArray array];
    for (NSUInteger index = 0; index < objects.count; index++) {
        [offsets addObject:@(pdf.length)];
        [pdf appendFormat:@"%lu 0 obj\n%@\nendobj\n", (unsigned long)index + 1, objects[index]];
    }
    NSUInteger xref = pdf.length;
    [pdf appendFormat:@"xref\n0 %lu\n0000000000 65535 f \n", (unsigned long)objects.count + 1];
    for (NSNumber* offset in offsets) [pdf appendFormat:@"%010lu 00000 n \n", offset.unsignedLongValue];
    [pdf appendFormat:@"trailer\n<< /Size %lu /Root 1 0 R /Info %lu 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
                      (unsigned long)objects.count + 1, (unsigned long)info, (unsigned long)xref];
    return [pdf dataUsingEncoding:NSASCIIStringEncoding];
}

// Three pages: prose, a pin table written column by column, ordering information.
static NSData* WebDatasheetPDF(void) {
    return WebFixturePDF(@[
        @[@[@72, @720, @"BM28 Series connector, 0.35 mm pitch, 0.6 mm stacking height"],
          @[@72, @700, @"Rated current 5 A on the power contacts."]],
        @[@[@72, @720, @"Pin assignment"],
          @[@72, @690, @"Pin"], @[@72, @670, @"1"], @[@72, @650, @"2"],
          @[@200, @690, @"Signal"], @[@200, @670, @"GND"], @[@200, @650, @"VBUS"],
          @[@330, @690, @"Voltage"], @[@330, @670, @"0 V"], @[@330, @650, @"5 V"]],
        @[@[@72, @720, @"Ordering information: BM28B0.6-10DS/2-0.35V(51)"]]], @"BM28 Test Datasheet");
}
