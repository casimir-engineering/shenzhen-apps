#import "SPDFMacCollectionStorePrivate.h"

static BOOL ValidComponent(NSString* value) {
    return value.length && [value isEqual:value.lastPathComponent] &&
        ![value isEqual:@"."] && ![value isEqual:@".."];
}
static NSURL* CopyURL(NSURL* root, NSString* documentID, NSString* copyID, NSString* filename) {
    if (!ValidComponent(documentID) || !ValidComponent(copyID) || !ValidComponent(filename)) return nil;
    return [[[[root URLByAppendingPathComponent:@"editable"] URLByAppendingPathComponent:documentID]
        URLByAppendingPathComponent:copyID] URLByAppendingPathComponent:filename];
}
@implementation SPDFMacCollectionStore (EditableDocuments)
- (void)recordUnavailableSourcePath:(NSString*)path documentID:(NSString*)documentID {
    // Only actual failed reader opens call this, on their recovery worker.
    // Readable metadata is not evidence of readable document contents (TCC/ACLs).
    [self transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
        (void)error; NSMutableDictionary* doc=manifest[@"documents"][documentID];
        if (![doc[@"path"] isEqual:path]) return NO;
        doc[@"originalUnavailable"]=@YES;
        doc[@"status"]=[NSFileManager.defaultManager fileExistsAtPath:path] ? @"Original unavailable" : @"Original missing";
        return YES;
    } error:nil];
}
- (NSDictionary*)editableInfoForPath:(NSString*)path {
    // Ordinary paths do not read the manifest or create directories.
    if (![path.pathComponents containsObject:@"editable"]) return nil;
    NSString* root=[self.rootURL.path.stringByResolvingSymlinksInPath stringByAppendingPathComponent:@"editable"];
    NSString* resolved=path.stringByResolvingSymlinksInPath;
    if (![resolved hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    NSArray* parts=[[resolved substringFromIndex:root.length+1] pathComponents];
    if (parts.count!=3) return nil;
    NSDictionary* doc=[self readManifest][@"documents"][parts[0]];
    NSDictionary* copy=doc[@"editableCopies"][parts[1]];
    if (!copy || (![copy[@"filename"] isEqual:parts[2]] && ![copy[@"previousNames"] containsObject:parts[2]])) return nil;
    NSDictionary* version=[self versionID:copy[@"currentVersionID"] document:doc] ?: [doc[@"versions"] lastObject];
    return @{@"document":doc,@"version":version ?: @{},@"copyID":parts[1],@"editable":@YES};
}
- (NSArray<NSString*>*)editablePathsForDocument:(NSDictionary*)document {
    NSMutableArray* paths=[NSMutableArray array];
    NSDictionary* copies=[document[@"editableCopies"] isKindOfClass:NSDictionary.class] ? document[@"editableCopies"] : nil;
    for (NSString* key in copies) {
        id filename=[copies[key] isKindOfClass:NSDictionary.class] ? copies[key][@"filename"] : nil;
        NSURL* URL=[filename isKindOfClass:NSString.class] ? CopyURL(self.rootURL,document[@"id"],key,filename) : nil;
        if (URL && [NSFileManager.defaultManager fileExistsAtPath:URL.path]) [paths addObject:URL.path];
    }
    return paths;
}
- (NSURL*)editableVersionID:(NSString*)versionID documentID:(NSString*)documentID error:(NSError**)error {
    __block NSURL* result;
    __block NSURL* createdDirectory;
    BOOL ok=[self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        NSMutableDictionary* doc=manifest[@"documents"][documentID];
        NSDictionary* version=[self versionID:versionID ?: doc[@"latestVersionID"] document:doc];
        if (!version) { if(failure)*failure=SPDFCollectionError(8,@"No saved document is available."); return NO; }
        NSMutableDictionary* copies=doc[@"editableCopies"];
        for (NSString* key in copies) {
            NSDictionary* copy=copies[key];
            if (![copy[@"currentVersionID"] isEqual:version[@"id"]]) continue;
            NSURL* URL=CopyURL(self.rootURL,documentID,key,copy[@"filename"]);
            if (URL && [NSFileManager.defaultManager fileExistsAtPath:URL.path]) { result=URL; return YES; }
        }
        NSString* key=NSUUID.UUID.UUIDString;
        NSString* filename=doc[@"title"] ?: version[@"filename"] ?: @"document";
        NSURL* URL=CopyURL(self.rootURL,documentID,key,filename);
        if (!URL) { if(failure)*failure=SPDFCollectionError(9,@"Invalid Collection document name."); return NO; }
        createdDirectory=URL.URLByDeletingLastPathComponent;
        NSMutableArray* entries=[NSMutableArray arrayWithObject:@{@"hash":version[@"hash"],@"relativePath":filename}];
        [entries addObjectsFromArray:version[@"assets"] ?: @[]];
        for (NSDictionary* entry in entries) {
            NSString* relative=entry[@"relativePath"];
            if (!relative.length || relative.isAbsolutePath || [relative.pathComponents containsObject:@".."] ||
                (entry!=entries.firstObject && [relative isEqual:filename])) {
                if(failure)*failure=SPDFCollectionError(9,@"Invalid Collection asset path."); return NO;
            }
            NSURL* blob=[self blobURL:entry[@"hash"]];
            if (![SPDFCollectionHashURL(blob,failure) isEqual:entry[@"hash"]]) return NO;
            NSData* data=[NSData dataWithContentsOfURL:blob options:0 error:failure];
            NSURL* destination=[URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:relative];
            // Independent writable bytes: editing can never alter a deduplicated snapshot.
            if (!data || !SPDFCollectionMakeDirectory(destination.URLByDeletingLastPathComponent,failure) ||
                !SPDFCollectionAtomicData(data,destination,0600,failure)) return NO;
        }
        if (!copies) doc[@"editableCopies"]=copies=[NSMutableDictionary dictionary];
        copies[key]=[@{@"filename":filename,@"currentVersionID":version[@"id"]} mutableCopy];
        result=URL; return YES;
    } error:error];
    if (!ok && createdDirectory) [NSFileManager.defaultManager removeItemAtURL:createdDirectory error:nil];
    return ok ? result : nil;
}
- (NSDictionary*)captureEditablePath:(NSString*)path reason:(NSString*)reason error:(NSError**)error {
    NSDictionary* info=[self editableInfoForPath:path];
    if (!info) return nil;
    __block NSDictionary* result;
    BOOL ok=[self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        NSMutableDictionary* doc=manifest[@"documents"][info[@"document"][@"id"]];
        if (![self captureRequestIsCurrentForPath:path] || ![self captureEpochIsCurrentForPath:path document:doc]) return NO;
        NSMutableDictionary* copy=doc[@"editableCopies"][info[@"copyID"]];
        NSURL* URL=CopyURL(self.rootURL,doc[@"id"],info[@"copyID"],copy[@"filename"]);
        if (!URL || ![URL.path.stringByResolvingSymlinksInPath isEqual:path.stringByResolvingSymlinksInPath]) return NO;
        NSDictionary* before=SPDFCollectionFingerprint(path);
        NSDictionary* current=[self versionID:copy[@"currentVersionID"] document:doc];
        NSData* bytes=[NSData dataWithContentsOfFile:path options:0 error:failure];
        if (!bytes) return NO;
        NSDictionary* dependencies=SPDFCollectionAssets(path,bytes);
        NSMutableArray* assets=[NSMutableArray array];
        for (NSDictionary* entry in dependencies[@"entries"]) {
            NSMutableDictionary* asset=[entry mutableCopy];
            [asset removeObjectForKey:@"data"]; [asset removeObjectForKey:@"captureFingerprint"]; [assets addObject:asset];
        }
        // Consulting an unchanged historical version must not promote it to latest.
        if ([SPDFCollectionHashURL(URL,failure) isEqual:current[@"hash"]] &&
            [assets isEqual:current[@"assets"]] && [dependencies[@"warnings"] isEqual:current[@"assetWarnings"]]) {
            if (![SPDFCollectionHashURL([self blobURL:current[@"hash"]],failure) isEqual:current[@"hash"]]) return NO;
            for (NSDictionary* asset in assets)
                if (![SPDFCollectionHashURL([self blobURL:asset[@"hash"]],failure) isEqual:asset[@"hash"]]) return NO;
            if (![before isEqual:SPDFCollectionFingerprint(path)]) {
                if(failure)*failure=SPDFCollectionSourceUnavailable(@"Document changed while protecting its history. Retry."); return NO;
            }
            copy[@"fingerprint"]=before; [self recordCaptureUserOpenInDocument:doc path:path]; result=doc; return YES;
        }
        // Reuse the complete snapshot/integrity pipeline under the same lock.
        // Its temporary source binding never escapes into the saved manifest.
        NSArray* keys=@[@"path",@"aliases",@"title",@"fileIdentity",@"sourceReplaced",@"originalUnavailable",
            @"sourceFingerprint",@"dependencyFingerprints",@"objectFingerprints",@"status",@"captureError"];
        NSMutableDictionary* original=[NSMutableDictionary dictionary];
        for (NSString* key in keys) original[key]=doc[key] ?: NSNull.null;
        doc[@"path"]=path; [doc removeObjectForKey:@"sourceReplaced"]; [doc removeObjectForKey:@"originalUnavailable"];
        [doc removeObjectForKey:@"fileIdentity"];
        @try {
            result=[self captureLockedPath:path reason:reason continuingDocumentID:doc[@"id"] manifest:manifest error:failure];
            if (result) {
                copy[@"currentVersionID"]=doc[@"latestVersionID"];
                copy[@"fingerprint"]=doc[@"sourceFingerprint"];
            }
        } @finally {
            for (NSString* key in keys) {
                if (original[key]==NSNull.null) [doc removeObjectForKey:key]; else doc[key]=original[key];
            }
        }
        return result!=nil;
    } error:error];
    if (ok) [self markCaptureUserOpenRecordedForPath:path];
    return ok ? [self readManifest][@"documents"][info[@"document"][@"id"]] : nil;
}
- (NSURL*)renameEditablePath:(NSString*)path filename:(NSString*)filename error:(NSError**)error {
    return [self renameEditablePath:path filename:filename documentTitle:filename expectedTitle:nil error:error];
}
- (NSURL*)renameEditablePath:(NSString*)path filename:(NSString*)filename
    documentTitle:(NSString*)title expectedTitle:(NSString*)expectedTitle error:(NSError**)error {
    if (!ValidComponent(filename) || [filename containsString:@":"]) {
        if(error)*error=SPDFCollectionError(9,@"Enter a valid document filename."); return nil;
    }
    NSDictionary* info=[self editableInfoForPath:path];
    if (!info) return nil;
    __block NSURL* renamed; __block BOOL installed=NO;
    BOOL ok=[self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        NSMutableDictionary* doc=manifest[@"documents"][info[@"document"][@"id"]];
        NSMutableDictionary* copy=doc[@"editableCopies"][info[@"copyID"]];
        if (expectedTitle && ![doc[@"title"] isEqual:expectedTitle]) {
            if(failure)*failure=SPDFCollectionError(9,@"The Collection name changed. Read the document again before renaming it."); return NO;
        }
        NSURL* source=CopyURL(self.rootURL,doc[@"id"],info[@"copyID"],copy[@"filename"]);
        renamed=CopyURL(self.rootURL,doc[@"id"],info[@"copyID"],filename);
        if (!source || !renamed || ![source.path.stringByResolvingSymlinksInPath isEqual:path.stringByResolvingSymlinksInPath]) return NO;
        if ([source isEqual:renamed]) return YES;
        if (link(source.fileSystemRepresentation,renamed.fileSystemRepresentation)!=0) {
            if(failure)*failure=SPDFCollectionError(errno,@"This name already exists or the document cannot be renamed."); return NO;
        }
        installed=YES;
        NSMutableArray* names=[copy[@"previousNames"] mutableCopy] ?: [NSMutableArray array];
        [names addObject:copy[@"filename"]]; copy[@"previousNames"]=names;
        copy[@"filename"]=filename; doc[@"title"]=title;
        return YES;
    } error:error];
    if (installed) unlink((ok ? path : renamed.path).fileSystemRepresentation);
    return ok ? renamed : nil;
}
- (void)rememberGroup:(NSDictionary*)group documentID:(NSString*)documentID {
    if (group.count && documentID.length) [self rememberGroups:@{documentID:group}];
}
- (void)rememberGroups:(NSDictionary<NSString*,NSDictionary*>*)groups {
    if (!groups.count) return;
    NSDictionary* documents=[self readManifest][@"documents"];
    NSMutableDictionary* changes=[NSMutableDictionary dictionary];
    for (NSString* identifier in groups) {
        NSDictionary* group=groups[identifier];
        NSDictionary* identity=[group dictionaryWithValuesForKeys:@[@"id",@"name",@"color"]];
        if (documents[identifier] && ![documents[identifier][@"tabGroup"] isEqual:identity]) changes[identifier]=identity;
    }
    if (!changes.count) return;
    [self transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
        (void)error;
        for (NSString* identifier in changes) {
            NSMutableDictionary* doc=manifest[@"documents"][identifier];
            if (doc) doc[@"tabGroup"]=changes[identifier];
        }
        return YES;
    } error:nil];
}
@end
