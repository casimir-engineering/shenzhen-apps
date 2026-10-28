#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One searched page: `payload` is whatever the page search returned (nil when
// the page had nothing).
@interface SPDFMacSearchPageResult : NSObject
@property(nonatomic, readonly) NSUInteger pageIndex;
@property(nonatomic, readonly, nullable) id payload;
@end

// Find in document, spread over a few background workers one page at a time,
// so a 2,000-page document never blocks the window and results show while the
// search runs. Pages are taken in order starting at `firstPage` (the page on
// screen) and wrapping, so the first results are the ones nearest the reader.
// Each worker keeps one context (an open document, for PDF) and holds only the
// page it is searching. Results reach the main queue in batches at most every
// 0.1s; nothing is delivered after -cancel. Main-thread API.
@interface SPDFMacProgressiveSearch : NSObject
- (instancetype)initWithPageCount:(NSUInteger)pageCount
                        firstPage:(NSUInteger)firstPage
                      workerCount:(NSUInteger)workerCount NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic, readonly) NSUInteger firstPage;
// Pages searched so far, counting those in flight as not done.
@property(nonatomic, readonly) NSUInteger pagesSearched;
@property(nonatomic, readonly, getter=isFinished) BOOL finished;
// Safe from any thread.
@property(atomic, readonly, getter=isCancelled) BOOL cancelled;
// Where the search is started from (the caller's work queue, so suspending
// that queue holds the search too); a global queue when nil. Set before start.
@property(nonatomic, strong, nullable) dispatch_queue_t startQueue;
- (void)cancel;

// `makeContext` runs once per worker on that worker's thread; returning nil
// with an error message stops the search. `searchPage` runs on a worker; an
// error message stops the search after the pages already searched. `results`
// gets each batch in the order the pages finished; `completion` runs once,
// after the last batch, unless the search was cancelled.
- (void)startWithContext:(id _Nullable (^)(NSString* _Nullable* _Nonnull error))makeContext
              searchPage:(id _Nullable (^)(id _Nullable context, NSUInteger pageIndex,
                                           NSString* _Nullable* _Nonnull error))searchPage
            closeContext:(void (^_Nullable)(id _Nullable context))closeContext
                 results:(void (^)(NSArray<SPDFMacSearchPageResult*>* pages))results
              completion:(void (^)(NSString* _Nullable error))completion;

// Workers for a document of `pageCount` pages: one for a few pages, up to four.
+ (NSUInteger)workerCountForPageCount:(NSUInteger)pageCount;
@end

// The search list in the sidebar shows this many matches at most (a long list
// of "e" matches is no use to read and costs seconds to build); the previous
// and next arrows still step through every match.
static const NSUInteger SPDFSearchSidebarListLimit = 1000;
static inline NSString* SPDFSearchSidebarOverflowTitle(NSUInteger total) {
    NSString* (^number)(NSUInteger) = ^NSString*(NSUInteger value) {
      return [NSNumberFormatter localizedStringFromNumber:@(value) numberStyle:NSNumberFormatterDecimalStyle];
    };
    return [NSString stringWithFormat:@"Showing the first %@ of %@ matches. The arrows go through all of them.",
                                      number(SPDFSearchSidebarListLimit), number(total)];
}

NS_ASSUME_NONNULL_END
