#pragma once

#import <Foundation/Foundation.h>

#import "SPDFMarkdownModel.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SPDFMarkdownErrorDomain;

typedef NS_ERROR_ENUM(SPDFMarkdownErrorDomain, SPDFMarkdownErrorCode) {
    SPDFMarkdownErrorUnreadable = 1,
    SPDFMarkdownErrorTooLarge,
    SPDFMarkdownErrorInvalidUTF8,
    SPDFMarkdownErrorParseFailed,
    SPDFMarkdownErrorBudgetExceeded,
    SPDFMarkdownErrorNonFileURL,
};

@interface SPDFMarkdownParser : NSObject

@property(nonatomic) NSUInteger maximumInputBytes;
@property(nonatomic) NSUInteger maximumNodeCount;
@property(nonatomic) NSUInteger maximumNestingDepth;

- (nullable SPDFMarkdownDocumentModel*)loadURL:(NSURL*)url error:(NSError**)error;
- (nullable SPDFMarkdownDocumentModel*)parseData:(NSData*)data
                                        sourceURL:(nullable NSURL*)sourceURL
                                            error:(NSError**)error;
- (nullable SPDFMarkdownDocumentModel*)parseString:(NSString*)markdown
                                          sourceURL:(nullable NSURL*)sourceURL
                                              error:(NSError**)error;

@end

@interface SPDFMarkdownParser (Resources)

// Opens every path component relative to the document directory with O_NOFOLLOW
// and returns bytes from the validated descriptor. The URL is metadata only.
+ (nullable NSData*)localResourceDataForTarget:(NSString*)target
                         relativeToDocumentURL:(NSURL*)documentURL
                                      resolvedURL:(NSURL* _Nullable* _Nullable)resolvedURL;

@end

NS_ASSUME_NONNULL_END
