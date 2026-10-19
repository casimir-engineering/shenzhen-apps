// SPDFMacFriendsCollectionLookup backed by ShenzhenPDF's Collection store. Nothing here runs while Collection is off:
// callers check friendsCollectionEnabled first, and the store itself never creates folders on reads.

#import <Foundation/Foundation.h>
#import "SPDFMacFriendsRevision.h"

@class SPDFMacCollectionStore;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacFriendsCollectionSource : NSObject <SPDFMacFriendsCollectionLookup>
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
