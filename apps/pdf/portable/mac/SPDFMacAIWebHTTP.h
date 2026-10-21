#pragma once
// The one HTTP exchange open_page makes per hop, written and read by hand because the connection goes to an address
// that was checked (SPDFMacAIWebAddress.h), not to a name the system would resolve again. Pure: bytes in, bytes out.
#import <Foundation/Foundation.h>
#import "SPDFMacAIWebAddress.h"

NS_ASSUME_NONNULL_BEGIN

// Safari's own user agent on a Mac. Sites behind bot filters (CloudFront in front of hirose.com, measured 21 October
// 2026) answer 403 to anything else, so the page is asked for the way the person's browser would ask for it.
FOUNDATION_EXPORT NSString* const SPDFMacAIWebUserAgent;
// What open_page accepts, "gzip, deflate, br", as browsers do: some sites send nothing else. The decoded size has the
// same limit as an uncompressed body (SPDFMacAIWebDecoding.h).
FOUNDATION_EXPORT NSString* const SPDFMacAIWebAcceptEncoding;

// An Accept-Language value from the person's preferred languages, as Safari sends one: at most four, each as
// language-region ("zh-Hans-CN" becomes "zh-CN"), the bare language added after its first regional form, q falling by
// 0.1. "en" when none is usable.
NSString* SPDFMacAIWebAcceptLanguage(NSArray<NSString*>* preferredLanguages);

// GET over HTTP/1.1 as a browser on this Mac asks: Safari's user agent and Accept, `acceptLanguage`, gzip, deflate and
// br accepted. No cookies, credentials or referrer.
NSData* SPDFMacAIWebRequestData(SPDFMacAIWebTarget* target, NSString* acceptLanguage);

// The redirect target for a Location header, absolute, or nil when it is not a URL. The scheme and host are left to
// SPDFMacAIWebTargetForURL, which refuses each for its own reason.
NSURL* _Nullable SPDFMacAIWebRedirectURL(NSURL* base, NSString* _Nullable location);

// Reads one response as its bytes arrive. Status line and headers (at most 32 KB), then the body by Content-Length,
// chunked transfer coding or until the connection closes. A redirect completes at its headers, and the body stops at
// `bodyLimit`, so a hostile site cannot make open_page read without end. A PDF (served as application/pdf, or with
// any type when its bytes start with "%PDF-") reads up to `documentLimit` instead: datasheets are larger than pages.
@interface SPDFMacAIWebResponseParser : NSObject
- (instancetype)initWithBodyLimit:(NSUInteger)bodyLimit documentLimit:(NSUInteger)documentLimit
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithBodyLimit:(NSUInteger)bodyLimit; // documentLimit = bodyLimit
- (instancetype)init NS_UNAVAILABLE;
// NO once no more bytes are wanted: the response is complete, failed, or reached the body limit.
- (BOOL)appendData:(NSData*)data;
// The connection closed. Completes a body read until close; a shorter body than declared is kept as truncated.
- (void)finishAtEndOfStream;
@property(nonatomic, readonly) BOOL headersComplete;
@property(nonatomic, readonly) BOOL complete;
@property(nonatomic, readonly) NSInteger status;
@property(nonatomic, readonly, copy) NSString* reason;
@property(nonatomic, readonly) BOOL redirect; // 301, 302, 303, 307 or 308 with a Location
// The first value of a header, by case-insensitive name.
- (nullable NSString*)headerNamed:(NSString*)name;
// The body as the site sent it: still compressed when contentEncoding is set (SPDFMacAIWebDecoding.h).
@property(nonatomic, readonly) NSData* body;
@property(nonatomic, readonly, copy, nullable) NSString* contentEncoding; // "gzip", "deflate", "br" or nil
@property(nonatomic, readonly) BOOL document;                              // read as a PDF, with documentLimit
@property(nonatomic, readonly) NSUInteger bodyLimit;                      // the limit that applies now
@property(nonatomic, readonly) BOOL bodyTruncated;
@property(nonatomic, readonly, nullable) NSError* error;
@end

NS_ASSUME_NONNULL_END
