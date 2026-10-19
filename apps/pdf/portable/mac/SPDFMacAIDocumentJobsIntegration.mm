#import "SPDFMacAIDocumentJobsIntegration.h"
#import "SPDFMacAIDocumentJobs.h"
#import "SPDFMacAIDocumentActions.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacToolEnvironment.h"
#import "SPDFMacImageSave.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownPrinting.h"
#import "markdown/SPDFTextDocumentFormats.h"
#include "shenzhen_pdf_core.h"
#include <unistd.h>
@interface ShenzhenMacDelegate (AIJobsHost)
- (NSDictionary*)ocrTaskEnvironmentWithTool:(NSString*)tool tesseract:(NSString*)tesseract language:(NSString*)language;
- (NSString*)tesseractToolPath;
@end
static NSDictionary* JobError(NSString* message) { return @{@"error":message ?: @"Document job failed."}; }
static BOOL Language(NSString* value, BOOL ocr) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length>40) return NO;
    NSCharacterSet* allowed=[NSCharacterSet characterSetWithCharactersInString:
        ocr ? @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-" : @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}
@implementation ShenzhenMacDelegate (SPDFMacAIDocumentJobsIntegration)
- (void)aiRunDocumentJob:(NSString*)kind arguments:(NSDictionary*)arguments progress:(NSProgress*)progress
             completion:(void (^)(NSDictionary*))completion {
    NSString* source=arguments[@"path"], *revision=arguments[@"revision"];
    if (progress.cancelled || ![source isEqual:_path] || !revision.length ||
        ![revision isEqual:SPDFSearchFileStamp(source)]) {
        completion(JobError(@"Show the document and read its current revision before starting this job.")); return;
    }
    if (_doc && spdf_is_password_protected(_doc)) {
        completion(JobError(@"Create an unprotected copy before exporting, OCR or translation.")); return;
    }
    NSString* name=arguments[@"name"];
    if (!name) name=[NSString stringWithFormat:@"%@-%@.pdf",source.lastPathComponent.stringByDeletingPathExtension,
        [kind isEqual:@"translate"] ? @"translated" : [kind isEqual:@"ocr"] ? @"ocr" : @"export"];
    if (![name isKindOfClass:NSString.class] || !name.length || name.length>240 ||
        ![name isEqual:name.lastPathComponent] || [name containsString:@":"] ||
        ![name.pathExtension.lowercaseString isEqual:@"pdf"] || [name hasPrefix:@"."]) {
        completion(JobError(@"Choose a PDF filename without folder separators.")); return;
    }
    BOOL ocr=[kind isEqual:@"ocr"], translate=[kind isEqual:@"translate"];
    if (!ocr && !translate && ![kind isEqual:@"export-pdf"]) { completion(JobError(@"Unknown document job.")); return; }
    NSMutableDictionary* options=[arguments mutableCopy];
    if (ocr && !options[@"language"]) options[@"language"]=@"eng";
    if ((ocr && !Language(options[@"language"],YES)) ||
        (translate && (!Language(options[@"sourceLanguage"],NO) || !Language(options[@"targetLanguage"],NO)))) {
        completion(JobError(@"Supply valid local OCR or translation language codes.")); return;
    }
    NSString* tool=ocr || translate ? [spdf_mac_tool_venv_bin_path()
        stringByAppendingPathComponent:ocr ? @"ocrmypdf" : @"argos-translate"] : @"";
    if ((ocr || translate) && ![NSFileManager.defaultManager isExecutableFileAtPath:tool]) {
        completion(JobError(@"Install local OCR or translation support using the reader first. This action installs nothing.")); return;
    }
    NSDictionary* environment=spdf_mac_tool_environment(NSProcessInfo.processInfo.environment,@[tool],@{});
    // The same owned tessdata override used by the native OCR command.
    if (ocr) environment=[self ocrTaskEnvironmentWithTool:tool tesseract:[self tesseractToolPath] language:options[@"language"]];
    SPDFMacMarkdownSession* session=[self isMarkdownActive] ? self.activeMarkdownSession : nil;
    SPDFMarkdownPaginationPlan* plan=session.exportPaginationPlan;
    NSAttributedString* text=session.exportAttributedString;
    SPDFMarkdownPaginationPlan* livePlan=session.paginationPlan;
    if (SPDFIsRenderedTextDocumentPath(source) && (!plan || !text)) {
        completion(JobError(@"The text document is still preparing its PDF export.")); return;
    }
    NSString* root=[SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Assistant Exports"];
    NSString* directory=[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* destination=[directory stringByAppendingPathComponent:name];
    __weak ShenzhenMacDelegate* weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSError* error=nil; NSDictionary* owned=nil; NSFileManager* fm=NSFileManager.defaultManager;
            BOOL prepared=!progress.cancelled && [revision isEqual:SPDFSearchFileStamp(source)];
            if (prepared) prepared=[fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions:@0700} error:&error];
            NSString* input=source;
            NSString* rendition=[directory stringByAppendingPathComponent:@".source.pdf"];
            if (prepared && plan) {
                prepared=[SPDFMacMarkdownPrintAdapter writePaginationPlan:plan attributedString:text
                    toURL:[NSURL fileURLWithPath:rendition] error:&error]; input=rendition;
            } else if (prepared && ![source.pathExtension.lowercaseString isEqual:@"pdf"]) {
                char message[1024]={}; spdf_document* doc=spdf_open(source.fileSystemRepresentation,message,sizeof(message));
                prepared=doc && !spdf_is_password_protected(doc); if (doc) spdf_close(doc);
                if (prepared) prepared=SPDFSaveImageCopy(source,rendition,YES,&error);
                input=rendition;
            }
            if (prepared && !progress.cancelled && [revision isEqual:SPDFSearchFileStamp(source)])
                owned=SPDFAIRunPDFJob(kind,input,destination,tool,environment,options,progress,&error);
            [fm removeItemAtPath:rendition error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                ShenzhenMacDelegate* reader=weakSelf;
                if (!reader || progress.cancelled || ![revision isEqual:SPDFSearchFileStamp(source)] ||
                    (session && session.paginationPlan!=livePlan)) {
                    if (owned) SPDFAIRemoveJobOutput(owned);
                    rmdir(directory.fileSystemRepresentation);
                    completion(JobError(progress.cancelled ? @"Cancelled." : @"Source document changed; output was discarded.")); return;
                }
                if (!owned) {
                    rmdir(directory.fileSystemRepresentation);
                    completion(JobError(error.localizedDescription ?: @"Document could not be prepared for this job.")); return;
                }
                NSDictionary* opened=[reader aiOpenCollectionDocumentAtPath:destination archived:NO progress:progress];
                if (progress.cancelled && opened[@"documentReceipt"]) {
                    [reader aiUndoDocumentAction:opened[@"documentReceipt"] progress:[NSProgress progressWithTotalUnitCount:1]];
                    SPDFAIRemoveJobOutput(owned); rmdir(directory.fileSystemRepresentation);
                    completion(JobError(@"Cancelled.")); return;
                }
                if (opened[@"error"] || !opened[@"documentReceipt"]) {
                    SPDFAIRemoveJobOutput(owned); rmdir(directory.fileSystemRepresentation); completion(opened); return;
                }
                completion(@{@"path":destination,@"filename":name,@"completed":@YES,@"operation":kind,
                    @"documentReceipt":@{@"kind":@"job",@"owned":owned,@"open":opened[@"documentReceipt"]}});
            });
        }
    });
}
- (BOOL)aiUndoDocumentJob:(NSDictionary*)receipt progress:(NSProgress*)progress {
    NSDictionary* owned=receipt[@"owned"];
    if (progress.cancelled || !SPDFAIJobReceiptIsCurrent(owned)) return NO;
    if (![self aiUndoDocumentAction:receipt[@"open"] progress:progress]) return NO;
    if (!SPDFAIRemoveJobOutput(owned)) return NO;
    // Only remove an empty request directory; never recursively remove human additions.
    rmdir([owned[@"path"] stringByDeletingLastPathComponent].fileSystemRepresentation);
    return YES;
}
@end
