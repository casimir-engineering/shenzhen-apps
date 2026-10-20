// Files received through Shenzhen Friends: which ones Collection still has to take (SPDFMacCollectionStore.h,
// Received). The record lives in the manifest's settings under "receivedFiles" ({since, handled}), so it follows the
// Collection, and the claim happens under the manifest's cross-process lock: of several ShenzhenPDF windows that
// all hear the same received file, exactly one captures it.

#import "SPDFMacCollectionStorePrivate.h"
#import <math.h>

// Far more than the helper's received view lists at once (100), so a file still listed is never forgotten and
// taken again; the oldest IDs go first.
static const NSUInteger SPDFCollectionReceivedHandledLimit = 500;

@implementation SPDFMacCollectionStore (Received)

- (NSArray<NSString*>*)claimReceivedFiles:(NSDictionary<NSString*, NSNumber*>*)files {
    // Unset: no Collection yet, and none is created for this. A damaged index or a missing location is left alone.
    NSDictionary* current = [self settings];
    NSString* choice = current[@"choice"];
    if (!([choice isEqual:@"enabled"] || [choice isEqual:@"disabled"]) || [current[@"indexDamaged"] boolValue] ||
        [current[@"locationUnavailable"] boolValue])
        return nil;
    __block NSArray<NSString*>* claimed = nil;
    __block BOOL writing = NO;
    long long now = (long long)floor(NSDate.date.timeIntervalSince1970);
    BOOL committed = [self manifestTransaction:^BOOL(NSMutableDictionary* manifest, NSError** error) {
        (void)error;
        NSMutableDictionary* settings = [manifest[@"settings"] isKindOfClass:NSDictionary.class]
            ? [manifest[@"settings"] mutableCopy] : [NSMutableDictionary dictionary];
        NSString* lockedChoice = settings[@"choice"];
        if (!([lockedChoice isEqual:@"enabled"] || [lockedChoice isEqual:@"disabled"])) return NO;
        NSDictionary* saved = [settings[@"receivedFiles"] isKindOfClass:NSDictionary.class] ? settings[@"receivedFiles"] : @{};
        id since = saved[@"since"];
        BOOL started = [since isKindOfClass:NSNumber.class];
        long long start = started ? [since longLongValue] : now;
        NSMutableArray<NSString*>* handled = [NSMutableArray array];
        for (id identifier in [saved[@"handled"] isKindOfClass:NSArray.class] ? saved[@"handled"] : @[])
            if ([identifier isKindOfClass:NSString.class]) [handled addObject:identifier];
        NSSet* known = [NSSet setWithArray:handled];
        NSMutableArray<NSString*>* fresh = [NSMutableArray array];
        for (NSString* identifier in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (![identifier isKindOfClass:NSString.class] || [known containsObject:identifier]) continue;
            id receivedAt = files[identifier];
            // Received before ShenzhenPDF first heard of received files: history, not something new.
            if (![receivedAt isKindOfClass:NSNumber.class] || [receivedAt longLongValue] < start) continue;
            [fresh addObject:identifier];
        }
        claimed = [lockedChoice isEqual:@"enabled"] ? [fresh copy] : @[];
        if (started && !fresh.count) return NO; // nothing to write
        [handled addObjectsFromArray:fresh];
        if (handled.count > SPDFCollectionReceivedHandledLimit)
            [handled removeObjectsInRange:NSMakeRange(0, handled.count - SPDFCollectionReceivedHandledLimit)];
        settings[@"receivedFiles"] = @{@"since" : @(start), @"handled" : handled};
        manifest[@"settings"] = settings;
        writing = YES;
        return YES;
    } writeBack:YES error:nil];
    // Not recorded: claim nothing now rather than take the same file again later.
    if (writing && !committed) return nil;
    return claimed;
}

@end
