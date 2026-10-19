#import "SPDFMacAIMetadataActions.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAIDocumentContext.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAILanguage.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacAIToolsReader.h"
#include <sys/stat.h>
#include <unistd.h>
static NSDictionary* Problem(NSString* text) {return @{@"error":text};}
@implementation ShenzhenMacDelegate (AIMetadataActions)
- (void)aiUpdateMetadata:(NSDictionary*)arguments progress:(NSProgress*)progress completion:(void (^)(NSDictionary*))completion {
    NSString* path=arguments[@"path"];NSDictionary* before=[self aiAnalysisForPath:path];
    if(!before[@"cacheKey"]) {
        completion(Problem(@"Generated metadata is not available for this document yet. Use show_document once to load its analysis, then read document_metadata. Retry the update only when analysisAvailable is true; otherwise explain that analysis is still pending."));return;
    }
    if(![arguments[@"revision"] isEqual:SPDFSearchFileStamp(path)]) {
        completion(Problem(@"The document revision changed. Read read_pages again and use its returned revision before updating metadata."));return;
    }
    NSDictionary* fields=arguments[@"metadata"];
    if(![fields isKindOfClass:NSDictionary.class]){completion(Problem(@"Provide metadata fields to update."));return;}
    NSMutableDictionary* after=[before mutableCopy];
    for(NSString* key in fields) {
        if(![@[@"summary",@"tags",@"keywords",@"chapters",@"language"] containsObject:key]) {completion(Problem(@"Unknown metadata field."));return;}
        after[key]=fields[key];
    }
    if(![after[@"language"] isKindOfClass:NSString.class] || !SPDFMacAILanguageNames()[after[@"language"]]) {completion(Problem(@"Use a supported language code."));return;}
    NSError* error=nil;NSDictionary* validated=SPDFAIValidateAnalysis(after,[before[@"pageCount"] unsignedIntegerValue],NO,&error);
    if(!validated) {completion(Problem(error.localizedDescription));return;}
    after=[validated mutableCopy];after[@"userRequestedOverride"]=@YES;
    [self aiSwapMetadataReceipt:@{@"path":path,@"revision":arguments[@"revision"],@"before":after,@"after":before}
        progress:progress completion:completion];
}
- (void)aiSwapMetadataReceipt:(NSDictionary*)receipt progress:(NSProgress*)progress completion:(void (^)(NSDictionary*))completion {
    NSString* path=receipt[@"path"];NSDictionary* expected=receipt[@"after"],*replacement=receipt[@"before"];
    NSDictionary* live=[self aiAnalysisForPath:path];
    BOOL restoredPDF=[path.pathExtension.lowercaseString isEqual:@"pdf"] &&
        [expected[@"contentHash"] isKindOfClass:NSString.class] && [expected[@"contentHash"] length]==64 &&
        ![receipt[@"revision"] isEqual:SPDFSearchFileStamp(path)];
    if(progress.cancelled || (live && ![live isEqual:expected]) || (!live && !restoredPDF) ||
        ![self aiDocumentCandidateForPath:path]) {completion(Problem(@"Document metadata changed; read it again."));return;}
    NSURL* root=[SPDFMacAISettings.defaultURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"AI/Analysis"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        SPDFMacAIAnalysisCache* cache=[[SPDFMacAIAnalysisCache alloc] initWithRootURL:root];NSError* error=nil;
        NSString* key=expected[@"cacheKey"];int lease=[cache lockHash:key progress:progress error:&error];
        NSString* revision=SPDFSearchFileStamp(path);
        BOOL sameSource=[receipt[@"revision"] isEqual:revision];
        if(lease>=0 && !sameSource && restoredPDF && !progress.cancelled) {
            // PDF Undo atomically restores bytes with a fresh inode. Hash only
            // this recovery path, on the worker, within the file-edit budget.
            struct stat info={};
            sameSource=!lstat(path.fileSystemRepresentation,&info) && S_ISREG(info.st_mode) &&
                info.st_size>0 && info.st_size<=32LL*1024*1024 &&
                [expected[@"contentHash"] isEqual:SPDFAIContentHash(path,progress,&error)];
        }
        BOOL ok=lease>=0 && !progress.cancelled && sameSource && [revision isEqual:SPDFSearchFileStamp(path)] &&
            [[cache analysisForHash:key] isEqual:expected] && [cache storeAnalysis:replacement forHash:key error:&error];
        if(lease>=0)close(lease);
        dispatch_async(dispatch_get_main_queue(),^{
            if(!ok){completion(Problem(error.localizedDescription ?: @"Document changed or the edit was cancelled."));return;}
            // A file watcher can advance the live document after the worker
            // commits this hash's cache. Never attach that old analysis to the
            // newly loaded document; retain its receipt for the completed edit.
            NSDictionary* current=[self aiAnalysisForPath:path];
            if([revision isEqual:SPDFSearchFileStamp(path)] &&
                ([current isEqual:expected] || (restoredPDF && !current)))
                [self aiPublishUpdatedMetadata:replacement path:path];
            completion(@{@"changed":@YES,@"metadataReceipt":@{@"path":path,@"revision":revision,@"before":expected,@"after":replacement},
                @"metadata":replacement});
        });
    });
}
@end
