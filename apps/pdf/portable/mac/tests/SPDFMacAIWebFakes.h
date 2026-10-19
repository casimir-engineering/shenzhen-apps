// Fakes for SPDFMacAIWebTests: a scripted resolver, connector and OpenRouter transport. Each records what it was asked,
// so a check proves where a request would have gone, not only what came back. Nothing here touches the network.
#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAIWebAddress.h"
#import "SPDFMacAIWebConnection.h"
#import "SPDFMacAIWebSearch.h"

static int failures;
static void WebCheck(const char* file, int line, BOOL condition, const char* message) {
    if (condition) return;
    fprintf(stderr, "FAIL %s:%d: %s\n", file, line, message);
    ++failures;
}
// Variadic, because a condition holding an array literal has commas the preprocessor would split on.
#define CHECK(...) WebCheck(__FILE__, __LINE__, __VA_ARGS__)

// Runs the main run loop until `done` or `seconds` pass (never more than 10 s); YES when `done` held.
static BOOL WebWait(BOOL (^done)(void), NSTimeInterval seconds) {
    NSDate* limit = [NSDate dateWithTimeIntervalSinceNow:MIN(seconds, 10.0)];
    while (!done() && [limit timeIntervalSinceNow] > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    return done();
}

static NSData* WebResponse(NSInteger status, NSDictionary<NSString*, NSString*>* headers, NSData* body) {
    NSMutableString* head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld Status\r\n", (long)status];
    for (NSString* name in headers) [head appendFormat:@"%@: %@\r\n", name, headers[name]];
    [head appendString:@"\r\n"];
    NSMutableData* data = [[head dataUsingEncoding:NSISOLatin1StringEncoding] mutableCopy];
    if (body) [data appendData:body];
    return data;
}

static NSData* WebHTML(NSString* html) {
    NSData* body = [html dataUsingEncoding:NSUTF8StringEncoding];
    NSString* length = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    return WebResponse(200, @{@"Content-Type" : @"text/html; charset=utf-8", @"Content-Length" : length}, body);
}

static NSData* WebRedirect(NSInteger status, NSString* location) {
    return WebResponse(status, @{@"Location" : location, @"Content-Length" : @"0"}, nil);
}

static SPDFMacAISettingsSnapshot* WebSettings(BOOL web) {
    // Construction and setters do no I/O; nothing is saved, so the temporary path is never created.
    NSURL* URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"spdf-ai-web-settings-%@.yaml", NSUUID.UUID.UUIDString]]];
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:URL];
    settings.model = @"example/model-for-tests";
    settings.aiWebSearchEnabled = web;
    return settings.snapshot;
}

// Answers per host from a queue: each lookup takes the next answer and the last one repeats. A host with no
// answers does not resolve. `silent` never answers at all.
@interface WebFakeResolver : NSObject <SPDFMacAIWebResolving>
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableArray<NSArray<NSString*>*>*>* answers;
@property(nonatomic) NSMutableArray<NSString*>* asked;
@property(nonatomic) BOOL silent;
- (void)answer:(NSString*)host with:(NSArray<NSString*>*)addresses;
@end

@implementation WebFakeResolver
- (instancetype)init {
    if ((self = [super init])) { _answers = [NSMutableDictionary dictionary]; _asked = [NSMutableArray array]; }
    return self;
}
- (void)answer:(NSString*)host with:(NSArray<NSString*>*)addresses {
    if (!_answers[host]) _answers[host] = [NSMutableArray array];
    [_answers[host] addObject:addresses];
}
- (void)resolveHost:(NSString*)host completion:(SPDFMacAIWebResolution)completion {
    NSArray* addresses = nil;
    @synchronized(self) {
        [_asked addObject:host];
        NSMutableArray* queue = _answers[host];
        addresses = queue.firstObject;
        if (queue.count > 1) [queue removeObjectAtIndex:0];
    }
    if (_silent) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        completion(addresses, addresses ? nil : SPDFMacAIWebMakeError(SPDFMacAIWebErrorNotFound, @"not found"));
    });
}
@end

// One recorded connection attempt.
@interface WebConnection : NSObject
@property(nonatomic, copy) NSString* address;
@property(nonatomic, copy) NSString* serverName;
@property(nonatomic) uint16_t port;
@property(nonatomic, copy) NSString* request;
@property(nonatomic) NSUInteger delivered;  // response bytes handed to the reader
@property(nonatomic) BOOL stoppedByReader; // the reader returned NO before the response ended
@property(nonatomic) BOOL cancelled;
@end
@implementation WebConnection
@end

// `respond` gives the response for a connection as chunks, or nil to fail it as unreachable. `hang` never answers.
@interface WebFakeConnector : NSObject <SPDFMacAIWebConnecting>
@property(nonatomic, copy) NSArray<NSData*>* (^respond)(WebConnection* connection);
@property(nonatomic) NSMutableArray<WebConnection*>* connections;
@property(nonatomic) BOOL hang;
@end

