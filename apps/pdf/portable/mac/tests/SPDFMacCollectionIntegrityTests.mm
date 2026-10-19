#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#import "SPDFMacCollectionStorePrivate.h"
static int failures;
static void Expect(NSString* name,BOOL ok) { if(!ok){fprintf(stderr,"FAIL %s\n",name.UTF8String);++failures;} }
static NSData* PlainPDF(void) {
    NSMutableData* data=[NSMutableData data]; CGDataConsumerRef consumer=CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect box=CGRectMake(0,0,200,200); CGContextRef context=CGPDFContextCreate(consumer,&box,NULL);
    CGPDFContextBeginPage(context,NULL); CGContextSetRGBFillColor(context,1,0,0,1);
    CGContextFillRect(context,CGRectMake(20,20,80,80)); CGPDFContextEndPage(context);
    CGPDFContextClose(context); CGContextRelease(context); CGDataConsumerRelease(consumer); return data;
}
@interface RacingStore : SPDFMacCollectionStore
@property(nonatomic) NSString* racingPath;
@property(nonatomic) BOOL inject;
@end
@implementation RacingStore
- (void)recordFingerprints:(NSMutableDictionary*)doc source:(NSDictionary*)source dependencies:(NSDictionary*)dependencies {
    if(self.inject) [@"replacement B" writeToFile:self.racingPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [super recordFingerprints:doc source:source dependencies:dependencies];
}
@end
@interface RetryStore : SPDFMacCollectionStore
@property(nonatomic) NSUInteger attempts;
@end
@implementation RetryStore
- (NSDictionary*)capturePath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID error:(NSError**)error {
    if (++self.attempts<3) { if(error)*error=SPDFCollectionError(5,@"Source is changing"); return nil; }
    return [super capturePath:path reason:reason continuingDocumentID:documentID error:error];
}
@end
@interface DelayedCaptureStore: SPDFMacCollectionStore
@property dispatch_semaphore_t entered;
@property dispatch_semaphore_t proceed;
@end
@implementation DelayedCaptureStore
- (NSDictionary*)capturePath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID error:(NSError**)error {
 if([reason isEqual:@"Delayed initial open"]){dispatch_semaphore_signal(self.entered);dispatch_semaphore_wait(self.proceed,DISPATCH_TIME_FOREVER);}
 return [super capturePath:path reason:reason continuingDocumentID:documentID error:error];
}
@end

#include "SPDFMacCollectionMaterializationChecks.h"
#include "SPDFMacCollectionAuthorizedCopyChecks.h"
#include "SPDFMacCollectionImportChecks.h"

int main(void) {
    @autoreleasepool {
        CheckCollectionMaterializationPerformance();
        CheckCollectionAuthorizedCopy();
        CheckCollectionInitialImport();
        NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager* fm=NSFileManager.defaultManager;
        [fm createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL* root=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Collection"]];
        SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSString* path=[sandbox stringByAppendingPathComponent:@"Encrypted.pdf"];
        PDFDocument* pdf=[[PDFDocument alloc] initWithData:PlainPDF()];
        Expect(@"encrypted fixture written",[pdf writeToFile:path withOptions:@{PDFDocumentOwnerPasswordOption:@"owner-secret",
               PDFDocumentUserPasswordOption:@"reader-secret"}]);
        NSError* error; NSDictionary* doc=[store capturePath:path reason:@"Opened" error:&error];
        NSDictionary* version=[store versionsForDocumentID:doc[@"id"]].firstObject;
        Expect([NSString stringWithFormat:@"encrypted source captured: %@",error ?: @""],doc!=nil);
        Expect(@"encrypted source has no plaintext index",[version[@"encrypted"] boolValue] && [version[@"textPages"] count]==0);
        NSURL* preview=[store materializeVersionID:version[@"id"] documentID:doc[@"id"] error:nil];
        Expect(@"archive preserves exact encrypted bytes",[[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfURL:preview]]);
        NSDictionary* beforePreview = [fm attributesOfItemAtPath:preview.path error:nil];
        NSURL* repeatedPreview = [store materializeVersionID:version[@"id"] documentID:doc[@"id"] error:nil];
        NSDictionary* afterPreview = [fm attributesOfItemAtPath:repeatedPreview.path error:nil];
        Expect(@"unchanged materialized preview preserves credential-bound file identity",
               [beforePreview[NSFileSystemFileNumber] isEqual:afterPreview[NSFileSystemFileNumber]] &&
               [beforePreview[NSFileModificationDate] isEqual:afterPreview[NSFileModificationDate]]);
        PDFDocument* restored=[[PDFDocument alloc] initWithURL:preview];
        Expect(@"restored encryption remains locked",restored.isEncrypted && restored.isLocked);
        Expect(@"original password still works",[restored unlockWithPassword:@"reader-secret"]);
        NSURL* exported=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Independent.pdf"]];
        Expect(@"independent export succeeds",[store exportVersionID:version[@"id"] documentID:doc[@"id"] toURL:exported error:nil]);
        [@"user edits independent file" writeToURL:exported atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Expect(@"editing export cannot mutate archive",[[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfURL:preview]]);
        Expect(@"Save a Copy cannot overwrite original",![store exportVersionID:version[@"id"] documentID:doc[@"id"]
                   toURL:[NSURL fileURLWithPath:path] error:nil]);
        NSURL* object=[[root URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:version[@"hash"]];
        [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:object.path error:nil];
        [@"corrupted snapshot" writeToURL:object atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Expect(@"corrupt snapshot blocks protection despite manifest reference",![store ensureProtectedPath:path reason:@"Edit" error:nil]);
        Expect(@"corrupt snapshot is not presented as protected",[[store documentForPath:path][@"status"] isEqual:@"Capture failed"]);
        Expect(@"corrupt snapshot is not opened as a preview",![store materializeVersionID:version[@"id"] documentID:doc[@"id"] error:nil]);
        NSURL* failedRoot=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Unavailable"]];
        SPDFMacCollectionStore* failed=[[SPDFMacCollectionStore alloc] initWithRootURL:failedRoot];
        [failed updateSettings:@{@"choice":@"enabled"} error:nil];
        [@"directory collision" writeToURL:[failedRoot URLByAppendingPathComponent:@"objects"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSError* writeError; Expect(@"unwritable object destination blocks edit",![failed ensureProtectedPath:path reason:@"Edit" error:&writeError] && writeError);
        Expect(@"failed snapshot never publishes partial revision",[[failed documentForPath:path][@"versions"] count]==0);
        Expect(@"failed archive leaves source readable",[[[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]] isEncrypted]);
        NSString* racePath=[sandbox stringByAppendingPathComponent:@"Race.md"];
        [@"captured A" writeToFile:racePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        RacingStore* racing=[[RacingStore alloc] initWithRootURL:[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"RaceStore"]]];
        [racing updateSettings:@{@"choice":@"enabled"} error:nil]; racing.racingPath=racePath; racing.inject=YES;
        NSError* raceError=nil;
        Expect(@"source replacement between validation and commit cannot report protected",![racing capturePath:racePath reason:@"Opened" error:&raceError] && raceError.code==5);
        NSDictionary* raceDoc=[racing documentForPath:racePath]; racing.inject=NO;
        Expect(@"captured fingerprint never resamples the replacement",![raceDoc[@"sourceFingerprint"] isEqual:SPDFCollectionFingerprint(racePath)]);
        Expect(@"retry archives actual current bytes before permitting edit",[racing ensureProtectedPath:racePath reason:@"Before edit"
                  continuingDocumentID:raceDoc[@"id"] error:nil]);
        NSDictionary* protectedVersion=[racing versionsForDocumentID:raceDoc[@"id"]].lastObject;
        NSURL* protectedURL=[racing materializeVersionID:protectedVersion[@"id"] documentID:raceDoc[@"id"] error:nil];
        Expect(@"only committed revision matches source B",[[NSData dataWithContentsOfURL:protectedURL] isEqual:[NSData dataWithContentsOfFile:racePath]] &&
               [racing versionsForDocumentID:raceDoc[@"id"]].count==1);
        NSString* identityPath=[sandbox stringByAppendingPathComponent:@"Identity.md"];
        [@"document one" writeToFile:identityPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* identityOne=[racing capturePath:identityPath reason:@"Opened" error:nil];
        [@"unrelated document two" writeToFile:identityPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        SPDFMacCollectionStore* reopened=[[SPDFMacCollectionStore alloc] initWithRootURL:racing.rootURL];
        NSDictionary* identityTwo=[reopened capturePath:identityPath reason:@"Opened after relaunch" error:nil];
        NSDictionary* former=nil; for(NSDictionary* item in reopened.documents)if([item[@"id"] isEqual:identityOne[@"id"]])former=item;
        Expect(@"same-path new inode after relaunch starts separate history",![identityOne[@"id"] isEqual:identityTwo[@"id"]] &&
               [former[@"sourceReplaced"] boolValue] && [former[@"originalUnavailable"] boolValue]);
        Expect(@"current path resolves current identity",[[reopened documentForPath:identityPath][@"id"] isEqual:identityTwo[@"id"]]);
        NSArray* historicalMatches=[reopened search:@"Identity" titlesOnly:YES excludingPaths:[NSSet setWithObject:identityPath] limit:5];
        Expect(@"open-path exclusion retains superseded historical documents",historicalMatches.count==1 &&
                   [historicalMatches.firstObject[@"id"] isEqual:identityOne[@"id"]]);
        [reopened setExcluded:YES documentID:identityOne[@"id"] error:nil];
        Expect(@"excluding a replaced history cannot exclude the current document",![[reopened documentForPath:identityPath][@"excluded"] boolValue]);
        [@"known live atomic save" writeToFile:identityPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* continued=[reopened capturePath:identityPath reason:@"Observed external save"
                                    continuingDocumentID:identityTwo[@"id"] error:nil];
        Expect(@"explicit observed atomic save retains ID and history",[continued[@"id"] isEqual:identityTwo[@"id"]] &&
               [reopened versionsForDocumentID:identityTwo[@"id"]].count==2);
        Expect(@"superseded continuity IDs cannot hijack current source",![reopened capturePath:identityPath reason:@"Stale watcher"
                                    continuingDocumentID:identityOne[@"id"] error:nil]);
        Expect(@"stale watcher cannot change current protection status",[[reopened documentForPath:identityPath][@"status"] isEqual:@"Protected"]);
        // Simulate a preview from the initial schema, which did not persist a filename.
        NSDictionary* legacyVersion=[reopened versionsForDocumentID:identityTwo[@"id"]].firstObject;
        NSURL* legacyPreview=[reopened materializeVersionID:legacyVersion[@"id"] documentID:identityTwo[@"id"] error:nil];
        [reopened transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
            (void)failure;
            NSMutableDictionary* legacyDoc=manifest[@"documents"][identityTwo[@"id"]];
            for (NSMutableDictionary* revision in legacyDoc[@"versions"]) [revision removeObjectForKey:@"filename"];
            legacyDoc[@"path"]=[sandbox stringByAppendingPathComponent:@"Renamed.md"];
            return YES;
        } error:nil];
        Expect(@"legacy archive keeps its dated identity after original rename",[[reopened archiveInfoForPath:legacyPreview.path][@"version"][@"id"] isEqual:legacyVersion[@"id"]]);
        NSString* otherOriginal=[sandbox stringByAppendingPathComponent:@"OtherOriginal.pdf"];
        [@"only copy of unrelated original" writeToFile:otherOriginal atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Expect(@"export cannot overwrite another document's only original",![reopened exportVersionID:protectedVersion[@"id"]
                  documentID:raceDoc[@"id"] toURL:[NSURL fileURLWithPath:otherOriginal] error:nil]);
        Expect(@"unrelated export destination remains intact",[[NSString stringWithContentsOfFile:otherOriginal encoding:NSUTF8StringEncoding error:nil]
                  isEqual:@"only copy of unrelated original"]);
        NSString* referenceImage=[sandbox stringByAppendingPathComponent:@"logo.svg"];
        [@"<svg>logo</svg>" writeToFile:referenceImage atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString* referencePath=[sandbox stringByAppendingPathComponent:@"References.md"];
        NSString* references=@"![Logo][image]\n![image][]\n![image]\n\n[image]: logo.svg\n";
        [references writeToFile:referencePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* referenceDoc=[reopened capturePath:referencePath reason:@"Opened" error:nil];
        NSDictionary* referenceVersion=[reopened versionsForDocumentID:referenceDoc[@"id"]].lastObject;
        Expect(@"full collapsed and shortcut reference images retain their dependency",[referenceVersion[@"assets"] count]==1 &&
                  [referenceVersion[@"assetWarnings"] count]==0);
        RetryStore* retry=[[RetryStore alloc] initWithRootURL:[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Retries"]]];
        [retry updateSettings:@{@"choice":@"enabled"} error:nil]; __block BOOL completed=NO; __block BOOL mainCompletion=NO;
        [retry capturePath:referencePath reason:@"Opened" completion:^(NSDictionary* row,NSError* failure) {
            completed=row!=nil && !failure; mainCompletion=NSThread.isMainThread;
        }];
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while(!completed && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        Expect(@"transient capture automatically retries twice with main-queue completion",completed && mainCompletion && retry.attempts==3);
        for (NSNumber* separate in @[@NO,@YES]) {
        DelayedCaptureStore* queued = [[DelayedCaptureStore alloc] initWithRootURL:[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:separate.boolValue ? @"SeparateQueues" : @"OneQueue"]]];
        SPDFMacCollectionStore* writer = separate.boolValue ? [[SPDFMacCollectionStore alloc] initWithRootURL:queued.rootURL] : queued;
        [queued updateSettings:@{@"choice":@"enabled"} error:nil];
        queued.entered=dispatch_semaphore_create(0); queued.proceed=dispatch_semaphore_create(0);
        NSString* queuedPath=[sandbox stringByAppendingPathComponent:@"Queued.md"];
        [@"A" writeToFile:queuedPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [queued capturePath:queuedPath reason:@"Delayed initial open" completion:nil];
        Expect(@"queued fixture reaches the capture boundary",dispatch_semaphore_wait(queued.entered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);
        Expect(@"edit gate protects A while older job is pending",[writer ensureProtectedPath:queuedPath reason:@"Before edit" error:nil]);
        NSString* queuedID=[queued documentForPath:queuedPath][@"id"];
        [@"B" writeToFile:queuedPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        __block BOOL savedCompleted=NO; __block NSError* savedError;
        [writer capturePath:queuedPath reason:@"Saved" continuingDocumentID:queuedID completion:^(NSDictionary* row,NSError* failure) {
            savedCompleted=row!=nil; savedError=failure;
        }];
        dispatch_semaphore_signal(queued.proceed);
        NSDate* queueDeadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while((!savedCompleted || queued.captureQueue.operationCount) && !savedError && queueDeadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Expect(separate.boolValue ? @"another window invalidates stale queued captures" : @"stale queued open cannot split a known save",savedCompleted && !savedError && queued.documents.count==1 &&
            [queued versionsForDocumentID:queuedID].count==2 && [[queued documentForPath:queuedPath][@"id"] isEqual:queuedID]);
        }
        [fm removeItemAtPath:sandbox error:nil];
        if(!failures)printf("SPDFMacCollectionIntegrityTests passed\n"); return failures?1:0;
    }
}
