#pragma once
#import <Foundation/Foundation.h>
// Anonymous inherited pipes carry transient intents/credentials only. No globally
// named endpoint, shared notification channel, or on-disk request file is used.
@interface SPDFCollectionPipe : NSObject
@property(nonatomic, copy) void (^messageHandler)(NSDictionary*);
@property(nonatomic, copy) void (^closedHandler)(void);
- (instancetype)initWithReader:(NSFileHandle*)reader writer:(NSFileHandle*)writer;
- (void)start;
- (BOOL)send:(NSDictionary*)message;
- (void)close;
@end
