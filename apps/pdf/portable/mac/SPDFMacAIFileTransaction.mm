#import "SPDFMacAIFileTransaction.h"
#import "SPDFMacSearchFileCache.h"
#include <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>
static id Fail(NSError** error, NSString* detail) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.FileTransaction" code:1 userInfo:@{NSLocalizedDescriptionKey:detail}];
    return nil;
}
static NSString* Digest(NSData* data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString* result=[NSMutableString string];
    for (NSUInteger i=0;i<sizeof(bytes);i++) [result appendFormat:@"%02x",bytes[i]];
    return result;
}
static NSString* UndoRevision(NSDictionary* receipt, NSProgress* progress) {
    NSString* path=receipt[@"path"]; struct stat info={};
    if (progress.cancelled || !path.isAbsolutePath || lstat(path.fileSystemRepresentation,&info) ||
        !S_ISREG(info.st_mode) || info.st_size<=0 || info.st_size>32LL*1024*1024) return nil;
    NSString* revision=SPDFSearchFileStamp(path);
    NSData* bytes=[NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:nil];
    if (!bytes || progress.cancelled || ![revision isEqual:SPDFSearchFileStamp(path)] ||
        ![receipt[@"afterHash"] isEqual:Digest(bytes)]) return nil;
    return revision;
}
BOOL SPDFAICanUndoFileTransaction(NSDictionary* receipt, NSProgress* progress) { return UndoRevision(receipt,progress)!=nil; }
static NSString* Stage(NSString* path, NSData* bytes, NSError** error) {
    NSString* directory=[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [@".shenzhen-ai-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSString* staged=[directory stringByAppendingPathComponent:@"document.pdf"];
    if (![bytes writeToFile:staged options:NSDataWritingWithoutOverwriting error:error]) {
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil]; return nil;
    }
    chmod(staged.fileSystemRepresentation,0600); return staged;
}
static BOOL Commit(NSString* staged, NSString* destination, NSString* revision, NSProgress* progress, NSError** error) {
    if (progress.cancelled || ![revision isEqual:SPDFSearchFileStamp(destination)]) {
        Fail(error,progress.cancelled ? @"Cancelled before saving." : @"The document changed before saving. No changes were installed."); return NO;
    }
    // Foundation's replacement keeps the destination's original metadata and
    // permissions; the private staging directory never exposes draft contents.
    NSURL* output=nil;
    return [NSFileManager.defaultManager replaceItemAtURL:[NSURL fileURLWithPath:destination]
        withItemAtURL:[NSURL fileURLWithPath:staged] backupItemName:nil options:0 resultingItemURL:&output error:error];
}
NSDictionary* SPDFAIMutatePDF(NSString* path, NSString* expectedRevision, NSProgress* progress,
    BOOL (^mutation)(spdf_document*,char*,size_t), NSError** error) {
    struct stat info={};
    if (progress.cancelled || !path.isAbsolutePath || lstat(path.fileSystemRepresentation,&info) ||
        !S_ISREG(info.st_mode) || info.st_size<=0 || info.st_size>32LL*1024*1024)
        return Fail(error,@"This action requires a readable regular PDF of at most 32 MiB and an active request.");
    if (![expectedRevision isEqual:SPDFSearchFileStamp(path)]) return Fail(error,@"Document revision changed. Read it again.");
    NSData* before=[NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:error];
    if (!before) return nil;
    if (progress.cancelled || ![expectedRevision isEqual:SPDFSearchFileStamp(path)])
        return Fail(error,@"Document changed or action was cancelled while protecting the original.");
    NSString* staged=Stage(path,before,error); if (!staged) return nil;
    char message[1024]={}; spdf_document* doc=spdf_open(staged.fileSystemRepresentation,message,sizeof(message));
    BOOL saved=NO;
    if (doc && !spdf_is_password_protected(doc) && !progress.cancelled)
        saved=mutation(doc,message,sizeof(message)) && spdf_save_document(doc,staged.fileSystemRepresentation,message,sizeof(message));
    BOOL encrypted=doc && spdf_is_password_protected(doc); if (doc) spdf_close(doc);
    if (!saved && error && !*error) Fail(error,encrypted ? @"Use the reader's native controls for encrypted PDFs; the assistant cannot create a protected transaction yet." :
        (message[0] ? [NSString stringWithUTF8String:message] : @"The PDF edit could not be prepared."));
    NSString* afterHash=saved ? Digest([NSData dataWithContentsOfFile:staged]) : nil;
    BOOL committed=saved && Commit(staged,path,expectedRevision,progress,error);
    [NSFileManager.defaultManager removeItemAtPath:staged.stringByDeletingLastPathComponent error:nil];
    if (!committed) return nil;
    return @{@"path":path,@"beforeBytes":before,@"afterRevision":SPDFSearchFileStamp(path) ?: @"",@"afterHash":afterHash};
}
BOOL SPDFAIUndoFileTransaction(NSDictionary* receipt, NSProgress* progress, NSError** error) {
    NSString* path=receipt[@"path"]; NSData* before=receipt[@"beforeBytes"];
    NSString* revision=UndoRevision(receipt,progress);
    if (![before isKindOfClass:NSData.class] || before.length>32*1024*1024 || progress.cancelled ||
        !revision) {
        Fail(error,@"The document changed after this action, or Undo was cancelled."); return NO;
    }
    NSString* staged=Stage(path,before,error); if (!staged) return NO;
    BOOL committed=Commit(staged,path,revision,progress,error);
    [NSFileManager.defaultManager removeItemAtPath:staged.stringByDeletingLastPathComponent error:nil];
    return committed;
}
