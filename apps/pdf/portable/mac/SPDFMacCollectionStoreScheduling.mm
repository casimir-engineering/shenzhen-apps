#import "SPDFMacCollectionStorePrivate.h"
#import <limits.h>
@implementation SPDFMacCollectionStore (CaptureScheduling)
- (NSNumber*)advanceCaptureGenerationForPath:(NSString*)path {
    @synchronized (self) {
        if (!self.captureGenerations) self.captureGenerations = [NSMutableDictionary dictionary];
        NSString* key = SPDFCollectionPath(path);
        NSNumber* next = @([self.captureGenerations[key] unsignedLongLongValue] + 1);
        self.captureGenerations[key] = next; return next;
    }
}
- (BOOL)captureRequestIsCurrentForPath:(NSString*)path {
    NSDictionary* context = NSThread.currentThread.threadDictionary[[NSString stringWithFormat:@"SPDFCollectionCapture.%p", self]];
    if (!context || ![context[@"path"] isEqual:SPDFCollectionPath(path)]) return YES;
    // An explicit open is a usage event, not replaceable background work.
    // Durable protection epochs still prevent an older job from splitting history.
    if ([context[@"userOpenState"][@"explicitOpen"] boolValue]) return YES;
    @synchronized (self) { return [context[@"generation"] isEqual:self.captureGenerations[SPDFCollectionPath(path)]]; }
}
- (BOOL)captureEpochIsCurrentForPath:(NSString*)path document:(NSDictionary*)document {
    NSDictionary* context = NSThread.currentThread.threadDictionary[[NSString stringWithFormat:@"SPDFCollectionCapture.%p", self]];
    return !context || ![context[@"path"] isEqual:SPDFCollectionPath(path)] ||
        [context[@"epoch"] isEqual:document[@"protectionEpoch"] ?: @""];
}
- (NSMutableDictionary*)captureUserOpenStateForPath:(NSString*)path {
    NSDictionary* context=NSThread.currentThread.threadDictionary[[NSString stringWithFormat:@"SPDFCollectionCapture.%p",self]];
    return [context[@"path"] isEqual:SPDFCollectionPath(path)] ? context[@"userOpenState"] : nil;
}
- (NSUInteger)captureUserOpenCountForPath:(NSString*)path {
    return [[self captureUserOpenStateForPath:path][@"count"] unsignedIntegerValue];
}
- (void)recordCaptureUserOpenInDocument:(NSMutableDictionary*)document path:(NSString*)path {
    NSUInteger count=[self captureUserOpenCountForPath:path];
    if (!count) return;
    unsigned long long previous=[document[@"openCount"] unsignedLongLongValue];
    document[@"openCount"]=@(ULLONG_MAX-previous<count ? ULLONG_MAX : previous+count);
    document[@"lastOpenedAt"]=@(NSDate.date.timeIntervalSince1970);
}
- (void)markCaptureUserOpenRecordedForPath:(NSString*)path {
    NSMutableDictionary* state=[self captureUserOpenStateForPath:path];
    if ([state[@"count"] unsignedIntegerValue]) { state[@"count"]=@0; state[@"recorded"]=@YES; }
}
- (void)recordUncapturedUserOpenForPath:(NSString*)path {
    if (![self captureUserOpenCountForPath:path]) return;
    NSString* identifier=[self documentForPath:path][@"id"];
    if (!identifier.length) return;
    // Successful reading still counts when capture is excluded, cancelled by an
    // edit epoch or fails. Finish before the next worker can enforce its cap;
    // a main-thread completion may be delayed while the user is interacting.
    BOOL recorded=[self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        (void)failure; NSMutableDictionary* document=manifest[@"documents"][identifier];
        if (!document) return NO;
        [self recordCaptureUserOpenInDocument:document path:path]; return YES;
    } error:nil];
    if (recorded) [self markCaptureUserOpenRecordedForPath:path];
}
- (void)capturePath:(NSString*)path reason:(NSString*)reason completion:(void (^)(NSDictionary*,NSError*))completion {
    [self capturePath:path reason:reason continuingDocumentID:nil completion:completion];
}
- (void)capturePath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID
        completion:(void (^)(NSDictionary*,NSError*))completion {
    if (!completion) {
        [self capturePath:path reason:reason continuingDocumentID:documentID userOpenCount:0 completion:nil]; return;
    }
    [self capturePath:path reason:reason continuingDocumentID:documentID userOpenCount:0
          completion:^(NSDictionary* row,NSError* error,BOOL recorded) {
              (void)recorded; if (completion) completion(row,error);
          }];
}
- (void)capturePath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID
        userOpenCount:(NSUInteger)count completion:(void (^)(NSDictionary*,NSError*,BOOL))completion {
    [self capturePath:path authorizedCopy:nil reason:reason continuingDocumentID:documentID
        userOpenCount:count completion:completion];
}
- (void)capturePath:(NSString*)path authorizedCopy:(NSDictionary*)copy reason:(NSString*)reason
        continuingDocumentID:(NSString*)documentID userOpenCount:(NSUInteger)count
        completion:(void (^)(NSDictionary*,NSError*,BOOL))completion {
    if (![self isEnabled] || [self isArchivePath:path]) {
        if (completion) dispatch_async(dispatch_get_main_queue(),^{ completion(nil,nil,NO); }); return;
    }
    @synchronized (self) {
        if (!self.captureQueue) { self.captureQueue=[NSOperationQueue new]; self.captureQueue.maxConcurrentOperationCount=1;
            self.captureQueue.qualityOfService=NSQualityOfServiceUtility; }
    }
    NSMutableDictionary* state=[@{@"count":@(count),@"recorded":@NO,@"explicitOpen":@(count>0)} mutableCopy];
    if (copy.count) state[@"authorizedCopy"] = @{@"path":[copy[@"path"] copy] ?: @"",
        @"source":[copy[@"source"] copy] ?: @{}, @"copy":[copy[@"copy"] copy] ?: @{}};
    [self enqueueCapturePath:path reason:reason continuingDocumentID:documentID attempt:0
                  generation:[self advanceCaptureGenerationForPath:path]
                       epoch:[self documentForPath:path][@"protectionEpoch"] ?: @""
               userOpenState:state completion:completion];
}
- (void)enqueueCapturePath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID
                  attempt:(NSUInteger)attempt generation:(NSNumber*)generation epoch:(NSString*)epoch
                 userOpenState:(NSMutableDictionary*)state completion:(void (^)(NSDictionary*,NSError*,BOOL))completion {
    NSBlockOperation* operation=[NSBlockOperation blockOperationWithBlock:^{
        NSString* contextKey = [NSString stringWithFormat:@"SPDFCollectionCapture.%p", self];
        id previousContext = NSThread.currentThread.threadDictionary[contextKey];
        NSThread.currentThread.threadDictionary[contextKey] = @{@"path":SPDFCollectionPath(path), @"generation":generation, @"epoch":epoch, @"userOpenState":state};
        NSError* error=nil; NSDictionary* row;
        @try {
            row=[self capturePath:path reason:reason continuingDocumentID:documentID error:&error];
            if (!row) [self recordUncapturedUserOpenForPath:path];
        }
        @finally {
            if (previousContext) NSThread.currentThread.threadDictionary[contextKey] = previousContext;
            else [NSThread.currentThread.threadDictionary removeObjectForKey:contextKey];
        }
        BOOL transient=([error.domain isEqual:@"SPDFCollection"] &&
                        (error.code==5 || error.code==EAGAIN || error.code==EINTR || error.code==EBUSY)) ||
                       ([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSFileReadUnknownError);
        if (!row && transient && attempt<2 && self.isEnabled) {
            NSString* continuation=documentID ?: error.userInfo[@"continuingDocumentID"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((attempt+1)*0.25*NSEC_PER_SEC)),
                dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                    if (self.isEnabled) [self enqueueCapturePath:path reason:reason continuingDocumentID:continuation
                                                        attempt:attempt+1 generation:generation epoch:epoch userOpenState:state completion:completion];
                    else if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,nil,[state[@"recorded"] boolValue]);});
                });
            return;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(),^{ completion(row,error,[state[@"recorded"] boolValue]); });
    }];
    operation.queuePriority=[reason isEqual:@"Imported recent document"] ? NSOperationQueuePriorityVeryLow : NSOperationQueuePriorityNormal;
    [self.captureQueue addOperation:operation];
}
@end
