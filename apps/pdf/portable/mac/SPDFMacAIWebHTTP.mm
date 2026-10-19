#import "SPDFMacAIWebHTTP.h"

// "compatible" in the style of other fetchers: sites that turn away anything without "Mozilla" still answer, and it
// claims no browser, operating system or language.
NSString* const SPDFMacAIWebUserAgent = @"Mozilla/5.0 (compatible; ShenzhenPDF)";

static const NSUInteger kMaximumHeaderBytes = 32 * 1024;
static const NSUInteger kMaximumChunkLine = 1024;
static const NSUInteger kMaximumTrailerBytes = 8 * 1024;
// 100 Continue and 103 Early Hints may precede the answer; more than a few is a site stalling on purpose.
static const NSUInteger kMaximumInformational = 4;

NSData* SPDFMacAIWebRequestData(SPDFMacAIWebTarget* target) {
    NSString* request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: %@\r\n"
        "Accept: text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1\r\nAccept-Encoding: identity\r\n"
        "Connection: close\r\n\r\n", target.requestTarget, target.hostHeader, SPDFMacAIWebUserAgent];
    return [request dataUsingEncoding:NSASCIIStringEncoding];
}

NSURL* SPDFMacAIWebRedirectURL(NSURL* base, NSString* location) {
    NSString* text = [location stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!text.length || text.length > 2048) return nil;
    // A host is not required here: file:///etc/passwd must reach the scheme check and be refused for its scheme.
    NSURL* URL = [NSURL URLWithString:text relativeToURL:base].absoluteURL;
    return URL.scheme.length ? URL : nil;
}

typedef NS_ENUM(NSInteger, SPDFWebParseMode) {
    SPDFWebParseHeaders, SPDFWebParseLength, SPDFWebParseUntilClose, SPDFWebParseChunkSize, SPDFWebParseChunkData,
    SPDFWebParseChunkEnd, SPDFWebParseTrailers, SPDFWebParseDone,
};

@implementation SPDFMacAIWebResponseParser {
    NSUInteger _limit;
    NSMutableData* _pending; // header bytes, or a chunk-size or trailer line, until it is whole
    NSMutableData* _body;
    NSMutableArray<NSArray<NSString*>*>* _headers;
    SPDFWebParseMode _mode;
    unsigned long long _remaining; // bytes left of the declared length or of the current chunk
    NSUInteger _informational;
    NSUInteger _trailerBytes;
}

- (instancetype)initWithBodyLimit:(NSUInteger)bodyLimit {
    if (!(self = [super init])) return nil;
    _limit = bodyLimit;
    _pending = [NSMutableData data];
    _body = [NSMutableData data];
    _headers = [NSMutableArray array];
    _reason = @"";
    return self;
}

- (NSData*)body { return [_body copy]; }

- (NSString*)headerNamed:(NSString*)name {
    NSString* wanted = name.lowercaseString;
    for (NSArray<NSString*>* header in _headers) if ([header[0] isEqual:wanted]) return header[1];
    return nil;
}

- (void)failWith:(SPDFMacAIWebError)code message:(NSString*)message {
    _error = SPDFMacAIWebMakeError(code, message);
    _mode = SPDFWebParseDone;
}

- (void)finishBody {
    _complete = YES;
    _mode = SPDFWebParseDone;
}

- (void)appendBody:(const uint8_t*)bytes length:(NSUInteger)length {
    NSUInteger room = _limit > _body.length ? _limit - _body.length : 0;
    [_body appendBytes:bytes length:MIN(room, length)];
    // Bytes past the limit: the limit, not the site, ends the read, and what was kept is a prefix of the page. A body
    // that fills the limit exactly and then ends is complete.
    if (length > room) {
        _bodyTruncated = YES;
        [self finishBody];
    }
}

