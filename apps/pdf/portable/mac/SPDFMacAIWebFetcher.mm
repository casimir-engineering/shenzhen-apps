#import "SPDFMacAIWebFetcher.h"
#import "SPDFMacAIWebAddress.h"
#import "SPDFMacAIWebDecoding.h"
#import "SPDFMacAIWebHTTP.h"

// A name with more addresses than this is tried on its first few only; each failed attempt costs a connect timeout.
static const NSUInteger kMaximumAddressAttempts = 3;
// A page with a password field and less text than this is a sign-in page, not an article with a sign-in box in its
// header (hirose.com's product pages hold 2,500 characters beside their "Login" link).
static const NSUInteger kSignInPageText = 1500;

@implementation SPDFMacAIWebPage
- (instancetype)initWithURL:(NSURL*)URL requested:(NSURL*)requested redirects:(NSUInteger)redirects
                    address:(NSString*)address readable:(SPDFMacAIWebReadable*)readable
                   document:(SPDFMacAIWebDocument*)document truncated:(BOOL)truncated {
    if (!(self = [super init])) return nil;
    _document = document;
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
    NSUInteger _maxRedirects, _maxBody, _maxDocument, _maxText;
    NSURL* _requested;
    NSURL* _documentFolder;
    NSString* _acceptLanguage;
    NSDate* _started;
    NSTimeInterval _documentTimeout;
    BOOL _document; // the answer is a PDF: its own size limit and deadline
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
    SPDFMacAIWebResponseParser* parser = [[SPDFMacAIWebResponseParser alloc] initWithBodyLimit:_maxBody
                                                                                  documentLimit:_maxDocument];
    NSString* address = addresses[index];
    __block BOOL received = NO;
    _cancelStep = [_connector exchangeRequest:SPDFMacAIWebRequestData(target, _acceptLanguage) address:address
                                         port:target.port
                                   serverName:target.literalAddress ? nil : target.host queue:_queue
                                      receive:^BOOL(NSData* bytes) {
        if (self->_done || generation != self->_generation) return NO;
        received = YES;
        BOOL more = [parser appendData:bytes];
        self->_document = self->_document || parser.document;
        return more;
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
    if (parser.status == 401 || parser.status == 407) {
        [self fail:SPDFMacAIWebErrorSignInRequired message:@"The site asks for a sign-in to show this page, so "
               "open_page did not read it. Do not look for a way around the sign-in."];
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
    NSData* body = parser.body;
    BOOL cut = parser.bodyTruncated;
    if (parser.contentEncoding) {
        BOOL decodedCut = NO;
        body = SPDFMacAIWebDecodeBody(body, parser.contentEncoding, parser.bodyLimit, &decodedCut, &error);
        if (!body) { [self finishPage:nil error:error]; return; }
        cut = cut || decodedCut;
    }
    if (parser.document || (body.length >= 5 && !memcmp(body.bytes, "%PDF-", 5))) {
        [self finishDocument:body cut:cut target:target address:address];
        return;
    }
    SPDFMacAIWebReadable* readable = SPDFMacAIWebReadableText(body, [parser headerNamed:@"content-type"], target.URL,
                                                              _maxText, &error);
    if (!readable) { [self finishPage:nil error:error]; return; }
    if (readable.markup && readable.text.length < kSignInPageText && SPDFMacAIWebHasPasswordField(body)) {
        [self fail:SPDFMacAIWebErrorSignInRequired message:@"The page is a sign-in form, so open_page did not read "
               "it. Do not look for a way around the sign-in."];
        return;
    }
    [self finishPage:[[SPDFMacAIWebPage alloc] initWithURL:target.URL requested:_requested redirects:_redirects
                                                   address:address readable:readable document:nil
                                                 truncated:readable.truncated || cut]
               error:nil];
}

// A PDF: saved whole for the reader's engine, or refused. A prefix of a PDF is not a readable PDF (its page index
// is at the end), so a cut one is too large rather than truncated.
- (void)finishDocument:(NSData*)body cut:(BOOL)cut target:(SPDFMacAIWebTarget*)target address:(NSString*)address {
    if (cut && body.length >= _maxDocument) {
        [self fail:SPDFMacAIWebErrorTooLarge message:[NSString stringWithFormat:@"The PDF is larger than the %lu MB "
               "open_page reads.", (unsigned long)(_maxDocument / (1024 * 1024))]];
        return;
    }
    if (cut) {
        [self fail:SPDFMacAIWebErrorBadResponse message:@"The site stopped sending the PDF part way."];
        return;
    }
    NSError* error = nil;
    SPDFMacAIWebDocument* document = SPDFMacAIWebStoreDocument(body, target.URL, _documentFolder, &error);
    if (!document) { [self finishPage:nil error:error]; return; }
    SPDFMacAIWebReadable* readable = [[SPDFMacAIWebReadable alloc] initWithTitle:document.title text:@"" truncated:NO
                                                                           links:@[]];
    [self finishPage:[[SPDFMacAIWebPage alloc] initWithURL:target.URL requested:_requested redirects:_redirects
                                                   address:address readable:readable document:document truncated:NO]
               error:nil];
}

// The deadline: a PDF's answer gets documentTimeout from the start, a page's only the timeout. The timer holds the
// fetch, so a resolver or site that never answers still ends it.
- (void)deadlineAfter:(NSTimeInterval)timeout {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _queue, ^{
        if (self->_done) return;
        NSTimeInterval left = self->_documentTimeout + self->_started.timeIntervalSinceNow;
        if (self->_document && left > 0.05) { [self deadlineAfter:left]; return; }
        [self fail:SPDFMacAIWebErrorTimedOut message:@"The site took too long to answer."];
    });
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
    _documentTimeout = 90;
    _maxRedirects = 5;
    _maxBodyBytes = 2 * 1024 * 1024;
    _maxDocumentBytes = 32 * 1024 * 1024;
    _maxTextBytes = 200 * 1024;
    _documentFolder = SPDFMacAIWebDocumentDefaultFolder();
    return self;
}

- (dispatch_block_t)fetchURL:(NSURL*)URL completion:(SPDFMacAIWebPageCompletion)completion {
    SPDFMacAIWebFetch* fetch = [SPDFMacAIWebFetch new];
    fetch->_resolver = _resolver;
    fetch->_connector = _connector;
    fetch->_queue = dispatch_queue_create("ShenzhenPDF.AI.Web.Fetch", DISPATCH_QUEUE_SERIAL);
    fetch->_maxRedirects = _maxRedirects;
    fetch->_maxBody = _maxBodyBytes;
    fetch->_maxDocument = MAX(_maxDocumentBytes, _maxBodyBytes);
    fetch->_maxText = _maxTextBytes;
    fetch->_requested = URL;
    fetch->_documentFolder = _documentFolder;
    fetch->_acceptLanguage = _acceptLanguage ?: SPDFMacAIWebAcceptLanguage(NSLocale.preferredLanguages);
    fetch->_started = [NSDate date];
    fetch->_documentTimeout = MAX(_documentTimeout, _timeout);
    fetch->_completion = [completion copy];
    dispatch_queue_t queue = fetch->_queue;
    NSTimeInterval timeout = _timeout;
    dispatch_async(queue, ^{
        [fetch deadlineAfter:timeout];
        [fetch openURL:URL];
    });
    return ^{
        dispatch_async(queue, ^{ [fetch fail:SPDFMacAIWebErrorCancelled message:@"The page request was stopped."]; });
    };
}

@end
