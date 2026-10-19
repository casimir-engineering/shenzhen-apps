#pragma once
#import <Foundation/Foundation.h>
// Main-thread intent ledger: success hooks also run during restore/watch reload,
// so only an explicit open request may consume a usage event. No store or disk access.
@interface SPDFCollectionOpenIntents : NSObject
- (void)requestPaths:(NSArray<NSString*>*)paths;
- (NSUInteger)consumePath:(NSString*)path;
@end
