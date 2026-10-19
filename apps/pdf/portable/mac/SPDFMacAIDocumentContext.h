#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Returns a prefix within the UTF-16 budget without splitting a composed character.
NSString* SPDFAIBoundedText(NSString* text, NSUInteger max);
// Explicit worker-only extraction. No singleton, queue, directory or document is
// created until called. Page numbers are one-based. Results contain exact text,
// authored outline and revision; limits are reported, never silently hidden.
NSDictionary* _Nullable SPDFAIDocumentContext(NSString* path, BOOL landscape,
    NSUInteger firstPage, NSUInteger pageLimit, NSProgress* progress, NSError** error);
NSDictionary* _Nullable SPDFAIDocumentContextForCandidate(NSDictionary* candidate, NSUInteger firstPage,
    NSUInteger pageLimit, NSProgress* progress, NSError** error);
NSArray<NSDictionary*>* SPDFAISearchContext(NSDictionary* context, NSString* query, NSUInteger limit);
NSString* _Nullable SPDFAIContentHash(NSString* path, NSProgress* progress, NSError** error);
// Validate model output before persisting or presenting generated metadata.
NSDictionary* _Nullable SPDFAIValidateAnalysis(id value, NSUInteger pageCount, BOOL authoredOutline,
    NSError** error);
@interface SPDFMacAIAnalysisCache : NSObject
- (instancetype)initWithRootURL:(NSURL*)rootURL;
@property(nonatomic,readonly) NSURL* rootURL;
// Hold this descriptor until the cache hit or network result is complete. Closing releases the process-safe lease.
- (int)lockHash:(NSString*)hash progress:(NSProgress*)progress error:(NSError**)error;
- (nullable NSDictionary*)analysisForHash:(NSString*)hash;
- (BOOL)storeAnalysis:(NSDictionary*)analysis forHash:(NSString*)hash error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
