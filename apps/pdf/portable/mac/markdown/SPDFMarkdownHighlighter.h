#pragma once

#import <Foundation/Foundation.h>

#import "SPDFMarkdownLanguage.h"
#import "SPDFMarkdownAsync.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMarkdownSyntaxTokenKind) {
    SPDFMarkdownSyntaxTokenKeyword,
    SPDFMarkdownSyntaxTokenString,
    SPDFMarkdownSyntaxTokenComment,
    SPDFMarkdownSyntaxTokenNumber,
    SPDFMarkdownSyntaxTokenKey,
    SPDFMarkdownSyntaxTokenMarkup,
};

@interface SPDFMarkdownSyntaxToken : NSObject
@property(nonatomic, readonly) NSRange range;
@property(nonatomic, readonly) SPDFMarkdownSyntaxTokenKind kind;
- (instancetype)initWithRange:(NSRange)range
                         kind:(SPDFMarkdownSyntaxTokenKind)kind NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end


@interface SPDFMarkdownHighlighter : NSObject
- (NSArray<SPDFMarkdownSyntaxToken*>*)tokensForCode:(NSString*)code
                                           language:(SPDFMarkdownLanguage*)language;
- (NSArray<SPDFMarkdownSyntaxToken*>*)tokensForCode:(NSString*)code
                                           language:(SPDFMarkdownLanguage*)language
                                  cancellationToken:(nullable SPDFMarkdownCancellationToken*)cancellationToken;
@end

NS_ASSUME_NONNULL_END
