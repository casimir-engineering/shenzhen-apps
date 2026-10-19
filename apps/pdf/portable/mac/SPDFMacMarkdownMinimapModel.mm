#import "SPDFMacMarkdownMinimapModel.h"

#import <CoreGraphics/CoreGraphics.h>

const NSUInteger SPDFMarkdownMinimapDefaultMaximumPixelDimension = 512;
const NSUInteger SPDFMarkdownMinimapHardMaximumPixelDimension = 1024;

@interface SPDFMarkdownMinimapThumbnailRequest : NSObject
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSSize pixelSize;
@property(nonatomic, strong) NSBlockOperation* operation;
@property(nonatomic, strong) NSMutableArray<SPDFMarkdownMinimapThumbnailCompletion>* completions;
@end

@implementation SPDFMarkdownMinimapThumbnailRequest
@end

static NSSize SPDFMarkdownBoundedThumbnailSize(NSSize paperSize, NSSize requestedSize, NSUInteger maximumDimension) {
    CGFloat paperWidth = MAX(1.0, paperSize.width);
    CGFloat paperHeight = MAX(1.0, paperSize.height);
    CGFloat requestedWidth = requestedSize.width > 0.0 ? requestedSize.width : maximumDimension;
    CGFloat requestedHeight = requestedSize.height > 0.0 ? requestedSize.height : maximumDimension;
    CGFloat scale = MIN(requestedWidth / paperWidth, requestedHeight / paperHeight);
    scale = MIN(scale, (CGFloat)maximumDimension / MAX(paperWidth, paperHeight));
    scale = MAX(scale, 1.0 / MAX(paperWidth, paperHeight));
    return NSMakeSize(MAX(1.0, floor(paperWidth * scale)), MAX(1.0, floor(paperHeight * scale)));
}

static BOOL SPDFMarkdownPixelSizeSatisfies(NSSize available, NSSize requested) {
    return available.width + 0.5 >= requested.width && available.height + 0.5 >= requested.height;
}

@interface SPDFMacMarkdownMinimapModel () {
    NSAttributedString* _attributedString;
    NSOperationQueue* _renderQueue;
    NSLock* _stateLock;
    NSMutableDictionary<NSNumber*, SPDFMarkdownMinimapThumbnailRequest*>* _requests;
    NSMutableDictionary<NSNumber*, NSValue*>* _thumbnailPixelSizes;
    NSMutableDictionary<NSNumber*, NSImage*>* _thumbnailImages;
    NSUInteger _nextGeneration;
    NSArray<NSValue*>* _documentPageRects;
    NSRect _documentVisibleRect;
    NSSize _documentSize;
    CGFloat _documentScale;
}
@end

@implementation SPDFMacMarkdownMinimapModel

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)paginationPlan
                      attributedString:(NSAttributedString*)attributedString {
    return [self initWithPaginationPlan:paginationPlan
                       attributedString:attributedString
         maximumThumbnailPixelDimension:SPDFMarkdownMinimapDefaultMaximumPixelDimension];
}

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)paginationPlan
                      attributedString:(NSAttributedString*)attributedString
        maximumThumbnailPixelDimension:(NSUInteger)maximumPixelDimension {
    NSParameterAssert(paginationPlan);
    NSParameterAssert(attributedString);
    self = [super init];
    if (!self) return nil;

    _paginationPlan = paginationPlan;
    _attributedString = [attributedString copy];
    _maximumThumbnailPixelDimension = MAX(1, MIN(maximumPixelDimension, SPDFMarkdownMinimapHardMaximumPixelDimension));
    _stateLock = [NSLock new];
    _requests = [NSMutableDictionary dictionary];
    _thumbnailPixelSizes = [NSMutableDictionary dictionary];
    _thumbnailImages = [NSMutableDictionary dictionary];
    _renderQueue = [NSOperationQueue new];
    _renderQueue.name = @"com.intuition.shenzhenpdf.markdown-minimap";
    _renderQueue.maxConcurrentOperationCount = 2;
    _renderQueue.qualityOfService = NSQualityOfServiceUtility;

    NSSize paperSize = paginationPlan.configuration.paperSize;
    NSMutableArray<SPDFRenderedPage*>* pages = [NSMutableArray arrayWithCapacity:paginationPlan.pages.count];
    NSMutableArray<NSValue*>* pageRects = [NSMutableArray arrayWithCapacity:paginationPlan.pages.count];
    for (NSUInteger index = 0; index < paginationPlan.pages.count; ++index) {
        SPDFRenderedPage* page = [SPDFRenderedPage new];
        page.pageIndex = (NSInteger)index;
        page.pageWidth = paperSize.width;
        page.pageHeight = paperSize.height;
        page.highlights = @[];
        page.selectionRects = @[];
        [pages addObject:page];
        [pageRects addObject:[NSValue valueWithRect:NSMakeRect(0, index * paperSize.height, paperSize.width,
                                                               paperSize.height)]];
    }
    _pages = [pages copy];
    _a4PageRects = [pageRects copy];
    _documentPageRects = _a4PageRects;
    _documentSize = NSMakeSize(paperSize.width, paperSize.height * paginationPlan.pages.count);
    _documentScale = 1.0;
    return self;
}

