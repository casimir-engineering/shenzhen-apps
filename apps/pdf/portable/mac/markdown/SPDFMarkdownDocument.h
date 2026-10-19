#pragma once

#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownParser.h"
#import "SPDFMarkdownAsync.h"

NS_ASSUME_NONNULL_BEGIN

// Read-only facade for later tab/session integration. Build it off the main
// thread, then create the NSTextView on the main thread.
@interface SPDFMarkdownDocument : NSObject
@property(nonatomic, readonly) SPDFMarkdownDocumentModel* model;
@property(nonatomic, readonly) SPDFMarkdownRenderedDocument* renderedDocument;
@property(nonatomic, readonly) SPDFMarkdownRenderOptions* renderOptions;
// Nil unless the source requests paper geometry. Callers still pass the actual
// destination explicitly to the renderer/paginator, including manual rotation.
@property(nonatomic, readonly, nullable) SPDFMarkdownPageConfiguration* authoredPageConfiguration;
@property(nonatomic, readonly, copy) NSDictionary<NSNumber*, NSString*>* languageOverrides;

+ (nullable instancetype)documentWithURL:(NSURL*)URL
                                 options:(nullable SPDFMarkdownRenderOptions*)options
                                   error:(NSError**)error;
- (instancetype)initWithModel:(SPDFMarkdownDocumentModel*)model
                       options:(SPDFMarkdownRenderOptions*)options NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)setLanguageIdentifier:(nullable NSString*)identifier forCodeBlock:(NSUInteger)blockIndex;
- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query caseSensitive:(BOOL)caseSensitive;
- (SPDFMarkdownPaginationPlan*)paginationPlanForConfiguration:(SPDFMarkdownPageConfiguration*)configuration;
// Synchronous one-off render with caller-supplied options, leaving the
// document's own stored rendition and options untouched. The export path uses
// it to produce a LIGHT rendition of an on-screen dark document; nil options
// means the stored options.
- (SPDFMarkdownRenderedDocument*)renderedDocumentWithOptions:(nullable SPDFMarkdownRenderOptions*)options
                                           languageOverrides:
                                               (nullable NSDictionary<NSNumber*, NSString*>*)languageOverrides;
- (NSTextView*)newSelectableTextView;

- (SPDFMarkdownCancellationToken*)searchForQuery:(NSString*)query
                                    caseSensitive:(BOOL)caseSensitive
                                        workQueue:(nullable dispatch_queue_t)workQueue
                                   completionQueue:(nullable dispatch_queue_t)completionQueue
                                       completion:(void (^)(NSArray<SPDFMarkdownSearchMatch*>* matches,
                                                            BOOL cancelled))completion;
- (SPDFMarkdownCancellationToken*)renderWithLanguageOverrides:
    (NSDictionary<NSNumber*, NSString*>*)languageOverrides
                                                        workQueue:(nullable dispatch_queue_t)workQueue
                                                   completionQueue:(nullable dispatch_queue_t)completionQueue
                                                       completion:(void (^)(SPDFMarkdownRenderedDocument* _Nullable rendered,
                                                                            BOOL cancelled))completion;
// Renders with caller-supplied options (for example a different fontScale)
// without mutating the document's stored renderOptions. nil options means the
// stored options.
- (SPDFMarkdownCancellationToken*)renderWithOptions:(nullable SPDFMarkdownRenderOptions*)options
                                   languageOverrides:(NSDictionary<NSNumber*, NSString*>*)languageOverrides
                                           workQueue:(nullable dispatch_queue_t)workQueue
                                      completionQueue:(nullable dispatch_queue_t)completionQueue
                                          completion:(void (^)(SPDFMarkdownRenderedDocument* _Nullable rendered,
                                                               BOOL cancelled))completion;
@end

NS_ASSUME_NONNULL_END
