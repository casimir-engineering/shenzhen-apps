#pragma once
#import <Foundation/Foundation.h>
@class SPDFMacCollectionStore;
// Explicit worker-only metadata lookup. Never reads, materializes, or hashes document bytes.
NSDictionary* SPDFAICollectionRevisionMetadata(SPDFMacCollectionStore* store, NSString* path, NSUInteger limit);
NSDictionary* SPDFAICollectionRevisionDiff(SPDFMacCollectionStore* store, NSString* path, NSString* versionID, NSProgress* progress);
// Exact UTF-16 splices per page, bounded to 32k changed characters. nil means full excerpts are safer.
NSDictionary* SPDFAIRevisionDelta(NSArray* previousPages, NSArray* pages, BOOL partial);
@interface SPDFMacAIRevisionBaseline : NSObject
- (instancetype)initWithRootURL:(NSURL*)root;
- (NSDictionary*)baselineForIdentity:(NSString*)identity;
- (BOOL)storeBaseline:(NSDictionary*)value identity:(NSString*)identity;
@end
