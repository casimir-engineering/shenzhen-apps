#import "SPDFMacCollectionImport.h"
#import "SPDFMacCollectionStorePrivate.h"
#import <objc/runtime.h>
#import <libproc.h>
#import <signal.h>
static char kInitialImport;
// Only tokens whose live coordinator already ended after a failed release may
// be reclaimed in this process; another active window's lease stays exclusive.
static NSMutableSet* AbandonedImportTokens;
static BOOL SourceUnavailable(NSError* error) {
    if ([error.domain isEqual:NSCocoaErrorDomain]) return error.code==NSFileReadNoPermissionError ||
        error.code==NSFileReadNoSuchFileError || error.code==NSFileReadUnknownError;
    if ([error.domain isEqual:NSPOSIXErrorDomain]) return error.code==EACCES || error.code==EPERM ||
        error.code==ENOENT || error.code==ENOTDIR;
    return [error.userInfo[@"sourceUnavailable"] boolValue];
}
static BOOL PermissionFailure(NSError* error) {
    return ([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSFileReadNoPermissionError) ||
        ([error.domain isEqual:NSPOSIXErrorDomain] && (error.code==EACCES || error.code==EPERM));
}
static NSDictionary* ImportProcessStamp(pid_t pid) {
    struct proc_bsdinfo info={};
    if (proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=(int)sizeof(info)) return @{};
    return @{@"pid":@(pid),@"startSec":@(info.pbi_start_tvsec),@"startUS":@(info.pbi_start_tvusec)};
}
static BOOL ImportOwnerAlive(NSDictionary* owner) {
    if (![owner isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary* process=[owner[@"process"] isKindOfClass:NSDictionary.class] ? owner[@"process"] : nil;
    pid_t pid=[process[@"pid"] intValue]; if (pid<=0) return NO;
    NSDictionary* current=ImportProcessStamp(pid);
    if (current.count) return [current isEqual:process];
    return kill(pid,0)==0 || errno==EPERM;
}
@interface SPDFCollectionInitialImport : NSObject
@property SPDFMacCollectionStore* store;
@property NSArray<NSString*>* paths;
@property NSMutableArray* completions;
@property(copy) SPDFCollectionImportRecovery recovery;
@property NSUInteger index;
@property BOOL skipPermissions;
@property BOOL waiting;
@property BOOL finished;
@property NSString* leaseToken;
@property NSString* waitingToken;
- (void)start:(NSArray*)paths;
@end
@implementation SPDFCollectionInitialImport
- (void)finish:(NSError*)error completed:(BOOL)completed {
    if (self.finished) return;
    self.finished=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        __block NSError* result=error;
        if (self.leaseToken) {
            NSError* commitError=nil;
            [self.store transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
                (void)failure; NSMutableDictionary* settings=manifest[@"settings"];
                if (![settings[@"initialImportOwner"][@"token"] isEqual:self.leaseToken]) return YES;
                if (completed && [settings[@"choice"] isEqual:@"enabled"]) settings[@"initialImportVersion"]=@1;
                [settings removeObjectForKey:@"initialImportOwner"]; return YES;
            } error:&commitError];
            if (commitError) {
                result=commitError;
                @synchronized(SPDFMacCollectionStore.class) {
                    if (!AbandonedImportTokens) AbandonedImportTokens=[NSMutableSet set];
                    [AbandonedImportTokens addObject:self.leaseToken];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{
            objc_setAssociatedObject(self.store,&kInitialImport,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (void (^completion)(NSError*) in self.completions) completion(result);
            self.completions=nil; self.recovery=nil;
        });
    });
}
- (void)start:(NSArray*)paths {
    // The existing enabled post-open trigger is the only caller. Restoring
    // settings, constructing the store and empty launch never scan old files.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        __block BOOL acquired=NO;
        NSString* token=NSUUID.UUID.UUIDString; NSError* leaseError=nil;
        BOOL claimed=[self.store transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
            NSMutableDictionary* settings=manifest[@"settings"];
            if (![settings[@"choice"] isEqual:@"enabled"] || [settings[@"initialImportVersion"] integerValue]>=1) return YES;
            NSDictionary* previous=[settings[@"initialImportOwner"] isKindOfClass:NSDictionary.class] ? settings[@"initialImportOwner"] : nil;
            BOOL abandoned=NO;
            @synchronized(SPDFMacCollectionStore.class) { abandoned=[AbandonedImportTokens containsObject:previous[@"token"] ?: @""]; }
            if (!abandoned && ImportOwnerAlive(previous)) {
                if (failure) *failure=SPDFCollectionError(24,@"Collection is being built in another window."); return NO;
            }
            settings[@"initialImportOwner"]=@{@"token":token,@"process":ImportProcessStamp(getpid())};
            acquired=YES; return YES;
        } error:&leaseError];
        if (!claimed || !acquired) {
            dispatch_async(dispatch_get_main_queue(),^{[self finish:leaseError completed:NO];}); return;
        }
        self.leaseToken=token;
        NSMutableOrderedSet* candidates=[NSMutableOrderedSet orderedSet];
        NSMutableSet* saved=[NSMutableSet set];
        for (NSDictionary* document in self.store.documents) {
            if (![document[@"sourceReplaced"] boolValue] &&
                ([document[@"versions"] count] || [document[@"excluded"] boolValue])) {
                if ([document[@"path"] length]) [saved addObject:document[@"path"]];
            } else if ([document[@"status"] isEqual:@"Capture failed"] && [document[@"path"] length])
                [candidates addObject:document[@"path"]];
        }
        for (id path in paths) if ([path isKindOfClass:NSString.class] && [path length])
            [candidates addObject:SPDFCollectionPath(path)];
        [candidates minusSet:saved];
        dispatch_async(dispatch_get_main_queue(),^{ self.paths=candidates.array; [self next]; });
    });
}
- (void)skipUnavailable:(NSString*)path {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    NSError* failure=nil;
    BOOL ok=[self.store transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
        (void)error;
        NSMutableDictionary* documents=manifest[@"documents"];
        // Recheck under the cross-process lock: a foreground capture may have
        // saved history while the permission sheet was awaiting the user.
        for (NSString* key in [documents.allKeys copy]) {
            NSDictionary* row=documents[key];
            if ([row[@"path"] isEqual:path] && ![row[@"versions"] count] &&
                ![row[@"excluded"] boolValue] && [row[@"status"] isEqual:@"Capture failed"])
                [documents removeObjectForKey:key];
        }
        return YES;
    } error:&failure];
    dispatch_async(dispatch_get_main_queue(),^{
        if (!ok) { [self finish:failure completed:NO]; return; }
        ++self.index; [self next];
    });
    });
}
- (void)capture:(NSString*)path hint:(NSDictionary*)hint recovered:(BOOL)recovered temporary:(NSURL*)temporary {
    [self.store capturePath:path authorizedCopy:hint reason:@"Imported recent document" continuingDocumentID:nil userOpenCount:0
        completion:^(NSDictionary* row,NSError* error,BOOL recorded) {
            (void)recorded;
            if (temporary) [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
            if (!self.store.isEnabled) { [self finish:nil completed:NO]; return; }
            if (row || !error) { ++self.index; [self next]; return; }
            if (!SourceUnavailable(error)) { [self finish:error completed:NO]; return; }
            if (!recovered && !self.skipPermissions && self.recovery && PermissionFailure(error)) {
                [self requestAccess:path]; return;
            }
            [self skipUnavailable:path];
        }];
}
- (void)requestAccess:(NSString*)path {
    NSURL* temporary=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSError* error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        [self finish:error completed:NO]; return;
    }
    self.waiting=YES; NSString* token=NSUUID.UUID.UUIDString; self.waitingToken=token;
    self.recovery(path,[temporary URLByAppendingPathComponent:path.lastPathComponent],^(NSDictionary* hint,BOOL skipRemaining,NSError* failure) {
        dispatch_async(dispatch_get_main_queue(),^{
            if (!self.waiting || self.finished || ![self.waitingToken isEqual:token]) return;
            self.waiting=NO; self.skipPermissions |= skipRemaining;
            if (hint && self.store.isEnabled) { [self capture:path hint:hint recovered:YES temporary:temporary]; return; }
            [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
            if (!self.store.isEnabled) { [self finish:nil completed:NO]; return; }
            if (failure && !SourceUnavailable(failure)) { [self finish:failure completed:NO]; return; }
            [self skipUnavailable:path];
        });
    });
}
- (void)next {
    if (self.finished) return;
    if (!self.store.isEnabled) { [self finish:nil completed:NO]; return; }
    if (self.index>=self.paths.count) { [self finish:nil completed:YES]; return; }
    [self capture:self.paths[self.index] hint:nil recovered:NO temporary:nil];
}
@end
@implementation SPDFMacCollectionStore (InitialImport)
- (void)importRecentPaths:(NSArray<NSString*>*)paths { [self importRecentPaths:paths recovery:nil completion:nil]; }
- (void)importRecentPaths:(NSArray<NSString*>*)paths recovery:(SPDFCollectionImportRecovery)recovery
              completion:(void (^)(NSError*))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self importRecentPaths:paths recovery:recovery completion:completion];}); return;
    }
    if (!self.isEnabled || [[self settings][@"initialImportVersion"] integerValue]>=1) {
        if (completion) completion(nil); return;
    }
    SPDFCollectionInitialImport* current=objc_getAssociatedObject(self,&kInitialImport);
    if (!current) {
        current=[SPDFCollectionInitialImport new]; current.store=self; current.recovery=recovery;
        current.completions=[NSMutableArray array];
        objc_setAssociatedObject(self,&kInitialImport,current,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [current start:[paths copy]];
    }
    if (completion) [current.completions addObject:[completion copy]];
}
@end
