#import "SPDFMarkdownDocument.h"
#import "SPDFMarkdownAuthoring.h"

@implementation SPDFMarkdownDocument {
    SPDFMarkdownRenderer* _renderer;
    SPDFMarkdownPaginator* _paginator;
    NSMutableDictionary<NSNumber*, NSString*>* _mutableLanguageOverrides;
}

+ (instancetype)documentWithURL:(NSURL*)URL options:(SPDFMarkdownRenderOptions*)options error:(NSError**)error {
    SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
    SPDFMarkdownDocumentModel* model = [parser loadURL:URL error:error];
    if (!model) return nil;
    if (!SPDFMarkdownHasAuthorPageConfiguration(model.frontMatter))
        return [[self alloc] initWithModel:model options:options ?: SPDFMarkdownRenderOptions.defaultOptions];
    SPDFMarkdownPageConfiguration* paper = SPDFMarkdownPageConfigurationForFrontMatter(
        model.frontMatter, SPDFMarkdownPageConfiguration.A4PortraitConfiguration, error);
    if (!paper) return nil;
    SPDFMarkdownRenderOptions* effective = [options ?: SPDFMarkdownRenderOptions.defaultOptions copy];
    effective.pageContentSize = paper.printableRect.size;
    return [[self alloc] initWithModel:model options:effective];
}

- (instancetype)initWithModel:(SPDFMarkdownDocumentModel*)model options:(SPDFMarkdownRenderOptions*)options {
    self = [super init];
    if (self) {
        _model = model;
        _renderOptions = [options copy];
        if (SPDFMarkdownHasAuthorPageConfiguration(model.frontMatter))
            _authoredPageConfiguration = SPDFMarkdownPageConfigurationForFrontMatter(
                model.frontMatter, SPDFMarkdownPageConfiguration.A4PortraitConfiguration, nil);
        _renderer = [SPDFMarkdownRenderer new];
        _paginator = [SPDFMarkdownPaginator new];
        _mutableLanguageOverrides = [NSMutableDictionary dictionary];
        _renderedDocument = [_renderer renderModel:_model options:_renderOptions languageOverrides:nil];
    }
    return self;
}

- (NSDictionary<NSNumber*, NSString*>*)languageOverrides { return [_mutableLanguageOverrides copy]; }

- (void)setLanguageIdentifier:(NSString*)identifier forCodeBlock:(NSUInteger)blockIndex {
    if (identifier.length) {
        SPDFMarkdownLanguage* language = [_renderer.languageCatalog languageForFenceIdentifier:identifier];
        if (language) _mutableLanguageOverrides[@(blockIndex)] = language.identifier;
    } else {
        [_mutableLanguageOverrides removeObjectForKey:@(blockIndex)];
    }
    _renderedDocument = [_renderer renderModel:_model
                                       options:_renderOptions
                             languageOverrides:_mutableLanguageOverrides];
}

- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query caseSensitive:(BOOL)caseSensitive {
    return [_renderedDocument searchForQuery:query caseSensitive:caseSensitive];
}

- (SPDFMarkdownPaginationPlan*)paginationPlanForConfiguration:(SPDFMarkdownPageConfiguration*)configuration {
    NSArray* items = [_paginator measureRenderedDocument:_renderedDocument
                                          containerWidth:NSWidth(configuration.printableRect)];
    return [_paginator paginateItems:items configuration:configuration];
}

- (SPDFMarkdownRenderedDocument*)renderedDocumentWithOptions:(SPDFMarkdownRenderOptions*)options
                                           languageOverrides:
                                               (NSDictionary<NSNumber*, NSString*>*)languageOverrides {
    return [_renderer renderModel:_model
                          options:[(options ?: _renderOptions) copy]
                languageOverrides:languageOverrides ?: _mutableLanguageOverrides];
}

- (NSTextView*)newSelectableTextView {
    NSAssert(NSThread.isMainThread, @"NSTextView creation must run on the main thread");
    return [_renderer newSelectableTextViewForRenderedDocument:_renderedDocument options:_renderOptions];
}

- (SPDFMarkdownCancellationToken*)searchForQuery:(NSString*)query
                                    caseSensitive:(BOOL)caseSensitive
                                        workQueue:(dispatch_queue_t)workQueue
                                   completionQueue:(dispatch_queue_t)completionQueue
                                       completion:(void (^)(NSArray<SPDFMarkdownSearchMatch*>*, BOOL))completion {
    SPDFMarkdownCancellationToken* token = [SPDFMarkdownCancellationToken new];
    SPDFMarkdownRenderedDocument* snapshot = _renderedDocument;
    dispatch_async(workQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray* matches = [snapshot searchForQuery:query caseSensitive:caseSensitive cancellationToken:token];
        BOOL cancelled = token.isCancelled;
        dispatch_async(completionQueue ?: dispatch_get_main_queue(), ^{ completion(cancelled ? @[] : matches, cancelled); });
    });
    return token;
}

- (SPDFMarkdownCancellationToken*)renderWithLanguageOverrides:(NSDictionary<NSNumber*, NSString*>*)languageOverrides
                                                    workQueue:(dispatch_queue_t)workQueue
                                               completionQueue:(dispatch_queue_t)completionQueue
                                                   completion:(void (^)(SPDFMarkdownRenderedDocument*, BOOL))completion {
    return [self renderWithOptions:nil
                 languageOverrides:languageOverrides
                         workQueue:workQueue
                   completionQueue:completionQueue
                        completion:completion];
}

- (SPDFMarkdownCancellationToken*)renderWithOptions:(SPDFMarkdownRenderOptions*)renderOptions
                                   languageOverrides:(NSDictionary<NSNumber*, NSString*>*)languageOverrides
                                           workQueue:(dispatch_queue_t)workQueue
                                      completionQueue:(dispatch_queue_t)completionQueue
                                          completion:(void (^)(SPDFMarkdownRenderedDocument*, BOOL))completion {
    SPDFMarkdownCancellationToken* token = [SPDFMarkdownCancellationToken new];
    SPDFMarkdownDocumentModel* model = _model;
    SPDFMarkdownRenderOptions* options = [(renderOptions ?: _renderOptions) copy];
    SPDFMarkdownRenderer* renderer = _renderer;
    NSDictionary* overrides = [languageOverrides copy];
    dispatch_async(workQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SPDFMarkdownRenderedDocument* rendered = [renderer renderModel:model options:options
                                                     languageOverrides:overrides cancellationToken:token];
        BOOL cancelled = token.isCancelled;
        dispatch_async(completionQueue ?: dispatch_get_main_queue(), ^{ completion(cancelled ? nil : rendered, cancelled); });
    });
    return token;
}

@end
