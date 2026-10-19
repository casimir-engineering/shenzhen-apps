#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownResourceStore;

typedef NS_ENUM(NSInteger, SPDFMarkdownBlockKind) {
    SPDFMarkdownBlockKindDocument,
    SPDFMarkdownBlockKindParagraph,
    SPDFMarkdownBlockKindHeading,
    SPDFMarkdownBlockKindBlockQuote,
    SPDFMarkdownBlockKindCallout,
    SPDFMarkdownBlockKindUnorderedList,
    SPDFMarkdownBlockKindOrderedList,
    SPDFMarkdownBlockKindListItem,
    SPDFMarkdownBlockKindCode,
    SPDFMarkdownBlockKindThematicBreak,
    SPDFMarkdownBlockKindTable,
    SPDFMarkdownBlockKindTableHead,
    SPDFMarkdownBlockKindTableBody,
    SPDFMarkdownBlockKindTableRow,
    SPDFMarkdownBlockKindTableHeaderCell,
    SPDFMarkdownBlockKindTableCell,
    SPDFMarkdownBlockKindPageBreak, // Structural only: no canonical text.
};

typedef NS_ENUM(NSInteger, SPDFMarkdownTableAlignment) {
    SPDFMarkdownTableAlignmentDefault,
    SPDFMarkdownTableAlignmentLeft,
    SPDFMarkdownTableAlignmentCenter,
    SPDFMarkdownTableAlignmentRight,
};

typedef NS_OPTIONS(NSUInteger, SPDFMarkdownInlineTraits) {
    SPDFMarkdownInlineTraitNone = 0,
    SPDFMarkdownInlineTraitEmphasis = 1 << 0,
    SPDFMarkdownInlineTraitStrong = 1 << 1,
    SPDFMarkdownInlineTraitCode = 1 << 2,
    SPDFMarkdownInlineTraitStrikethrough = 1 << 3,
    SPDFMarkdownInlineTraitLink = 1 << 4,
    SPDFMarkdownInlineTraitWikiLink = 1 << 5,
    SPDFMarkdownInlineTraitImage = 1 << 6,
    // LaTeX math span content ($...$ / $$...$$, delimiters stripped by the
    // parser). The run's text is the raw LaTeX; the renderer typesets it via
    // SPDFMarkdownMathTypesetter. Display math carries both Math and
    // DisplayMath.
    SPDFMarkdownInlineTraitMath = 1 << 7,
    SPDFMarkdownInlineTraitDisplayMath = 1 << 8,
    // Whitelisted inline HTML styling: <sub>/<sup> render as smaller
    // baseline-shifted runs (mirroring the math typesetter's scripts) and
    // <kbd> renders as a key-cap chip (smaller mono font on the inline-code
    // background). The visible text stays plain canonical text.
    SPDFMarkdownInlineTraitSubscript = 1 << 9,
    SPDFMarkdownInlineTraitSuperscript = 1 << 10,
    SPDFMarkdownInlineTraitKeyboard = 1 << 11,
    // <u>/<ins> draw a single underline; <mark> sets the highlight background.
    // Both are plain text attributes on the run, so they reach the screen, the
    // print pass and the PDF export through the one canonical string.
    SPDFMarkdownInlineTraitUnderline = 1 << 12,
    SPDFMarkdownInlineTraitHighlight = 1 << 13,
};

@interface SPDFMarkdownInlineRun : NSObject

@property(nonatomic, readonly, copy) NSString* text;
@property(nonatomic, readonly) SPDFMarkdownInlineTraits traits;
@property(nonatomic, readonly, copy, nullable) NSString* destination;
// Markdown title attribute (`![alt](src "title")` / `[text](href "title")`),
// surfaced as a tooltip on rendered links and image attachments.
@property(nonatomic, readonly, copy, nullable) NSString* title;
// HTML `<img width=… height=…>` display-size hints in points (0 = no hint).
// The renderer treats them as the preferred display size, keeps the existing
// image caps as maxima, and scales proportionally when only one is given.
@property(nonatomic, readonly) CGFloat preferredImageWidth;
@property(nonatomic, readonly) CGFloat preferredImageHeight;

- (instancetype)initWithText:(NSString*)text
                      traits:(SPDFMarkdownInlineTraits)traits
                 destination:(nullable NSString*)destination
                       title:(nullable NSString*)title
         preferredImageWidth:(CGFloat)preferredImageWidth
        preferredImageHeight:(CGFloat)preferredImageHeight NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithText:(NSString*)text
                      traits:(SPDFMarkdownInlineTraits)traits
                 destination:(nullable NSString*)destination
                       title:(nullable NSString*)title;
- (instancetype)initWithText:(NSString*)text
                      traits:(SPDFMarkdownInlineTraits)traits
                 destination:(nullable NSString*)destination;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface SPDFMarkdownBlock : NSObject

