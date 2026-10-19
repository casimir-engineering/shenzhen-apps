#import "SPDFMacAIWebFetcher.h"
#import "SPDFMacAIWebAddress.h"
#import "SPDFMacAIWebHTTP.h"

// A name with more addresses than this is tried on its first few only; each failed attempt costs a connect timeout.
static const NSUInteger kMaximumAddressAttempts = 3;

@implementation SPDFMacAIWebPage
- (instancetype)initWithURL:(NSURL*)URL requested:(NSURL*)requested redirects:(NSUInteger)redirects
                    address:(NSString*)address readable:(SPDFMacAIWebReadable*)readable truncated:(BOOL)truncated {
    if (!(self = [super init])) return nil;
    _URL = URL;
    _requestedURL = requested;
    _redirects = redirects;
    _address = [address copy];
    _readable = readable;
    _truncated = truncated;
    return self;
}
@end

// One fetch, on its own serial queue. `_generation` drops callbacks from a step that was abandoned (a timeout, a
// retry on the next address) so a late answer cannot finish a fetch twice or resurrect it.
@interface SPDFMacAIWebFetch : NSObject
@end

@implementation SPDFMacAIWebFetch {
  @public
    id<SPDFMacAIWebResolving> _resolver;
    id<SPDFMacAIWebConnecting> _connector;
    dispatch_queue_t _queue;
    NSUInteger _maxRedirects, _maxBody, _maxText;
    NSURL* _requested;
    NSUInteger _redirects;
    SPDFMacAIWebPageCompletion _completion;
    dispatch_block_t _cancelStep;
    NSUInteger _generation;
    BOOL _done;
}

- (void)finishPage:(SPDFMacAIWebPage*)page error:(NSError*)error {
    if (_done) return;
    _done = YES;
    ++_generation;
    dispatch_block_t cancel = _cancelStep;
    _cancelStep = nil;
    if (cancel && !page) cancel();
    SPDFMacAIWebPageCompletion completion = _completion;
    _completion = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(page, page ? nil : error); });
}

- (void)fail:(SPDFMacAIWebError)code message:(NSString*)message {
    [self finishPage:nil error:SPDFMacAIWebMakeError(code, message)];
}

- (void)openURL:(NSURL*)URL {
    NSError* error = nil;
    SPDFMacAIWebTarget* target = SPDFMacAIWebTargetForURL(URL, &error);
    if (!target) { [self finishPage:nil error:error]; return; }
    if (target.literalAddress) { [self connect:target addresses:@[target.literalAddress] index:0]; return; }
    NSUInteger generation = ++_generation;
    [_resolver resolveHost:target.host completion:^(NSArray<NSString*>* addresses, NSError* failure) {
        dispatch_async(self->_queue, ^{
            if (self->_done || generation != self->_generation) return;
            if (!addresses.count) {
                [self finishPage:nil error:failure ?: SPDFMacAIWebMakeError(SPDFMacAIWebErrorNotFound,
                    [NSString stringWithFormat:@"%@ could not be found.", target.host])];
                return;
            }
            for (NSString* address in addresses) {
                // One private answer refuses the name. A public site never needs one, and answers that mix public
                // and private addresses are how a rebinding attack chooses which one a client connects to.
                NSString* refusal = SPDFMacAIWebAddressRefusal(address);
                if (!refusal) continue;
                [self fail:SPDFMacAIWebErrorPrivateAddress message:[NSString stringWithFormat:@"%@ points to %@. %@",
                                                                    target.host, address, refusal]];
                return;
            }
            [self connect:target addresses:addresses index:0];
        });
    }];
}

- (void)connect:(SPDFMacAIWebTarget*)target addresses:(NSArray<NSString*>*)addresses index:(NSUInteger)index {
    NSUInteger generation = ++_generation;
    SPDFMacAIWebResponseParser* parser = [[SPDFMacAIWebResponseParser alloc] initWithBodyLimit:_maxBody];
    NSString* address = addresses[index];
    __block BOOL received = NO;
    _cancelStep = [_connector exchangeRequest:SPDFMacAIWebRequestData(target) address:address port:target.port
                                   serverName:target.literalAddress ? nil : target.host queue:_queue
                                      receive:^BOOL(NSData* bytes) {
        if (self->_done || generation != self->_generation) return NO;
        received = YES;
        return [parser appendData:bytes];
    } finished:^(NSError* error) {
        if (self->_done || generation != self->_generation) return;
        self->_cancelStep = nil;
        if (error && !received) {
            // The name's next address may answer where this one did not (IPv6 listed first on a network where it
            // fails). Every one of them was checked above.
            if (error.code == SPDFMacAIWebErrorUnreachable && index + 1 < MIN(addresses.count, kMaximumAddressAttempts))
                [self connect:target addresses:addresses index:index + 1];
            else [self finishPage:nil error:error];
            return;
        }
        // A connection that drops mid-body still leaves a readable prefix; the parser marks it truncated.
        [parser finishAtEndOfStream];
        if (parser.error) { [self finishPage:nil error:parser.error]; return; }
        [self handleResponse:parser target:target address:address];
    }];
}

