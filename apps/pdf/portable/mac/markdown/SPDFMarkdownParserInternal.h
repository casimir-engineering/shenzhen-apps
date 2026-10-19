#pragma once

#import "SPDFMarkdownModel.h"

NS_ASSUME_NONNULL_BEGIN

// Mutable block under construction while md4c callbacks stream in. Shared
// between the markdown parser (SPDFMarkdownParser.mm, which owns the
// @implementation) and the HTML-island translator (SPDFMarkdownHTMLBlocks.mm),
// which appends whitelisted builder subtrees in place of raw HTML islands.
@interface SPDFMarkdownBlockBuilder : NSObject
@property(nonatomic) SPDFMarkdownBlockKind kind;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger level;
@property(nonatomic) NSInteger orderedStart;
@property(nonatomic) NSInteger taskState;
@property(nonatomic) SPDFMarkdownTableAlignment tableAlignment;
@property(nonatomic) SPDFMarkdownTableAlignment blockAlignment;
@property(nonatomic) NSUInteger tableColumnCount;
@property(nonatomic, copy, nullable) NSString* codeLanguage;
@property(nonatomic, copy, nullable) NSString* codeInfo;
@property(nonatomic, copy, nullable) NSString* calloutKind;
@property(nonatomic, copy, nullable) NSString* calloutTitle;
// Raw HTML-island accumulation: an MD_BLOCK_HTML builder collects its
// MD_TEXT_HTML callbacks here and is replaced by translated builders when the
// island closes. Raw island text never reaches the frozen model.
@property(nonatomic) BOOL htmlIsland;
@property(nonatomic, nullable) NSMutableString* htmlText;
@property(nonatomic) NSMutableArray<SPDFMarkdownInlineRun*>* runs;
@property(nonatomic) NSMutableArray<SPDFMarkdownBlockBuilder*>* children;
@end

NS_ASSUME_NONNULL_END