- (void)dealloc {
    [self cancelAllThumbnailRequests];
}

- (NSArray<NSValue*>*)documentPageRects {
    [_stateLock lock];
    NSArray<NSValue*>* value = _documentPageRects;
    [_stateLock unlock];
    return value;
}

- (NSRect)documentVisibleRect {
    [_stateLock lock];
    NSRect value = _documentVisibleRect;
    [_stateLock unlock];
    return value;
}

- (NSSize)documentSize {
    [_stateLock lock];
    NSSize value = _documentSize;
    [_stateLock unlock];
    return value;
}

- (CGFloat)documentScale {
    [_stateLock lock];
    CGFloat value = _documentScale;
    [_stateLock unlock];
    return value;
}

- (NSUInteger)pendingThumbnailRequestCount {
    [_stateLock lock];
    NSUInteger count = _requests.count;
    [_stateLock unlock];
    return count;
}

- (void)updateViewportPageRects:(NSArray<NSValue*>*)pageRects
                    visibleRect:(NSRect)visibleRect
                   documentSize:(NSSize)documentSize
                  documentScale:(CGFloat)documentScale {
    NSArray<NSValue*>* snapshot = [pageRects copy] ?: @[];
    [_stateLock lock];
    _documentPageRects = snapshot;
    _documentVisibleRect = visibleRect;
    _documentSize = documentSize;
    _documentScale = MAX(0.0, documentScale);
    [_stateLock unlock];
}

- (void)updateSearchHighlightRects:(NSDictionary<NSNumber*, NSArray<NSValue*>*>*)rectsByPage {
    NSAssert(NSThread.isMainThread, @"Search highlights are published on the main thread");
    NSMutableArray<SPDFRenderedPage*>* pages = [NSMutableArray arrayWithCapacity:_pages.count];
    for (SPDFRenderedPage* page in _pages) {
        page.highlights = rectsByPage[@((NSUInteger)page.pageIndex)] ?: @[];
        [pages addObject:page];
    }
    _pages = [pages copy];
}

- (void)invalidateThumbnails {
    [_thumbnailImages removeAllObjects];
    [_thumbnailPixelSizes removeAllObjects];
}

- (NSImage*)renderThumbnailForPageIndex:(NSUInteger)pageIndex pixelSize:(NSSize)pixelSize {
    size_t width = (size_t)MAX(1.0, pixelSize.width);
    size_t height = (size_t)MAX(1.0, pixelSize.height);
    size_t bytesPerRow = width * 4;
    if (width > SPDFMarkdownMinimapHardMaximumPixelDimension || height > SPDFMarkdownMinimapHardMaximumPixelDimension ||
        bytesPerRow / 4 != width || height > SIZE_MAX / bytesPerRow)
        return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, bytesPerRow, colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;

    NSSize paperSize = _paginationPlan.configuration.paperSize;
    CGContextScaleCTM(context, (CGFloat)width / MAX(1.0, paperSize.width),
                      (CGFloat)height / MAX(1.0, paperSize.height));
    BOOL drew = [_paginationPlan drawPageAtIndex:pageIndex attributedString:_attributedString inContext:context];
    CGImageRef CGImage = drew ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    if (!CGImage) return nil;
    NSImage* image = [[NSImage alloc] initWithCGImage:CGImage size:NSMakeSize(width, height)];
    CGImageRelease(CGImage);
    return image;
}

