#import "SPDFMarkdownAsync.h"

@implementation SPDFMarkdownCancellationToken {
    NSLock* _lock;
    BOOL _cancelled;
}
- (instancetype)init {
    self = [super init];
    if (self) _lock = [NSLock new];
    return self;
}
- (BOOL)isCancelled {
    [_lock lock];
    BOOL value = _cancelled;
    [_lock unlock];
    return value;
}
- (void)cancel {
    [_lock lock];
    _cancelled = YES;
    [_lock unlock];
}
@end
