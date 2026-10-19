#import "SPDFMacCollectionStorePrivate.h"

@implementation SPDFMacCollectionStore (Access)
- (BOOL)setExcluded:(BOOL)excluded path:(NSString*)path error:(NSError**)error {
    path=SPDFCollectionPath(path);
    return [self transaction:^BOOL(NSMutableDictionary* m,NSError** e) {
        (void)e; NSMutableDictionary* doc;
        for (NSMutableDictionary* d in [m[@"documents"] allValues])
            if (![d[@"sourceReplaced"] boolValue] && [d[@"path"] isEqual:path]) { doc=d; break; }
        if (!doc) {
            doc=[@{@"id":NSUUID.UUID.UUIDString,@"path":path,@"title":path.lastPathComponent,
                  @"aliases":@[path],@"versions":@[]} mutableCopy]; m[@"documents"][doc[@"id"]]=doc;
        }
        doc[@"excluded"]=@(excluded); return YES;
    } error:error];
}
- (BOOL)setExcluded:(BOOL)excluded documentID:(NSString*)documentID error:(NSError**)error {
    return [self transaction:^BOOL(NSMutableDictionary* m,NSError** e) {
        NSMutableDictionary* doc=m[@"documents"][documentID];
        if (!doc) { if(e)*e=SPDFCollectionError(8,@"Document history no longer exists."); return NO; }
        doc[@"excluded"]=@(excluded); return YES;
    } error:error];
}
- (BOOL)setKeep:(BOOL)keep versionID:(NSString*)versionID documentID:(NSString*)documentID error:(NSError**)error {
    return [self transaction:^BOOL(NSMutableDictionary* m,NSError** e) {
        NSMutableDictionary* v=(NSMutableDictionary*)[self versionID:versionID document:m[@"documents"][documentID]];
        if (!v) { if(e)*e=SPDFCollectionError(8,@"Version no longer exists."); return NO; }
        v[@"keep"]=@(keep); return YES;
    } error:error];
}
- (BOOL)deleteDocumentID:(NSString*)documentID versionID:(NSString*)versionID error:(NSError**)error {
    // First atomically remove references. Unreferenced objects are harmless if cleanup is interrupted.
    return [self transaction:^BOOL(NSMutableDictionary* m,NSError** e) {
        (void)e; NSMutableDictionary* docs=m[@"documents"];
        if (!documentID) {
            for (NSString* key in [docs.allKeys copy]) {
                NSMutableDictionary* doc=docs[key];
                if ([doc[@"excluded"] boolValue]) {
                    doc[@"versions"]=[NSMutableArray array]; [doc removeObjectForKey:@"latestVersionID"];
                    [doc removeObjectForKey:@"capturedAt"]; doc[@"status"]=@"Excluded";
                } else [docs removeObjectForKey:key];
            }
        }
        else if (!versionID) {
            NSMutableDictionary* doc=docs[documentID];
            // Exclusion is a future-capture preference, independent of deleting old history.
            if ([doc[@"excluded"] boolValue]) { doc[@"versions"]=[NSMutableArray array]; [doc removeObjectForKey:@"latestVersionID"]; }
            else [docs removeObjectForKey:documentID];
        } else {
            NSMutableDictionary* doc=docs[documentID]; NSMutableArray* versions=doc[@"versions"];
            NSIndexSet* matching=[versions indexesOfObjectsPassingTest:^BOOL(NSDictionary* v,NSUInteger i,BOOL* stop) {
                (void)i;(void)stop; return [v[@"id"] isEqual:versionID];
            }];
            [versions removeObjectsAtIndexes:matching];
            if (versions.count) { doc[@"latestVersionID"]=[versions lastObject][@"id"];
                doc[@"capturedAt"]=[versions lastObject][@"capturedAt"]; }
            else { [doc removeObjectForKey:@"latestVersionID"]; doc[@"status"]=@"Not protected"; }
        }
        m[@"_collectUnreferencedFiles"]=@YES;
        return YES;
    } error:error];
}
- (BOOL)deletePreviousBackupsForDocumentID:(NSString*)documentID error:(NSError**)error {
    return [self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        NSMutableDictionary* doc=manifest[@"documents"][documentID];
        if (!doc) { if(failure)*failure=SPDFCollectionError(8,@"Document history no longer exists."); return NO; }
        NSArray* versions=doc[@"versions"];
        NSDictionary* latest=[self versionID:doc[@"latestVersionID"] document:doc] ?: versions.lastObject;
        // Decide under the manifest lock: a capture during confirmation must
        // never turn the newest protected revision into a deletion target.
        doc[@"versions"]=latest ? [NSMutableArray arrayWithObject:latest] : [NSMutableArray array];
        if (latest) { doc[@"latestVersionID"]=latest[@"id"]; doc[@"capturedAt"]=latest[@"capturedAt"]; }
        manifest[@"_collectUnreferencedFiles"]=@YES;
        return YES;
    } error:error];
}
- (NSURL*)materializeVersionID:(NSString*)versionID documentID:(NSString*)documentID error:(NSError**)error {
    __block NSURL* result;
    // Preview files may be created/repaired, but no library metadata changes.
    // Avoid serializing and fsyncing the whole history for every thumbnail.
    BOOL ok=[self withLockedManifest:^BOOL(NSMutableDictionary* m,NSError** e) {
        NSDictionary* doc=m[@"documents"][documentID]; NSDictionary* version=[self versionID:versionID document:doc];
        if (!version) { if(e)*e=SPDFCollectionError(8,@"Version no longer exists."); return NO; }
        NSURL* directory=[[[self.rootURL URLByAppendingPathComponent:@"previews"] URLByAppendingPathComponent:documentID]
                          URLByAppendingPathComponent:versionID];
        if (!SPDFCollectionMakeDirectory(directory,e)) return NO;
        NSMutableArray* entries=[NSMutableArray arrayWithObject:@{@"hash":version[@"hash"],
                 @"relativePath":version[@"filename"] ?: [doc[@"path"] lastPathComponent] ?: @"document"}];
        [entries addObjectsFromArray:version[@"assets"] ?: @[]];
        for (NSDictionary* entry in entries) {
            NSString* relative=entry[@"relativePath"];
            if ([relative hasPrefix:@"/"] || [relative.pathComponents containsObject:@".."] || !relative.length) {
                if(e)*e=SPDFCollectionError(9,@"Invalid archive dependency path."); return NO;
            }
            NSURL* source=[self blobURL:entry[@"hash"]];
            if (![SPDFCollectionHashURL(source,e) isEqual:entry[@"hash"]]) {
                if(e && !*e)*e=SPDFCollectionError(3,@"Archived bytes failed their integrity check."); return NO;
            }
            NSURL* destination=[directory URLByAppendingPathComponent:relative];
            if (!SPDFCollectionMakeDirectory(destination.URLByDeletingLastPathComponent,e)) return NO;
            // A copy (never a hard link) prevents another process from mutating the content-addressed object.
            NSData* bytes=[NSData dataWithContentsOfURL:source options:0 error:e];
            if (!bytes) return NO;
            struct stat existing;
            BOOL reusable = lstat(destination.fileSystemRepresentation,&existing)==0 &&
                S_ISREG(existing.st_mode) && (existing.st_mode & 0777)==0400 &&
                [bytes isEqualToData:[NSData dataWithContentsOfURL:destination]];
            // Preserve the identity of a verified read-only preview: session passwords
            // are bound to that identity, and thumbnails must not invalidate them.
            if (!reusable && !SPDFCollectionAtomicData(bytes,destination,0400,e)) return NO;
        }
        result=[directory URLByAppendingPathComponent:entries.firstObject[@"relativePath"]]; return YES;
    } error:error];
    return ok ? result : nil;
}
- (BOOL)linkDocumentID:(NSString*)documentID toPath:(NSString*)path allowMismatch:(BOOL)allowMismatch error:(NSError**)error {
    return [self linkDocumentID:documentID toPath:path allowMismatch:allowMismatch forgettingPath:nil error:error];
}
- (BOOL)rebaseDocumentID:(NSString*)documentID toPath:(NSString*)path forgettingPath:(NSString*)oldPath error:(NSError**)error {
    return [self linkDocumentID:documentID toPath:path allowMismatch:YES forgettingPath:oldPath error:error];
}
- (BOOL)linkDocumentID:(NSString*)documentID toPath:(NSString*)path allowMismatch:(BOOL)allowMismatch
        forgettingPath:(NSString*)oldPath error:(NSError**)error {
    path=SPDFCollectionPath(path);
    if ([self isArchivePath:path]) { if(error)*error=SPDFCollectionError(11,@"Choose an original outside Collection."); return NO; }
    NSString* hash=SPDFCollectionHashURL([NSURL fileURLWithPath:path],error); if (!hash) return NO;
    return [self transaction:^BOOL(NSMutableDictionary* m,NSError** e) {
        NSMutableDictionary* doc=m[@"documents"][documentID]; NSDictionary* latest=[doc[@"versions"] lastObject];
        if (!doc) { if(e)*e=SPDFCollectionError(8,@"Document history no longer exists."); return NO; }
        if (![latest[@"hash"] isEqual:hash] && !allowMismatch) {
            if(e)*e=SPDFCollectionError(12,@"Selected file differs from the last protected revision. Confirm linking a changed document."); return NO;
        }
        for (NSDictionary* other in [m[@"documents"] allValues])
            if (![other[@"id"] isEqual:documentID] && [other[@"path"] isEqual:path]) {
                if(e)*e=SPDFCollectionError(13,@"Selected path already belongs to a separate document history."); return NO;
            }
        NSMutableArray* aliases=[doc[@"aliases"] mutableCopy] ?: [NSMutableArray array];
        if (![aliases containsObject:doc[@"path"]]) [aliases addObject:doc[@"path"]];
        if (![aliases containsObject:path]) [aliases addObject:path];
        if (oldPath.length && ![SPDFCollectionPath(oldPath) isEqual:path]) [aliases removeObject:SPDFCollectionPath(oldPath)];
        doc[@"aliases"]=aliases; doc[@"path"]=path; doc[@"title"]=path.lastPathComponent;
        [doc removeObjectForKey:@"sourceReplaced"]; [doc removeObjectForKey:@"originalUnavailable"];
        doc[@"status"]=[latest[@"hash"] isEqual:hash] ? @"Protected" : @"Not protected";
        [doc removeObjectForKey:@"captureError"];
        struct stat info={}; if (lstat(path.fileSystemRepresentation,&info)==0)
            doc[@"fileIdentity"]=[NSString stringWithFormat:@"%llu:%llu",(unsigned long long)info.st_dev,(unsigned long long)info.st_ino];
        return YES;
    } error:error];
}
@end
