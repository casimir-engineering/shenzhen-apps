#import "SPDFMacAIDocumentJobsIntegration.h"
#import "SPDFMacAIDocumentJobs.h"
#import "SPDFMacAIDocumentActions.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacToolEnvironment.h"
#import "SPDFMacImageSave.h"
#import "SPDFMacAIOutputs.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownPrinting.h"
#import "markdown/SPDFTextDocumentFormats.h"
#import "markdown/SPDFTextDocumentParser.h"
#import "SPDFMacAIJobTranslator.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAICredentials.h"
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
    // Any open document, shown or not. A read-only one is read from the private copy the reader made of it, and the
    // revision read_pages and reader_state give is that copy's: comparing it with the original's own stamp refused
    // every job on a read-only document, however often it was shown and read.
    SPDFDocumentTab* tab=nil;
    for (SPDFDocumentTab* open in _tabs) if ([open.path isEqual:source]) { tab=open; break; }
    if (progress.cancelled) { completion(JobError(@"Cancelled.")); return; }
    if (!tab || tab.missingFile) { completion(JobError(@"This document is no longer open, or its file can't be found.")); return; }
    NSString* readPath=tab.workingPath.length ? tab.workingPath : source;
    NSString* current=SPDFSearchFileStamp(readPath);
    if (![revision isKindOfClass:NSString.class] || !current || !([revision isEqual:current] ||
        (tab.workingPath.length && [revision isEqual:SPDFSearchFileStamp(source)]))) {
        completion(JobError(@"The document changed since it was read. Read it again (read_pages or reader_state) and use the revision it gives.")); return;
    }
    revision=current;  // what the job reads must stay exactly this
    BOOL shown=[source isEqual:_path];
    spdf_document* loaded=shown ? _doc : tab.cachedDocument;
    if (loaded && spdf_is_password_protected(loaded)) {
        completion(JobError(@"Create an unprotected copy before exporting, OCR or translation.")); return;
    }
    NSString* name=arguments[@"name"];
    BOOL ocr=[kind isEqual:@"ocr"], translate=[kind isEqual:@"translate"];
    // A Markdown or text document is translated as the text it is, into the same format; everything else as a PDF.
    BOOL textTranslation=translate && SPDFIsRenderedTextDocumentPath(source);
    NSString* extension=textTranslation ? (source.pathExtension.length ? source.pathExtension : @"md") : @"pdf";
    // A document shown under a name given in ShenzhenPDF names its output after that name, not its file's.
    NSString* shownName=spdf_tab_display_name(tab) ? [[source.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [spdf_tab_display_name(tab) stringByReplacingOccurrencesOfString:@"/" withString:@"-"]] stringByAppendingPathExtension:source.pathExtension] : source;
    if (!name) name=[SPDFMacAIJobOutputName(shownName,kind,arguments[@"targetLanguage"]).stringByDeletingPathExtension
        stringByAppendingPathExtension:extension];
    if (![name isKindOfClass:NSString.class] || !name.length || name.length>240 ||
        ![name isEqual:name.lastPathComponent] || [name containsString:@":"] ||
        ![name.pathExtension.lowercaseString isEqual:extension.lowercaseString] || [name hasPrefix:@"."]) {
        completion(JobError([NSString stringWithFormat:@"Choose a .%@ filename without folder separators.",extension])); return;
    }
    if (!ocr && !translate && ![kind isEqual:@"export-pdf"]) { completion(JobError(@"Unknown document job.")); return; }
    NSMutableDictionary* options=[arguments mutableCopy];
    if (ocr && !options[@"language"]) options[@"language"]=@"eng";
    if (ocr && !Language(options[@"language"],YES)) { completion(JobError(@"Supply a valid local OCR language code.")); return; }
    SPDFMacAIJobTranslator* translator=nil;
    if (translate) {
        // Translated by the assistant's own model, any language it can write: no local tools.
        NSString* language=SPDFMacAITranslationLanguageName(options[@"targetLanguage"]);
        if (!language) { completion(JobError(@"Give targetLanguage as a language name or code, such as French or fr.")); return; }
        SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
        NSError* problem=nil; NSString* key=[settings load:&problem] ? [SPDFMacAICredentials APIKeyWithError:&problem] : nil;
        if (!key.length || !settings.model.length) { completion(JobError(@"Connect OpenRouter in AI settings to translate.")); return; }
        translator=[[SPDFMacAIJobTranslator alloc] initWithTransport:[[SPDFMacAITransport alloc]
            initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration] model:settings.model key:key language:language];
        options[@"translator"]=translator;
    }
    NSString* tool=ocr ? [spdf_mac_tool_venv_bin_path() stringByAppendingPathComponent:@"ocrmypdf"] : @"";
    if (ocr && ![NSFileManager.defaultManager isExecutableFileAtPath:tool]) {
        completion(JobError(@"Install local OCR support using the reader first. This action installs nothing.")); return;
    }
    NSDictionary* environment=spdf_mac_tool_environment(NSProcessInfo.processInfo.environment,@[tool],@{});
    // The same owned tessdata override used by the native OCR command.
    if (ocr) environment=[self ocrTaskEnvironmentWithTool:tool tesseract:[self tesseractToolPath] language:options[@"language"]];
    SPDFMacMarkdownSession* session=shown && [self isMarkdownActive] ? self.activeMarkdownSession : tab.cachedMarkdownSession;
    SPDFMarkdownPaginationPlan* plan=session.exportPaginationPlan;
    NSAttributedString* text=session.exportAttributedString;
    SPDFMarkdownPaginationPlan* livePlan=session.paginationPlan;
    if (textTranslation) { plan=nil; session=nil; }  // read from its file: how it is laid out on screen doesn't matter
    if (SPDFIsRenderedTextDocumentPath(source) && !textTranslation && (!plan || !text)) {
        completion(JobError(shown ? @"The text document is still preparing its PDF export." :
            @"Show this text document first (show_document), so its pages are laid out, then start the job.")); return;
    }
    // The person's Downloads, never replacing a file there; a private folder holds the rendition meanwhile.
    NSString* downloads=SPDFMacAIDownloadsDirectory();
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ShenzhenPDF-rendition-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    SPDFMacCollectionStore* collection=SPDFMacCollectionStore.defaultStore;
    __weak ShenzhenMacDelegate* weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSError* error=nil; NSDictionary* owned=nil; NSFileManager* fm=NSFileManager.defaultManager;
            BOOL prepared=!progress.cancelled && [revision isEqual:SPDFSearchFileStamp(readPath)];
            if (prepared) prepared=[fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions:@0700} error:&error];
            NSString* input=readPath;
            NSString* rendition=[directory stringByAppendingPathComponent:@".source.pdf"];
            if (prepared && plan) {
                prepared=[SPDFMacMarkdownPrintAdapter writePaginationPlan:plan attributedString:text
                    toURL:[NSURL fileURLWithPath:rendition] error:&error]; input=rendition;
            } else if (prepared && !textTranslation && ![source.pathExtension.lowercaseString isEqual:@"pdf"]) {
                char message[1024]={}; spdf_document* doc=spdf_open(readPath.fileSystemRepresentation,message,sizeof(message));
                prepared=doc && !spdf_is_password_protected(doc); if (doc) spdf_close(doc);
                if (prepared) prepared=SPDFSaveImageCopy(readPath,rendition,YES,&error);
                input=rendition;
            } else if (prepared && !loaded) {
                // A PDF in a tab that isn't loaded: the password check the loaded document gave above.
                char message[1024]={}; spdf_document* doc=spdf_open(readPath.fileSystemRepresentation,message,sizeof(message));
                if (doc && spdf_is_password_protected(doc)) {
                    prepared=NO; error=[NSError errorWithDomain:@"ShenzhenPDF.AIJob" code:1 userInfo:@{NSLocalizedDescriptionKey:
                        @"Create an unprotected copy before exporting, OCR or translation."}];
                }
                if (doc) spdf_close(doc);
            }
            if (prepared && textTranslation && !progress.cancelled) {
                NSData* data=[NSData dataWithContentsOfFile:readPath options:NSDataReadingMappedIfSafe error:&error];
                NSString* original=data.length>2000000 ? nil : data ? SPDFDecodeSourceDocument(data,&error) : nil;
                if (data.length>2000000) error=[NSError errorWithDomain:@"ShenzhenPDF.AIJob" code:1 userInfo:@{NSLocalizedDescriptionKey:
                    @"This document is too large to translate at once."}];
                NSString* translated=original ? [translator translateText:original progress:progress error:&error] : nil;
                if (translated && !progress.cancelled && [revision isEqual:SPDFSearchFileStamp(readPath)])
                    owned=SPDFMacAIOutputWriteData([translated dataUsingEncoding:NSUTF8StringEncoding],downloads,name,&error);
            } else if (prepared && !progress.cancelled && [revision isEqual:SPDFSearchFileStamp(readPath)])
                owned=SPDFAIRunPDFJob(kind,input,downloads,name,tool,environment,options,progress,&error);
            [fm removeItemAtPath:rendition error:nil];
            rmdir(directory.fileSystemRepresentation);
            // Kept in Collection now, before its tab opens, so its history says who made it rather than "Opened".
            if (owned && !progress.cancelled && [revision isEqual:SPDFSearchFileStamp(readPath)])
                SPDFMacAIOutputKeepInCollection(owned[@"path"],collection);
            dispatch_async(dispatch_get_main_queue(), ^{
                ShenzhenMacDelegate* reader=weakSelf;
                if (!reader || progress.cancelled || ![revision isEqual:SPDFSearchFileStamp(readPath)] ||
                    (session && session.paginationPlan!=livePlan)) {
                    if (owned) SPDFAIRemoveJobOutput(owned);
                    completion(JobError(progress.cancelled ? @"Cancelled." : @"Source document changed; output was discarded.")); return;
                }
                if (!owned) {
                    completion(JobError(error.localizedDescription ?: @"Document could not be prepared for this job.")); return;
                }
                NSString* destination=owned[@"path"];
                // Beside the document it was made from, in its group.
                NSDictionary* opened=[reader aiOpenCollectionDocumentAtPath:destination archived:NO afterPath:source progress:progress];
                if (progress.cancelled && opened[@"documentReceipt"]) {
                    [reader aiUndoDocumentAction:opened[@"documentReceipt"] progress:[NSProgress progressWithTotalUnitCount:1]];
                    SPDFAIRemoveJobOutput(owned);
                    completion(JobError(@"Cancelled.")); return;
                }
                if (opened[@"error"] || !opened[@"documentReceipt"]) {
                    SPDFAIRemoveJobOutput(owned); completion(opened); return;
                }
                completion(@{@"path":destination,@"filename":destination.lastPathComponent,@"savedTo":@"Downloads",
                    @"completed":@YES,@"operation":kind,
                    @"documentReceipt":@{@"kind":@"job",@"owned":owned,@"open":opened[@"documentReceipt"]}});
            });
        }
    });
}
- (BOOL)aiUndoDocumentJob:(NSDictionary*)receipt progress:(NSProgress*)progress {
    NSDictionary* owned=receipt[@"owned"];
    if (progress.cancelled || !SPDFAIJobReceiptIsCurrent(owned)) return NO;
    if (![self aiUndoDocumentAction:receipt[@"open"] progress:progress]) return NO;
    // The Downloads copy only, and only while it is the exact file made; its Collection history stays, as it does
    // for any original that is removed.
    return SPDFAIRemoveJobOutput(owned);
}
@end