// The status line and headers of one response. NO when they are not HTTP/1.x.
- (BOOL)parseHead:(NSData*)head {
    NSString* text = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
    NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];
    NSString* statusLine =
        [lines.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString*>* words = [statusLine componentsSeparatedByString:@" "];
    if (words.count < 2 || ![words[0] hasPrefix:@"HTTP/1."] || [words[1] length] != 3 ||
        [words[1] rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
        return NO;
    NSMutableArray* headers = [NSMutableArray array];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString* line = [lines[index] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (!line.length) continue;
        unichar first = [line characterAtIndex:0];
        NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ((first == ' ' || first == '\t') && headers.count) { // an obsolete folded continuation
            NSArray* last = headers.lastObject;
            headers[headers.count - 1] = @[last[0], [NSString stringWithFormat:@"%@ %@", last[1], trimmed]];
            continue;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || !colon.location) return NO;
        NSString* name = [line substringToIndex:colon.location].lowercaseString;
        if ([name rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) return NO;
        NSString* value = [[line substringFromIndex:NSMaxRange(colon)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [headers addObject:@[name, value]];
    }
    _status = [words[1] integerValue];
    _reason = words.count > 2 ? [[words subarrayWithRange:NSMakeRange(2, words.count - 2)]
                                    componentsJoinedByString:@" "] : @"";
    _headers = headers;
    return YES;
}

// Chooses how the body is read once the headers are known.
- (void)beginBody {
    if (_status >= 100 && _status < 200) {
        if (_status == 101 || ++_informational > kMaximumInformational) {
            [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site did not answer with a page."];
            return;
        }
        [_headers removeAllObjects];
        _status = 0;
        return; // the real answer follows
    }
    _headersComplete = YES;
    NSArray* redirects = @[@301, @302, @303, @307, @308];
    if ([redirects containsObject:@(_status)] && [self headerNamed:@"location"].length) {
        _redirect = YES;
        [self finishBody];
        return;
    }
    if (_status == 204 || _status == 304) { [self finishBody]; return; }
    NSString* encoding = [self headerNamed:@"content-encoding"].lowercaseString;
    if (encoding.length && ![encoding isEqual:@"identity"]) {
        [self failWith:SPDFMacAIWebErrorUnsupportedContent
               message:[NSString stringWithFormat:@"The site sent the page compressed (%@), which open_page "
                        "cannot read.", encoding]];
        return;
    }
    NSString* transfer = [self headerNamed:@"transfer-encoding"].lowercaseString;
    if (transfer) {
        NSMutableArray* codings = [NSMutableArray array];
        for (NSString* coding in [transfer componentsSeparatedByString:@","]) {
            NSString* name = [coding stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (name.length && ![name isEqual:@"identity"]) [codings addObject:name];
        }
        if (codings.count == 1 && [codings[0] isEqual:@"chunked"]) { _mode = SPDFWebParseChunkSize; return; }
        if (codings.count) {
            [self failWith:SPDFMacAIWebErrorUnsupportedContent message:@"The site sent the page in a transfer "
                   "coding open_page cannot read."];
            return;
        }
    }
    NSString* declared = nil;
    for (NSArray<NSString*>* header in _headers) {
        if (![header[0] isEqual:@"content-length"]) continue;
        for (NSString* part in [header[1] componentsSeparatedByString:@","]) {
            NSString* value = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            BOOL digits = value.length && value.length <= 15 &&
                [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location ==
                    NSNotFound;
            // Two different lengths is how request smuggling starts; refuse rather than pick one.
            if (!digits || (declared && ![declared isEqual:value])) {
                [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site sent a malformed response."];
                return;
            }
            declared = value;
        }
    }
    if (!declared) { _mode = SPDFWebParseUntilClose; return; }
    _remaining = strtoull(declared.UTF8String, NULL, 10);
    if (!_remaining) [self finishBody];
    else _mode = SPDFWebParseLength;
}

// A whole line from _pending plus `bytes`, or nil while it is still incomplete. *used is what it took from `bytes`.
- (NSString*)lineFrom:(const uint8_t*)bytes length:(NSUInteger)length used:(NSUInteger*)used limit:(NSUInteger)limit {
    const uint8_t* newline = (const uint8_t*)memchr(bytes, '\n', length);
    NSUInteger take = newline ? (NSUInteger)(newline - bytes) + 1 : length;
    *used = take;
    if (_pending.length + take > limit) {
        [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site sent a malformed response."];
        return nil;
    }
    [_pending appendBytes:bytes length:take];
    if (!newline) return nil;
    NSString* line = [[NSString alloc] initWithData:_pending encoding:NSISOLatin1StringEncoding];
    _pending = [NSMutableData data];
    return [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (BOOL)appendData:(NSData*)data {
    NSData* input = data;
    NSUInteger offset = 0;
    while (offset < input.length && _mode != SPDFWebParseDone) {
        const uint8_t* bytes = (const uint8_t*)input.bytes + offset;
        NSUInteger length = input.length - offset, used = 0;
        switch (_mode) {
            case SPDFWebParseHeaders: {
                [_pending appendBytes:bytes length:length];
                offset = input.length;
                NSRange end = [_pending rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0
                                              range:NSMakeRange(0, _pending.length)];
                if (end.location == NSNotFound || end.location > kMaximumHeaderBytes) {
                    if (_pending.length > kMaximumHeaderBytes)
                        [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site sent oversized headers."];
                    break;
                }
                NSData* head = [_pending subdataWithRange:NSMakeRange(0, end.location)];
                input = [_pending subdataWithRange:NSMakeRange(NSMaxRange(end), _pending.length - NSMaxRange(end))];
                offset = 0;
                _pending = [NSMutableData data];
                if (![self parseHead:head]) {
                    [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site did not answer with HTTP."];
                    break;
                }
                [self beginBody];
                break;
            }
            case SPDFWebParseLength:
            case SPDFWebParseChunkData: {
                NSUInteger take = (NSUInteger)MIN((unsigned long long)length, _remaining);
                [self appendBody:bytes length:take];
                offset += take;
                _remaining -= take;
                if (_mode == SPDFWebParseDone) break;
                if (_remaining) break;
                if (_mode == SPDFWebParseLength) [self finishBody];
                else _mode = SPDFWebParseChunkEnd;
                break;
            }
            case SPDFWebParseUntilClose:
                [self appendBody:bytes length:length];
                offset = input.length;
                break;
            case SPDFWebParseChunkSize: {
                NSString* line = [self lineFrom:bytes length:length used:&used limit:kMaximumChunkLine];
                offset += used;
                if (!line) break;
                NSString* size = [line componentsSeparatedByString:@";"].firstObject;
                size = [size stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSCharacterSet* hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
                if (!size.length || size.length > 12 || [size rangeOfCharacterFromSet:hex.invertedSet].location !=
                    NSNotFound) {
                    [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site sent a malformed response."];
                    break;
                }
                _remaining = strtoull(size.UTF8String, NULL, 16);
                _mode = _remaining ? SPDFWebParseChunkData : SPDFWebParseTrailers;
                break;
            }
            case SPDFWebParseChunkEnd:
                // The CRLF after a chunk's data; a bare LF is accepted like most clients do.
                if (bytes[0] == '\n') _mode = SPDFWebParseChunkSize;
                else if (bytes[0] != '\r')
                    [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site sent a malformed response."];
                offset++;
                break;
            case SPDFWebParseTrailers: {
                NSString* line = [self lineFrom:bytes length:length used:&used limit:kMaximumChunkLine];
                offset += used;
                _trailerBytes += used;
                if (_trailerBytes > kMaximumTrailerBytes)
                    [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site sent a malformed response."];
                else if (line && !line.length) [self finishBody];
                break;
            }
            case SPDFWebParseDone: break;
        }
    }
    return _mode != SPDFWebParseDone;
}

- (void)finishAtEndOfStream {
    if (_mode == SPDFWebParseDone) return;
    if (_mode == SPDFWebParseHeaders) {
        [self failWith:SPDFMacAIWebErrorBadResponse message:@"The site closed the connection without answering."];
        return;
    }
    // Closing mid-body leaves a prefix of the page: still worth reading, so it is kept and marked truncated.
    if (_mode != SPDFWebParseUntilClose) _bodyTruncated = YES;
    [self finishBody];
}

@end