- (void)handleResponse:(SPDFMacAIWebResponseParser*)parser target:(SPDFMacAIWebTarget*)target
               address:(NSString*)address {
    if (parser.redirect) {
        NSURL* next = SPDFMacAIWebRedirectURL(target.URL, [parser headerNamed:@"location"]);
        if (!next) {
            [self fail:SPDFMacAIWebErrorBadResponse message:@"The site redirected to an invalid address."];
            return;
        }
        if (_redirects >= _maxRedirects) {
            [self fail:SPDFMacAIWebErrorTooManyRedirects message:[NSString stringWithFormat:@"The site redirected "
                "more than %lu times, so open_page stopped following it.", (unsigned long)_maxRedirects]];
            return;
        }
        if (![next.scheme.lowercaseString isEqual:@"https"]) {
            [self fail:SPDFMacAIWebErrorNotHTTPS message:@"The site redirected to an address that is not https, so "
                   "open_page did not follow it."];
            return;
        }
        _redirects++;
        [self openURL:next]; // the new host is checked from the start: its name, its addresses, every one of them
        return;
    }
    if (parser.status < 200 || parser.status > 299) {
        NSString* message = [NSString stringWithFormat:@"The site answered %ld%@%@.", (long)parser.status,
                             parser.reason.length ? @" " : @"", parser.reason];
        [self finishPage:nil error:[NSError errorWithDomain:SPDFMacAIWebErrorDomain code:SPDFMacAIWebErrorHTTPStatus
            userInfo:@{NSLocalizedDescriptionKey : message, SPDFMacAIWebHTTPStatusKey : @(parser.status)}]];
        return;
    }
    NSError* error = nil;
    SPDFMacAIWebReadable* readable = SPDFMacAIWebReadableText(parser.body, [parser headerNamed:@"content-type"],
                                                              target.URL, _maxText, &error);
    if (!readable) { [self finishPage:nil error:error]; return; }
    [self finishPage:[[SPDFMacAIWebPage alloc] initWithURL:target.URL requested:_requested redirects:_redirects
                                                   address:address readable:readable
                                                 truncated:readable.truncated || parser.bodyTruncated]
               error:nil];
}

@end

@implementation SPDFMacAIWebFetcher {
    id<SPDFMacAIWebResolving> _resolver;
    id<SPDFMacAIWebConnecting> _connector;
}

- (instancetype)init {
    return [self initWithResolver:[SPDFMacAIWebSystemResolver new] connector:[SPDFMacAIWebTLSConnector new]];
}

- (instancetype)initWithResolver:(id<SPDFMacAIWebResolving>)resolver connector:(id<SPDFMacAIWebConnecting>)connector {
    if (!(self = [super init])) return nil;
    _resolver = resolver;
    _connector = connector;
    _timeout = 30;
    _maxRedirects = 3;
    _maxBodyBytes = 2 * 1024 * 1024;
    _maxTextBytes = 200 * 1024;
    return self;
}

- (dispatch_block_t)fetchURL:(NSURL*)URL completion:(SPDFMacAIWebPageCompletion)completion {
    SPDFMacAIWebFetch* fetch = [SPDFMacAIWebFetch new];
    fetch->_resolver = _resolver;
    fetch->_connector = _connector;
    fetch->_queue = dispatch_queue_create("ShenzhenPDF.AI.Web.Fetch", DISPATCH_QUEUE_SERIAL);
    fetch->_maxRedirects = _maxRedirects;
    fetch->_maxBody = _maxBodyBytes;
    fetch->_maxText = _maxTextBytes;
    fetch->_requested = URL;
    fetch->_completion = [completion copy];
    dispatch_queue_t queue = fetch->_queue;
    dispatch_async(queue, ^{ [fetch openURL:URL]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_timeout * NSEC_PER_SEC)), queue, ^{
        [fetch fail:SPDFMacAIWebErrorTimedOut message:@"The site took too long to answer."];
    });
    return ^{
        dispatch_async(queue, ^{ [fetch fail:SPDFMacAIWebErrorCancelled message:@"The page request was stopped."]; });
    };
}

@end
