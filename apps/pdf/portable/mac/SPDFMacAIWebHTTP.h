#pragma once
// The one HTTP exchange open_page makes per hop, written and read by hand because the connection goes to an address
// that was checked (SPDFMacAIWebAddress.h), not to a name the system would resolve again. Pure: bytes in, bytes out.
#import <Foundation/Foundation.h>
#import "SPDFMacAIWebAddress.h"

NS_ASSUME_NONNULL_BEGIN

// Says what fetched the page and nothing about the person or their Mac.
FOUNDATION_EXPORT NSString* const SPDFMacAIWebUserAgent;

// GET over HTTP/1.1 with no cookies, credentials or referrer, the plain user agent, and identity encoding so the
// body the size limit counts is the body the site sent.
NSData* SPDFMacAIWebRequestData(SPDFMacAIWebTarget* target);

// The redirect target for a Location header, absolute, or nil when it is not a URL. The scheme and host are left to
// SPDFMacAIWebTargetForURL, which refuses each for its own reason.
NSURL* _Nullable SPDFMacAIWebRedirectURL(NSURL* base, NSString* _Nullable location);

// Reads one response as its bytes arrive. Status line and headers (at most 32 KB), then the body by Content-Length,
// chunked transfer coding or until the connection closes. A redirect completes at its headers, and the body stops at
// `bodyLimit`, so a hostile site cannot make open_page read without end.
@interface SPDFMacAIWebResponseParser : NSObject
- (instancetype)initWithBodyLimit:(NSUInteger)bodyLimit NS_DESIGNATED_INITIALIZER;
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
@property(nonatomic, readonly) NSData* body;
@property(nonatomic, readonly) BOOL bodyTruncated;
@property(nonatomic, readonly, nullable) NSError* error;
@end

NS_ASSUME_NONNULL_END
