#pragma once

#import <AppKit/AppKit.h>

@class SPDFMarkdownPaginationPlan;

NS_ASSUME_NONNULL_BEGIN

// Print/export never repaginates: both consume the session's live pagination
// plan (current font scale, language overrides, and the reserved language
// control band), so output is page-for-page identical to the on-screen render.
@interface SPDFMacMarkdownPrintView : NSView
@property(nonatomic, readonly) SPDFMarkdownPaginationPlan* paginationPlan;
@property(nonatomic, readonly) NSAttributedString* attributedString;
- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
@end

@interface SPDFMacMarkdownPrintAdapter : NSObject
+ (NSPrintOperation*)printOperationForPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                                    attributedString:(NSAttributedString*)attributedString
                                           printInfo:(NSPrintInfo*)printInfo;
+ (BOOL)writePaginationPlan:(SPDFMarkdownPaginationPlan*)plan
           attributedString:(NSAttributedString*)attributedString
                      toURL:(NSURL*)URL
                      error:(NSError**)error;

// Single-page exports reuse the exact drawPageAtIndex path and the plan's
// paper size, so a copied page matches the corresponding printed/saved page.
+ (nullable NSData*)PDFDataForPageAtIndex:(NSUInteger)pageIndex
                           paginationPlan:(SPDFMarkdownPaginationPlan*)plan
                         attributedString:(NSAttributedString*)attributedString;
+ (nullable NSBitmapImageRep*)imageRepForPageAtIndex:(NSUInteger)pageIndex
                                      paginationPlan:(SPDFMarkdownPaginationPlan*)plan
                                    attributedString:(NSAttributedString*)attributedString
                                               scale:(CGFloat)scale;

// Pasteboard writers mirror the PDF tab's copy actions: Copy Page declares
// PDF data plus a temp-file URL named fileName; Copy Page Image writes an
// NSImage rasterized at 2x. Both clear the pasteboard first.
+ (BOOL)copyPageAtIndex:(NSUInteger)pageIndex
         paginationPlan:(SPDFMarkdownPaginationPlan*)plan
       attributedString:(NSAttributedString*)attributedString
               fileName:(NSString*)fileName
           toPasteboard:(NSPasteboard*)pasteboard;
+ (BOOL)copyPageImageAtIndex:(NSUInteger)pageIndex
              paginationPlan:(SPDFMarkdownPaginationPlan*)plan
            attributedString:(NSAttributedString*)attributedString
                toPasteboard:(NSPasteboard*)pasteboard;
@end

NS_ASSUME_NONNULL_END
