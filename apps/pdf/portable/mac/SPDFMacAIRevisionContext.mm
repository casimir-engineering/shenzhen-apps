#import "SPDFMacAIRevisionContext.h"
#import "SPDFMacCollectionStorePrivate.h"
#import <CommonCrypto/CommonDigest.h>
static NSString* IdentityHash(NSString* identity) {
    NSData* data=[identity dataUsingEncoding:NSUTF8StringEncoding]; unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);NSMutableString* value=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(bytes);i++)[value appendFormat:@"%02x",bytes[i]];return value;
}
NSDictionary* SPDFAICollectionRevisionMetadata(SPDFMacCollectionStore* store, NSString* path, NSUInteger limit) {
    NSDictionary* documents=[store readManifest][@"documents"];NSDictionary* doc=nil,*selected=nil;
    NSString* normalized=path.stringByStandardizingPath;
    // Worker-only lookup: restored tabs may retain a path through relocation symlinks.
    NSString* resolved=normalized.stringByResolvingSymlinksInPath;
    NSString* root=store.rootURL.path.stringByResolvingSymlinksInPath;
    if([resolved hasPrefix:[root stringByAppendingString:@"/"]]) {
        NSArray* parts=[[resolved substringFromIndex:root.length+1] pathComponents];
        if(parts.count==4 && ( [parts[0] isEqual:@"editable"] || [parts[0] isEqual:@"previews"])) {
            doc=documents[parts[1]];NSString* versionID=parts[2];
            if([parts[0] isEqual:@"editable"])versionID=doc[@"editableCopies"][parts[2]][@"currentVersionID"];
            for(NSDictionary* version in doc[@"versions"])if([version[@"id"] isEqual:versionID]){selected=version;break;}
        }
    } else for(NSDictionary* candidate in documents.allValues)
        if(![candidate[@"sourceReplaced"] boolValue] && [candidate[@"path"] isEqual:normalized]){doc=candidate;break;}
    if(!doc)return @{@"revisionCount":@0,@"analysisEligible":@(![resolved hasPrefix:[root stringByAppendingString:@"/"]]),@"analysisDocumentID":normalized};
    NSArray* versions=doc[@"versions"] ?: @[];NSMutableArray* rows=[NSMutableArray array];
    NSUInteger count=MIN(MIN(limit,100),versions.count);
    for(NSUInteger index=versions.count-count;index<versions.count;index++) {
        NSDictionary* version=versions[index];NSMutableDictionary* row=[@{@"id":version[@"id"] ?: @"",
            @"date":version[@"capturedAt"] ?: @0,@"bytes":version[@"size"] ?: @0,@"diffStatus":@"notComputed",
            @"latest":@([version[@"id"] isEqual:doc[@"latestVersionID"]])} mutableCopy];
        if(index)row[@"previousBytes"]=versions[index-1][@"size"] ?: @0;
        [rows addObject:row];
    }
    BOOL eligible=!selected || [selected[@"id"] isEqual:doc[@"latestVersionID"]];
    // Immutable historical previews never receive standalone model summaries, even if the latest snapshot.
    if([resolved hasPrefix:[root stringByAppendingString:@"/previews/"]])eligible=NO;
    return @{@"revisionCount":@(versions.count),@"revisions":rows,@"moreRevisions":@(versions.count>count),
        @"analysisEligible":@(eligible),@"analysisDocumentID":doc[@"id"] ?: normalized,
        @"selectedVersionID":selected[@"id"] ?: NSNull.null,@"latestVersionID":doc[@"latestVersionID"] ?: NSNull.null};
}
static NSDictionary* RevisionDelta(NSArray* previousPages, NSArray* pages, BOOL partial, NSUInteger budget) {
    if(previousPages.count!=pages.count || pages.count>30)return nil;
    NSMutableArray* edits=[NSMutableArray array];NSUInteger added=0,removed=0;
    for(NSUInteger i=0;i<pages.count;i++) {
        NSDictionary* before=previousPages[i],*after=pages[i];
        if(![before isKindOfClass:NSDictionary.class] || ![after isKindOfClass:NSDictionary.class])return nil;
        if(![before[@"page"] isEqual:after[@"page"]])return nil;
        NSString* old=before[@"text"],*next=after[@"text"];
        if(![old isKindOfClass:NSString.class] || ![next isKindOfClass:NSString.class])return nil;
        if([old isEqual:next])continue;
        NSUInteger prefix=0,suffix=0;
        while(prefix<MIN(old.length,next.length) && [old characterAtIndex:prefix]==[next characterAtIndex:prefix])prefix++;
        // Do not split surrogate pairs / composed characters in the JSON strings.
        if(prefix<old.length)prefix=MIN(prefix,[old rangeOfComposedCharacterSequenceAtIndex:prefix].location);
        if(prefix<next.length)prefix=MIN(prefix,[next rangeOfComposedCharacterSequenceAtIndex:prefix].location);
        while(suffix<MIN(old.length-prefix,next.length-prefix) &&
            [old characterAtIndex:old.length-suffix-1]==[next characterAtIndex:next.length-suffix-1])suffix++;
        if(suffix) {
            NSRange oldChar=[old rangeOfComposedCharacterSequenceAtIndex:old.length-suffix];
            NSRange newChar=[next rangeOfComposedCharacterSequenceAtIndex:next.length-suffix];
            NSUInteger oldEnd=oldChar.location==old.length-suffix ? oldChar.location : NSMaxRange(oldChar);
            NSUInteger newEnd=newChar.location==next.length-suffix ? newChar.location : NSMaxRange(newChar);
            suffix=MIN(old.length-oldEnd,next.length-newEnd);
        }
        NSRange oldRange=NSMakeRange(prefix,old.length-prefix-suffix),newRange=NSMakeRange(prefix,next.length-prefix-suffix);
        removed+=oldRange.length;added+=newRange.length;
        if(added+removed>budget)return nil;
        NSUInteger contextStart=prefix>120 ? prefix-120 : 0,contextEnd=MIN(next.length,NSMaxRange(newRange)+120);
        NSRange contextRange=[next rangeOfComposedCharacterSequencesForRange:NSMakeRange(contextStart,contextEnd-contextStart)];
        [edits addObject:@{@"page":after[@"page"],@"offsetUTF16":@(prefix),
            @"removed":[old substringWithRange:oldRange],@"inserted":[next substringWithRange:newRange],
            @"currentContext":[next substringWithRange:contextRange]}];
    }
    return @{@"edits":edits,@"addedCharacters":@(added),@"removedCharacters":@(removed),
        @"unit":@"UTF-16 code units",@"partial":@(partial),@"algorithm":@"one exact replacement per changed page"};
}
NSDictionary* SPDFAIRevisionDelta(NSArray* previousPages, NSArray* pages, BOOL partial) {
    return RevisionDelta(previousPages,pages,partial,32000);
}
static NSDictionary* BoundedIndex(SPDFMacCollectionStore* store,NSDictionary* version) {
    if([version[@"encrypted"] boolValue])return nil;
    NSString* filename=version[@"indexFile"];
    if(filename && ![filename isEqual:filename.lastPathComponent])return nil;
    if(filename) {
        NSString* path=[[[store.rootURL URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:filename] path];
        NSDictionary* attrs=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if(!attrs || [attrs[NSFileSize] unsignedLongLongValue]>4*1024*1024)return nil;
    }
    NSDictionary* index=[store textIndexForVersion:version];
    return [index[@"textPages"] isKindOfClass:NSArray.class] && [index[@"textPages"] count] ? index : nil;
}
NSDictionary* SPDFAICollectionRevisionDiff(SPDFMacCollectionStore* store, NSString* path, NSString* versionID, NSProgress* progress) {
    if(progress.cancelled)return @{@"diffStatus":@"cancelled"};
    NSDictionary* identity=SPDFAICollectionRevisionMetadata(store,path,0);
    NSDictionary* doc=[store readManifest][@"documents"][identity[@"analysisDocumentID"] ?: @""];
    NSArray* versions=doc[@"versions"] ?: @[];NSUInteger index=NSNotFound;
    for(NSUInteger i=0;i<versions.count;i++)if([versions[i][@"id"] isEqual:versionID]){index=i;break;}
    if(index==NSNotFound)return @{@"diffStatus":@"unavailable",@"reason":@"Revision is not in this document history."};
    if(!index)return @{@"diffStatus":@"firstRevision",@"reason":@"No preceding revision."};
    NSDictionary* previous=versions[index-1],*current=versions[index];
    if([previous[@"hash"] isEqual:current[@"hash"]])return @{@"diffStatus":@"identical",@"addedCharacters":@0,@"removedCharacters":@0,@"partial":@NO};
    NSDictionary* before=BoundedIndex(store,previous),*after=BoundedIndex(store,current);
    if(!before || !after)return @{@"diffStatus":@"unavailable",@"reason":@"Saved text indexes are unavailable, encrypted, or exceed the read budget."};
    NSMutableDictionary* oldPages=[NSMutableDictionary dictionary],*newPages=[NSMutableDictionary dictionary];
    NSMutableSet* pageIDs=[NSMutableSet set];
    for(NSDictionary* row in before[@"textPages"])if([row isKindOfClass:NSDictionary.class] && [row[@"page"] isKindOfClass:NSNumber.class] && [row[@"text"] isKindOfClass:NSString.class]){
        oldPages[row[@"page"]]=row[@"text"];[pageIDs addObject:row[@"page"]];
    }
    for(NSDictionary* row in after[@"textPages"])if([row isKindOfClass:NSDictionary.class] && [row[@"page"] isKindOfClass:NSNumber.class] && [row[@"text"] isKindOfClass:NSString.class]){
        newPages[row[@"page"]]=row[@"text"];[pageIDs addObject:row[@"page"]];
    }
    NSUInteger added=0,removed=0,read=0,count=0;
    for(NSNumber* page in [pageIDs.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        if(progress.cancelled)return @{@"diffStatus":@"cancelled"};
        NSString* old=oldPages[page] ?: @"",*next=newPages[page] ?: @"";
        if(count>=30 || old.length+next.length>128000-read)break;
        NSDictionary* delta=RevisionDelta(@[@{@"page":page,@"text":old}],@[@{@"page":page,@"text":next}],YES,128000);
        if(!delta)break;
        added+=[delta[@"addedCharacters"] unsignedIntegerValue];removed+=[delta[@"removedCharacters"] unsignedIntegerValue];
        read+=old.length+next.length;count++;
    }
    if(!count)return @{@"diffStatus":@"unavailable",@"reason":@"Indexed pages exceed the bounded diff budget."};
    return @{@"diffStatus":@"computed",@"versionID":versionID,@"previousVersionID":previous[@"id"],
        @"date":current[@"capturedAt"] ?: @0,@"addedCharacters":@(added),@"removedCharacters":@(removed),
        @"pagesCompared":@(count),@"partial":@YES,@"unit":@"UTF-16 code units",
        @"scope":@"Saved text excerpts only; image changes and text outside the index are not measured.",
        @"algorithm":@"one exact replacement per changed page"};
}
@interface SPDFMacAIRevisionBaseline ()
@property(nonatomic) NSURL* root;
@end
@implementation SPDFMacAIRevisionBaseline
- (instancetype)initWithRootURL:(NSURL*)root {if((self=[super init]))_root=root;return self;}
- (NSDictionary*)baselineForIdentity:(NSString*)identity {
    NSURL* URL=[self.root URLByAppendingPathComponent:[IdentityHash(identity) stringByAppendingString:@".json"]];
    NSDictionary* attrs=[NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:nil];
    if([attrs[NSFileSize] unsignedLongLongValue]>512*1024)return nil;
    NSData* data=[NSData dataWithContentsOfURL:URL];if(!data)return nil;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![value isKindOfClass:NSDictionary.class] || ![value[@"pages"] isKindOfClass:NSArray.class] ||
       ![value[@"analysis"] isKindOfClass:NSDictionary.class])return nil;
    return value;
}
- (BOOL)storeBaseline:(NSDictionary*)value identity:(NSString*)identity {
    NSData* bytes=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if(!bytes || bytes.length>512*1024)return NO;
    if(![NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil])return NO;
    NSURL* URL=[self.root URLByAppendingPathComponent:[IdentityHash(identity) stringByAppendingString:@".json"]];
    if(![bytes writeToURL:URL options:NSDataWritingAtomic error:nil])return NO;
    chmod(URL.fileSystemRepresentation,0600);return YES;
}
@end