@implementation WebFakeConnector
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
    if (!_hang) {
        NSArray<NSData*>* chunks = _respond ? _respond(connection) : nil;
        dispatch_async(queue, ^{
            if (over) return;
            if (!chunks) {
                over = YES;
                finished(SPDFMacAIWebMakeError(SPDFMacAIWebErrorUnreachable, @"unreachable"));
                return;
            }
            for (NSData* chunk in chunks) {
                connection.delivered += chunk.length;
                if (!receive(chunk)) { connection.stoppedByReader = chunk != chunks.lastObject; break; }
            }
            over = YES;
            finished(nil);
        });
    }
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

static NSArray<NSData*>* WebChunks(NSData* data, NSUInteger size) {
    NSMutableArray* chunks = [NSMutableArray array];
    for (NSUInteger offset = 0; offset < data.length; offset += size)
        [chunks addObject:[data subdataWithRange:NSMakeRange(offset, MIN(size, data.length - offset))]];
    return chunks;
}

@interface WebFakeSearchTransport : NSObject <SPDFMacAIWebSearchTransport>
@property(nonatomic) NSMutableArray<NSURLRequest*>* requests;
@property(nonatomic) NSInteger status;
@property(nonatomic) NSData* body;
@property(nonatomic) NSError* error;
@property(nonatomic) BOOL hang;
@property(nonatomic) NSUInteger cancels;
@end

@implementation WebFakeSearchTransport
- (instancetype)init {
    if ((self = [super init])) { _requests = [NSMutableArray array]; _status = 200; }
    return self;
}
- (dispatch_block_t)sendRequest:(NSURLRequest*)request reply:(SPDFMacAIWebSearchReply)reply {
    [_requests addObject:request];
    NSInteger status = _status;
    NSData* body = _body;
    NSError* error = _error;
    if (!_hang) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{ reply(status, body, error); });
    return ^{ self.cancels++; };
}
@end

static NSData* WebSearchBody(NSArray<NSDictionary*>* citations, NSInteger tokens) {
    NSMutableArray* annotations = [NSMutableArray array];
    for (NSDictionary* citation in citations) [annotations addObject:@{@"type" : @"url_citation",
    @"url_citation" : citation}];
    NSDictionary* JSON = @{@"choices" : @[@{@"message" : @{@"role" : @"assistant", @"content" : @"done",
                                                           @"annotations" : annotations}, @"finish_reason" : @"stop"}],
                           @"usage" : @{@"total_tokens" : @(tokens)}};
    return [NSJSONSerialization dataWithJSONObject:JSON options:0 error:nil];
}

static NSDictionary* WebJSON(NSData* data) {
    id JSON = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [JSON isKindOfClass:NSDictionary.class] ? JSON : nil;
}

// Stands between a provider and the chat's activity: records what the provider sent, raw, and forwards all of it. The
// activity keeps a link row's url and title only, so the rows' other fields are checked here, as sent.
@interface WebActivityRecorder : NSObject <SPDFMacAIActivityReporting>
- (instancetype)initWithActivity:(SPDFMacAIChatActivity*)activity;
@property(nonatomic, readonly) SPDFMacAIChatActivity* activity;
@property(nonatomic, readonly) NSMutableDictionary<NSString*, NSNumber*>* options; // by entry id
@property(nonatomic, readonly) NSMutableDictionary<NSString*, NSArray*>* links;    // the last rows sent, by entry id
@end

@implementation WebActivityRecorder
- (instancetype)initWithActivity:(SPDFMacAIChatActivity*)activity {
    if (!(self = [super init])) return nil;
    _activity = activity;
    _options = [NSMutableDictionary dictionary];
    _links = [NSMutableDictionary dictionary];
    return self;
}
- (NSString*)beginStepWithTitle:(NSString*)title detail:(NSString*)detail options:(SPDFMacAIActivityOptions)options
                         cancel:(dispatch_block_t)cancel {
    NSString* entry = [_activity beginStepWithTitle:title detail:detail options:options cancel:cancel];
    if (entry) _options[entry] = @(options);
    return entry;
}
- (NSString*)addCard:(NSDictionary*)card options:(SPDFMacAIActivityOptions)options
             handler:(SPDFMacAIActivityHandler)handler {
    NSString* entry = [_activity addCard:card options:options handler:handler];
    if (entry) _options[entry] = @(options);
    return entry;
}
- (NSString*)addImageAtPath:(NSString*)path caption:(NSString*)caption options:(SPDFMacAIActivityOptions)options {
    return [_activity addImageAtPath:path caption:caption options:options];
}
- (void)updateEntry:(NSString*)identifier changes:(NSDictionary*)changes {
    if (changes[SPDFMacAIActivityLinksKey]) _links[identifier] = changes[SPDFMacAIActivityLinksKey];
    [_activity updateEntry:identifier changes:changes];
}
- (void)setHandler:(SPDFMacAIActivityHandler)handler forEntry:(NSString*)identifier {
    [_activity setHandler:handler forEntry:identifier];
}
@end
