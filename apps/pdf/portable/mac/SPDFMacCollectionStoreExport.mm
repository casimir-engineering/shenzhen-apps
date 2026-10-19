#import "SPDFMacCollectionStorePrivate.h"
@implementation SPDFMacCollectionStore (Export)
- (NSDictionary*)archiveInfoForPath:(NSString*)path {
    NSDictionary* editable=[self editableInfoForPath:path];
    if (editable) return editable;
    NSString* resolved=path.stringByResolvingSymlinksInPath;
    NSString* previews=[[self.rootURL URLByAppendingPathComponent:@"previews"].path stringByResolvingSymlinksInPath];
    if (![resolved hasPrefix:[previews stringByAppendingString:@"/"]]) return nil;
    NSArray* parts=[[resolved substringFromIndex:previews.length+1] pathComponents];
    if (parts.count!=3) return nil;
    NSDictionary* doc=[self readManifest][@"documents"][parts[0]];
    NSDictionary* version=[self versionID:parts[1] document:doc];
    if (!version) return nil;
    NSMutableSet* filenames = [NSMutableSet set];
    if ([version[@"filename"] length]) [filenames addObject:version[@"filename"]];
    else {
        // Early Collection previews used the original's then-current basename.
        // A verified rename retains that old name in aliases, so restored tabs
        // remain tied to the same immutable revision after the original moves.
        for (NSString* alias in doc[@"aliases"]) [filenames addObject:alias.lastPathComponent];
        if ([doc[@"path"] length]) [filenames addObject:[doc[@"path"] lastPathComponent]];
    }
    if (![filenames containsObject:parts[2]]) return nil;
    return @{@"document":doc,@"version":version};
}
- (BOOL)exportVersionID:(NSString*)versionID documentID:(NSString*)documentID toURL:(NSURL*)URL error:(NSError**)error {
    if ([self isArchivePath:URL.path]) { if(error)*error=SPDFCollectionError(7,@"Choose a location outside Collection."); return NO; }
    if ([NSFileManager.defaultManager fileExistsAtPath:URL.path]) {
        if(error)*error=SPDFCollectionError(20,@"Save a Copy requires a new file name. Existing files are never overwritten."); return NO;
    }
    NSDictionary* original=[self readManifest][@"documents"][documentID];
    if ([URL.path.stringByResolvingSymlinksInPath isEqual:[original[@"path"] stringByResolvingSymlinksInPath]]) {
        if(error)*error=SPDFCollectionError(18,@"Save a Copy needs a separate destination from the original document."); return NO;
    }
    NSURL* preview=[self materializeVersionID:versionID documentID:documentID error:error];
    if (!preview) return NO;
    NSDictionary* version=[self versionID:versionID document:original];
    NSFileManager* fm=NSFileManager.defaultManager;
    // Preflight all conflicting assets before changing a destination, including an existing document.
    NSMutableArray* pending=[NSMutableArray array];
    for (NSDictionary* asset in version[@"assets"]) {
        NSURL* destination=[URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:asset[@"relativePath"]];
        if ([destination.path.stringByStandardizingPath isEqual:URL.path.stringByStandardizingPath]) {
            if(error)*error=SPDFCollectionError(10,@"The chosen document name conflicts with an archived asset."); return NO;
        }
        if ([fm fileExistsAtPath:destination.path]) {
            if (![SPDFCollectionHashURL(destination,error) isEqual:asset[@"hash"]]) {
                if(error)*error=SPDFCollectionError(10,@"An export asset already exists with different contents. Choose another folder."); return NO;
            }
        } else [pending addObject:asset];
    }
    NSURL* staging=[URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                    [@".szpdf-export-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (!SPDFCollectionMakeDirectory(staging,error)) return NO;
    NSMutableArray* installed=[NSMutableArray array]; BOOL success=NO;
    @try {
        NSData* source=[NSData dataWithContentsOfURL:preview options:0 error:error];
        if (!source || !SPDFCollectionAtomicData(source,[staging URLByAppendingPathComponent:@"document"],0600,error)) return NO;
        for (NSDictionary* asset in pending) {
            NSURL* from=[preview.URLByDeletingLastPathComponent URLByAppendingPathComponent:asset[@"relativePath"]];
            NSData* bytes=[NSData dataWithContentsOfURL:from options:0 error:error];
            if (!bytes || !SPDFCollectionAtomicData(bytes,[staging URLByAppendingPathComponent:asset[@"hash"]],0600,error)) return NO;
        }
        for (NSDictionary* asset in pending) {
            NSURL* target=[URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:asset[@"relativePath"]];
            if (!SPDFCollectionMakeDirectory(target.URLByDeletingLastPathComponent,error)) return NO;
            // Exclusive link installs our staged copy without clobbering a racing external writer.
            if (link([staging URLByAppendingPathComponent:asset[@"hash"]].fileSystemRepresentation,target.fileSystemRepresentation)!=0) {
                if(error)*error=SPDFCollectionError(errno,@"An export destination changed. No document was overwritten."); return NO;
            }
            [installed addObject:target];
        }
        // Exclusive installation closes the race between the initial check and an external creator.
        success=link([staging URLByAppendingPathComponent:@"document"].fileSystemRepresentation,URL.fileSystemRepresentation)==0;
        if (!success && error) *error=SPDFCollectionError(errno,@"The destination already exists or is unavailable. Choose a new file name.");
        if (success) { int fd=open(URL.URLByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY);
            if(fd>=0){fsync(fd);close(fd);} }
        return success;
    } @finally {
        if (!success) for (NSURL* target in installed) [fm removeItemAtURL:target error:nil];
        [fm removeItemAtURL:staging error:nil];
    }
}
@end