@property(nonatomic, readonly) SPDFMarkdownBlockKind kind;
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly) NSUInteger level;
@property(nonatomic, readonly) NSInteger orderedStart;
@property(nonatomic, readonly) NSInteger taskState;
@property(nonatomic, readonly) SPDFMarkdownTableAlignment tableAlignment;
// Paragraph/heading alignment requested by whitelisted HTML (`align`
// attributes, `<center>`, and container islands like `<div align="center">`
// that span multiple markdown blocks). Default means natural alignment.
@property(nonatomic, readonly) SPDFMarkdownTableAlignment blockAlignment;
@property(nonatomic, readonly) NSUInteger tableColumnCount;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownInlineRun*>* runs;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownBlock*>* children;
@property(nonatomic, readonly, copy, nullable) NSString* codeLanguage;
@property(nonatomic, readonly, copy, nullable) NSString* codeInfo;
@property(nonatomic, readonly, copy, nullable) NSString* calloutKind;
@property(nonatomic, readonly, copy, nullable) NSString* calloutTitle;
@property(nonatomic, readonly, copy) NSString* plainText;

- (instancetype)initWithKind:(SPDFMarkdownBlockKind)kind
                   blockIndex:(NSUInteger)blockIndex
                        level:(NSUInteger)level
                 orderedStart:(NSInteger)orderedStart
                    taskState:(NSInteger)taskState
               tableAlignment:(SPDFMarkdownTableAlignment)tableAlignment
               blockAlignment:(SPDFMarkdownTableAlignment)blockAlignment
             tableColumnCount:(NSUInteger)tableColumnCount
                         runs:(NSArray<SPDFMarkdownInlineRun*>*)runs
                     children:(NSArray<SPDFMarkdownBlock*>*)children
                 codeLanguage:(nullable NSString*)codeLanguage
                     codeInfo:(nullable NSString*)codeInfo
                  calloutKind:(nullable NSString*)calloutKind
                 calloutTitle:(nullable NSString*)calloutTitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithKind:(SPDFMarkdownBlockKind)kind
                   blockIndex:(NSUInteger)blockIndex
                        level:(NSUInteger)level
                 orderedStart:(NSInteger)orderedStart
                    taskState:(NSInteger)taskState
               tableAlignment:(SPDFMarkdownTableAlignment)tableAlignment
             tableColumnCount:(NSUInteger)tableColumnCount
                         runs:(NSArray<SPDFMarkdownInlineRun*>*)runs
                     children:(NSArray<SPDFMarkdownBlock*>*)children
                 codeLanguage:(nullable NSString*)codeLanguage
                     codeInfo:(nullable NSString*)codeInfo
                  calloutKind:(nullable NSString*)calloutKind
                 calloutTitle:(nullable NSString*)calloutTitle;
- (instancetype)init NS_UNAVAILABLE;

@end


@interface SPDFMarkdownHeading : NSObject

@property(nonatomic, readonly) NSUInteger level;
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly, copy) NSString* title;

- (instancetype)initWithLevel:(NSUInteger)level
                   blockIndex:(NSUInteger)blockIndex
                        title:(NSString*)title NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface SPDFMarkdownCodeFence : NSObject

@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly, copy, nullable) NSString* declaredLanguage;
@property(nonatomic, readonly, copy, nullable) NSString* infoString;
@property(nonatomic, readonly, copy) NSString* code;

- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                  declaredLanguage:(nullable NSString*)declaredLanguage
                        infoString:(nullable NSString*)infoString
                               code:(NSString*)code NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface SPDFMarkdownSearchMatch : NSObject

@property(nonatomic, readonly) NSRange range;
@property(nonatomic, readonly) NSUInteger blockIndex;
@property(nonatomic, readonly) NSInteger headingIndex;
@property(nonatomic, readonly, copy) NSString* context;

- (instancetype)initWithRange:(NSRange)range
                   blockIndex:(NSUInteger)blockIndex
                 headingIndex:(NSInteger)headingIndex
                      context:(NSString*)context NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface SPDFMarkdownDocumentModel : NSObject

@property(nonatomic, readonly, copy, nullable) NSURL* sourceURL;
@property(nonatomic, readonly, copy) NSDictionary<NSString*, NSString*>* frontMatter;
@property(nonatomic, readonly, copy, nullable) NSString* rawFrontMatter;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownBlock*>* blocks;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownHeading*>* headings;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownCodeFence*>* codeFences;
@property(nonatomic, readonly, strong, nullable) SPDFMarkdownResourceStore* resourceStore;

- (instancetype)initWithSourceURL:(nullable NSURL*)sourceURL
                      frontMatter:(NSDictionary<NSString*, NSString*>*)frontMatter
                   rawFrontMatter:(nullable NSString*)rawFrontMatter
                           blocks:(NSArray<SPDFMarkdownBlock*>*)blocks NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable SPDFMarkdownBlock*)blockWithIndex:(NSUInteger)blockIndex;

@end

NS_ASSUME_NONNULL_END
