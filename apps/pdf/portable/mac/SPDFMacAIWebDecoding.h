#pragma once
// A compressed response body, decoded for open_page (SPDFMacAIWebFetcher.h). The limit counts DECODED bytes: a few
// kilobytes of gzip can expand to gigabytes, so the decoder stops at the limit instead of trusting what the site
// declared. Pure: bytes in, bytes out.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// `body` decoded from `encoding` ("gzip", "deflate" with or without its zlib wrapper, or "br"), at most `limit` bytes.
// *truncated is YES when the limit cut it or the compressed stream ended early (a body cut at the read limit or a
// dropped connection), so what came back is a prefix. nil and a BadResponse error when nothing decodes at all.
NSData* _Nullable SPDFMacAIWebDecodeBody(NSData* body, NSString* encoding, NSUInteger limit, BOOL* _Nullable truncated,
                                         NSError** error);

NS_ASSUME_NONNULL_END
