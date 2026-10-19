#import "SPDFMacAIToolsComments.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacAIFileTransaction.h"
@interface ShenzhenMacDelegate (SPDFMacAICommentHost)
- (void)reloadCommentsFromActiveDocument;
- (void)reloadSelectedTabFromDiskChange;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
@end
static NSDictionary* CommentError(NSString* message) { return @{@"error":message}; }
@implementation ShenzhenMacDelegate (SPDFMacAIToolsComments)
- (NSDictionary*)aiReadCommentsAtPath:(NSString*)path {
    if (![_path isEqual:path] || !_doc || ![path.pathExtension.lowercaseString isEqual:@"pdf"])
        return CommentError(@"Show this PDF in the reader before accessing its comments.");
    NSString* revision=SPDFSearchFileStamp(path); struct stat info={};
    if (!revision || stat(path.fileSystemRepresentation,&info) || info.st_size>32LL*1024*1024)
        return CommentError(@"Use the reader controls for comments on PDFs larger than 32 MiB.");
    // Match indices to the exact on-disk revision used by staged edits, rather
    // than the live viewer's potentially stale pre-file-watcher document.
    char message[1024]={}; spdf_comments comments={};
    spdf_document* source=spdf_open(path.fileSystemRepresentation,message,sizeof(message));
    if (!source) return CommentError(@"Comments could not be loaded.");
    BOOL loaded=!spdf_is_password_protected(source) && spdf_load_comments(source,&comments,message,sizeof(message));
    spdf_close(source);
    if (!loaded) return CommentError(@"Use the reader controls for encrypted PDF comments.");
    NSMutableArray* rows=[NSMutableArray array];
    for (int i=0;i<comments.count && i<500;i++) {
        spdf_comment_item item=comments.items[i];
        NSString* text=item.text ? [NSString stringWithUTF8String:item.text] : @"";
        if (text.length>10000) text=[text substringToIndex:10000];
        [rows addObject:@{@"index":@(item.index),@"page":@(item.page_index+1),@"text":text ?: @"",
            @"author":item.author ? [NSString stringWithUTF8String:item.author] : @""}];
    }
    BOOL truncated=comments.count>500; spdf_free_comments(&comments);
    if (![revision isEqual:SPDFSearchFileStamp(path)]) return CommentError(@"The document changed while reading comments. Try again.");
    return @{@"comments":rows,@"truncated":@(truncated),@"path":path,@"revision":revision};
}
- (NSDictionary*)aiEditComment:(NSDictionary*)arguments progress:(NSProgress*)progress {
    if (progress.cancelled) return CommentError(@"Comment edit cancelled.");
    NSString* path=arguments[@"path"];
    if (![_path isEqual:path] || !_doc || ![path.pathExtension.lowercaseString isEqual:@"pdf"])
        return CommentError(@"Show this PDF in the reader before changing its comments.");
    if (![arguments[@"revision"] isEqual:SPDFSearchFileStamp(path)])
        return CommentError(@"Read the current comments first. The document revision changed.");
    NSString* operation=arguments[@"operation"];
    NSInteger page=[arguments[@"page"] integerValue], index=[arguments[@"index"] integerValue];
    if ([operation isEqual:@"add"] && (page<1 || page>spdf_page_count(_doc)))
        return CommentError(@"Comment page is outside the document.");
    if (![@[@"add",@"edit",@"delete"] containsObject:operation]) return CommentError(@"Unknown comment operation.");
    if (![operation isEqual:@"delete"] && ![arguments[@"text"] length]) return CommentError(@"Comment text is required.");
    if (![operation isEqual:@"add"]) {
        NSDictionary* current=[self aiReadCommentsAtPath:path]; BOOL exists=NO;
        for (NSDictionary* row in current[@"comments"]) if ([row[@"index"] integerValue]==index) exists=YES;
        if (!exists) return CommentError(@"The comment no longer exists.");
    }
    struct stat info={};
    if (stat(path.fileSystemRepresentation,&info) || info.st_size>32LL*1024*1024)
        return CommentError(@"This PDF exceeds the 32 MiB reversible comment budget. Use the reader comment controls.");
    // Preserve normal permission and Collection protection gates. A user can
    // cancel the native Save As/protection panel, including during an AI task.
    if (![self ensureActivePDFCanBeModifiedForOperation:@"assistant comment editing"])
        return CommentError(@"Comment edit cancelled.");
    if (progress.cancelled) return CommentError(@"Comment edit cancelled.");
    if (![_path isEqual:path] || ![arguments[@"revision"] isEqual:SPDFSearchFileStamp(path)])
        return CommentError(@"The document changed during permission handling. Read comments again.");
    NSError* transactionError=nil;
    NSDictionary* receipt=SPDFAIMutatePDF(path,arguments[@"revision"],progress,^BOOL(spdf_document* document,char* message,size_t length) {
        const char* author=[(arguments[@"author"] ?: @"Shenzhen PDF Assistant") UTF8String];
        if ([operation isEqual:@"add"])
            return spdf_add_text_comment(document,(int)page-1,36,36,[arguments[@"text"] UTF8String],author,message,length);
        if ([operation isEqual:@"edit"])
            return spdf_update_comment(document,(int)index,[arguments[@"text"] UTF8String],author,message,length);
        return spdf_delete_comment(document,(int)index,message,length);
    },&transactionError);
    if (!receipt) return CommentError(transactionError.localizedDescription ?: @"Comment edit could not be saved.");

    [self collectionDidSavePath:path]; [self refreshActiveTabCachedFileAttributesAfterSelfSave];
    [self reloadSelectedTabFromDiskChange];
    NSMutableDictionary* result=[receipt mutableCopy]; result[@"operation"]=operation; result[@"changed"]=@YES; return result;
}
- (BOOL)aiUndoCommentReceipt:(NSDictionary*)receipt progress:(NSProgress*)progress {
    NSString* path=receipt[@"path"];
    if (progress.cancelled || ![_path isEqual:path] || !SPDFAICanUndoFileTransaction(receipt,progress)) return NO;
    if (![self collectionProtectPath:path operation:@"undoing an assistant comment edit"]) return NO;
    if (progress.cancelled || !SPDFAICanUndoFileTransaction(receipt,progress)) return NO;
    if (!SPDFAIUndoFileTransaction(receipt,progress,nil)) return NO;
    [self collectionDidSavePath:path]; [self refreshActiveTabCachedFileAttributesAfterSelfSave];
    [self reloadSelectedTabFromDiskChange]; return YES;
}
@end
