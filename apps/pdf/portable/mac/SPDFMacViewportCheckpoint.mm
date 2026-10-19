#import "SPDFMacViewportCheckpoint.h"

@interface SPDFMacViewportCheckpoint ()
@property(nonatomic) NSTimeInterval delay;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL hasPendingAction;
@end

@implementation SPDFMacViewportCheckpoint

- (instancetype)initWithDelay:(NSTimeInterval)delay {
    self = [super init];
    if (self) _delay = MAX(0, delay);
    return self;
}

- (void)scheduleAction:(dispatch_block_t)action {
    NSAssert(NSThread.isMainThread, @"viewport checkpoints are main-thread state");
    if (!action) return;
    NSUInteger generation = ++self.generation;
    self.hasPendingAction = YES;
    __weak SPDFMacViewportCheckpoint* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      SPDFMacViewportCheckpoint* strongSelf = weakSelf;
      if (!strongSelf || generation != strongSelf.generation) return;
      strongSelf.hasPendingAction = NO;
      action();
    });
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"viewport checkpoints are main-thread state");
    ++self.generation;
    self.hasPendingAction = NO;
}

@end