- (void)requestThumbnailForPageIndex:(NSUInteger)pageIndex
                     targetPixelSize:(NSSize)targetPixelSize
                          completion:(SPDFMarkdownMinimapThumbnailCompletion)completion {
    if (pageIndex >= _pages.count) {
        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{
              completion(nil, nil);
            });
        return;
    }

    NSSize pixelSize = SPDFMarkdownBoundedThumbnailSize(_paginationPlan.configuration.paperSize, targetPixelSize,
                                                        _maximumThumbnailPixelDimension);
    NSNumber* key = @(pageIndex);
    [_stateLock lock];
    NSValue* cachedSize = _thumbnailPixelSizes[key];
    SPDFRenderedPage* page = _pages[pageIndex];
    NSImage* cachedImage = _thumbnailImages[key];
    if (cachedImage && cachedSize && SPDFMarkdownPixelSizeSatisfies(cachedSize.sizeValue, pixelSize)) {
        [_stateLock unlock];
        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{
              completion(page, cachedImage);
            });
        return;
    }

    SPDFMarkdownMinimapThumbnailRequest* existing = _requests[key];
    if (existing && SPDFMarkdownPixelSizeSatisfies(existing.pixelSize, pixelSize)) {
        if (completion) [existing.completions addObject:[completion copy]];
        [_stateLock unlock];
        return;
    }

    NSMutableArray<SPDFMarkdownMinimapThumbnailCompletion>* completions = [NSMutableArray array];
    if (existing) {
        [existing.operation cancel];
        [completions addObjectsFromArray:existing.completions];
    }
    if (completion) [completions addObject:[completion copy]];
    SPDFMarkdownMinimapThumbnailRequest* request = [SPDFMarkdownMinimapThumbnailRequest new];
    request.generation = ++_nextGeneration;
    request.pixelSize = pixelSize;
    request.completions = completions;
    _requests[key] = request;
    [_stateLock unlock];

    __weak SPDFMacMarkdownMinimapModel* weakSelf = self;
    __weak SPDFMarkdownMinimapThumbnailRequest* weakRequest = request;
    request.operation = [NSBlockOperation blockOperationWithBlock:^{
      @autoreleasepool {
          SPDFMacMarkdownMinimapModel* strongSelf = weakSelf;
          SPDFMarkdownMinimapThumbnailRequest* strongRequest = weakRequest;
          if (!strongSelf || !strongRequest || strongRequest.operation.cancelled) return;
          NSImage* image = [strongSelf renderThumbnailForPageIndex:pageIndex pixelSize:pixelSize];
          if (strongRequest.operation.cancelled) return;
          dispatch_async(dispatch_get_main_queue(), ^{
            SPDFMacMarkdownMinimapModel* mainSelf = weakSelf;
            SPDFMarkdownMinimapThumbnailRequest* mainRequest = weakRequest;
            if (!mainSelf || !mainRequest || mainRequest.operation.cancelled) return;
            [mainSelf->_stateLock lock];
            SPDFMarkdownMinimapThumbnailRequest* current = mainSelf->_requests[key];
            if (current != mainRequest || current.generation != mainRequest.generation) {
                [mainSelf->_stateLock unlock];
                return;
            }
            [mainSelf->_requests removeObjectForKey:key];
            NSArray<SPDFMarkdownMinimapThumbnailCompletion>* callbacks = [current.completions copy];
            SPDFRenderedPage* publishedPage = mainSelf->_pages[pageIndex];
            if (image) {
                publishedPage.minimapImage = image;
                publishedPage.minimapImageZoom = pixelSize.width / MAX(1.0, publishedPage.pageWidth);
                publishedPage.minimapImageScale = 1.0;
                mainSelf->_thumbnailPixelSizes[key] = [NSValue valueWithSize:pixelSize];
                mainSelf->_thumbnailImages[key] = image;
            }
            [mainSelf->_stateLock unlock];
            for (SPDFMarkdownMinimapThumbnailCompletion callback in callbacks) callback(publishedPage, image);
          });
      }
    }];
    [_stateLock lock];
    BOOL requestIsCurrent = _requests[key] == request;
    [_stateLock unlock];
    if (requestIsCurrent)
        [_renderQueue addOperation:request.operation];
    else
        [request.operation cancel];
}

- (void)cancelThumbnailRequestForPageIndex:(NSUInteger)pageIndex {
    NSNumber* key = @(pageIndex);
    [_stateLock lock];
    SPDFMarkdownMinimapThumbnailRequest* request = _requests[key];
    [_requests removeObjectForKey:key];
    [_stateLock unlock];
    [request.operation cancel];
}

- (void)cancelAllThumbnailRequests {
    [_stateLock lock];
    NSArray<SPDFMarkdownMinimapThumbnailRequest*>* requests = _requests.allValues;
    [_requests removeAllObjects];
    [_stateLock unlock];
    for (SPDFMarkdownMinimapThumbnailRequest* request in requests) [request.operation cancel];
    [_renderQueue cancelAllOperations];
}

@end
