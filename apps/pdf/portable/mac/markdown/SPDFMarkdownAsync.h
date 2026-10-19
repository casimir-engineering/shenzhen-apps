#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMarkdownCancellationToken : NSObject
@property(atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
