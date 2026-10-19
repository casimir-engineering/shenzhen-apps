#pragma once
// The readable text of a fetched page: what open_page hands the model. HTML is read by a single linear pass with no
// tree, no recursion, no scripts, styles or remote resources, so a hostile page cannot stall or crash it; the
// output stops at a byte limit (200 KB in open_page).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAIWebReadable : NSObject
@property(nonatomic, readonly, copy) NSString* title; // empty when the page has none
@property(nonatomic, readonly, copy) NSString* text;
@property(nonatomic, readonly) BOOL truncated;        // the text was cut at the limit
// The page's https links, absolute, in page order, at most 100: [{text, url}]. Text may be empty.
@property(nonatomic, readonly, copy) NSArray<NSDictionary<NSString*, NSString*>*>* links;
- (instancetype)initWithTitle:(NSString*)title text:(NSString*)text truncated:(BOOL)truncated
                        links:(NSArray<NSDictionary<NSString*, NSString*>*>*)links NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// The text of `body` as served with `contentType` (nil when the site sent none), links resolved against `baseURL`,
// at most `maxTextBytes` of UTF-8. nil and an UnsupportedContent error for content that is not text a person reads
// (a PDF, an image, an archive).
SPDFMacAIWebReadable* _Nullable SPDFMacAIWebReadableText(NSData* body, NSString* _Nullable contentType,
                                                         NSURL* baseURL, NSUInteger maxTextBytes, NSError** error);

// `body` as text: the charset the site declared (header, byte-order mark or HTML meta), else UTF-8, with invalid
// bytes replaced rather than failing the whole page (a body cut at the size limit may end mid-character).
NSString* SPDFMacAIWebDecodeText(NSData* body, NSString* _Nullable contentType, BOOL html);

NS_ASSUME_NONNULL_END
