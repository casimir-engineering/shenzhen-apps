#import "SPDFMacCollectionStorePrivate.h"
#include <stdio.h>

static BOOL MoveError(NSError** error,NSString* message) {
    if(error)*error=SPDFCollectionError(errno ?: 15,message);return NO;
}
static BOOL SyncDirectory(NSURL* URL,NSError** error) {
    int descriptor=open(URL.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(descriptor<0)return MoveError(error,@"Collection folder could not be synchronized.");
    BOOL ok=fsync(descriptor)==0;close(descriptor);
    return ok || MoveError(error,@"Collection folder could not be synchronized.");
}
static BOOL CopyVerified(NSURL* source,NSURL* target,mode_t mode,NSError** error) {
    NSFileManager* manager=NSFileManager.defaultManager;
    struct stat sourceInfo={},targetInfo={};
    if(lstat(source.fileSystemRepresentation,&sourceInfo) || !S_ISREG(sourceInfo.st_mode))
        return MoveError(error,@"Collection contains an unsupported file. Original storage is unchanged.");
    if(![manager copyItemAtURL:source toURL:target error:error])return NO;
    if(lstat(target.fileSystemRepresentation,&targetInfo) || !S_ISREG(targetInfo.st_mode))
        return MoveError(error,@"A Collection file changed during copying. Original storage is unchanged.");
    if(chmod(target.fileSystemRepresentation,mode))return MoveError(error,@"Collection copy permissions could not be preserved.");
    int descriptor=open(target.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(descriptor<0)return MoveError(error,@"Collection copy could not be verified.");
    BOOL durable=fsync(descriptor)==0;close(descriptor);
    if(!durable)return MoveError(error,@"Collection copy could not be synchronized.");
    NSString* original=SPDFCollectionHashURL(source,error),*copied=SPDFCollectionHashURL(target,error);
    if(!original || ![original isEqual:copied])return MoveError(error,@"Collection move failed integrity verification; original storage is unchanged.");
    return YES;
}
static BOOL PreserveLegacyPath(NSURL* old,NSURL* destination,NSString* name,NSError** error) {
    NSFileManager* manager=NSFileManager.defaultManager;
    NSURL* original=[old URLByAppendingPathComponent:name],*target=[destination URLByAppendingPathComponent:name];
    struct stat info={};
    if(lstat(original.fileSystemRepresentation,&info)==0 && S_ISLNK(info.st_mode)) {
        NSString* link=[manager destinationOfSymbolicLinkAtPath:original.path error:nil];
        if([link isEqual:target.path])return YES;
    }
    NSURL* temporary=[old URLByAppendingPathComponent:[@".move-link-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![manager createSymbolicLinkAtURL:temporary withDestinationURL:target error:error])return NO;
    BOOL exists=lstat(original.fileSystemRepresentation,&info)==0;
    // Swap atomically: saved tab paths always address either the verified old tree
    // or its new location. The old payload ends up at our temporary name.
    int result=renameatx_np(AT_FDCWD,temporary.fileSystemRepresentation,AT_FDCWD,original.fileSystemRepresentation,
        exists ? RENAME_SWAP : RENAME_EXCL);
    if(result) { [manager removeItemAtURL:temporary error:nil];return MoveError(error,@"Collection moved, but a legacy document path could not be reconnected."); }
    if(exists && ![manager removeItemAtURL:temporary error:error])return NO;
    return YES;
}
static NSArray* EditableEntries(NSURL* folder,NSError** error) {
    struct stat info={};
    if(lstat(folder.fileSystemRepresentation,&info)) {
        if(errno==ENOENT)return @[];
        MoveError(error,@"Editable Collection files could not be inspected safely.");return nil;
    }
    return [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder.path error:error];
}
static BOOL RemoveOldPayload(NSURL* old,NSURL* destination,NSError** error) {
    NSURL* editable=[old URLByAppendingPathComponent:@"editable"];struct stat info={};
    if(lstat(editable.fileSystemRepresentation,&info)==0 && S_ISDIR(info.st_mode)) {
        NSArray* entries=EditableEntries(editable,error);
        if(!entries)return NO;
        if(entries.count)return MoveError(error,[NSString stringWithFormat:@"Previous editable Collection files remain at %@ and may contain newer edits. They were not removed. Preserve and reconcile those files before retrying cleanup.",editable.path]);
    }
    for(NSString* name in @[@"previews",@"editable"])
        if(!PreserveLegacyPath(old,destination,name,error))return NO;
    NSArray* names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:old.path error:error];
    if(!names)return NO;
    NSSet* routing=[NSSet setWithArray:@[@"redirect.json",@"collection.lock",@"previews",@"editable"]];
    for(NSString* name in names)if(![routing containsObject:name])
        if(![NSFileManager.defaultManager removeItemAtURL:[old URLByAppendingPathComponent:name] error:error])return NO;
    return SyncDirectory(old,error);
}
static BOOL FinishRedirectCleanup(NSURL* original,NSURL* active,NSError** error) {
    NSURL* current=original;
    for(NSUInteger hop=0;hop<8 && ![current.path.stringByStandardizingPath isEqual:active.path.stringByStandardizingPath];hop++) {
        NSData* data=[NSData dataWithContentsOfURL:[current URLByAppendingPathComponent:@"redirect.json"]];
        NSDictionary* redirect=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString* path=[redirect isKindOfClass:NSDictionary.class] ? redirect[@"path"] : nil;
        if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath)return MoveError(error,@"Collection moved, but its previous location is unavailable for cleanup.");
        NSURL* next=[NSURL fileURLWithPath:path];
        if(!RemoveOldPayload(current,next,error))return NO;
        current=next;
    }
    return [current.path.stringByStandardizingPath isEqual:active.path.stringByStandardizingPath] || MoveError(error,@"Collection location has too many redirects to complete cleanup.");
}
@interface SPDFMacCollectionStore (RelocationPrivate)
- (BOOL)relocationSharesVolumeFrom:(NSURL*)old to:(NSURL*)destination;
- (BOOL)transferEditableTreeFrom:(NSURL*)old to:(NSURL*)destination transferred:(BOOL*)transferred error:(NSError**)error;
@end
@implementation SPDFMacCollectionStore (Location)
- (BOOL)relocationSharesVolumeFrom:(NSURL*)old to:(NSURL*)destination {
    struct stat source={},target={};
    return stat(old.fileSystemRepresentation,&source)==0 && stat(destination.fileSystemRepresentation,&target)==0 && source.st_dev==target.st_dev;
}
- (BOOL)transferEditableTreeFrom:(NSURL*)old to:(NSURL*)destination transferred:(BOOL*)transferred error:(NSError**)error {
    NSURL* source=[old URLByAppendingPathComponent:@"editable"],*target=[destination URLByAppendingPathComponent:@"editable"];
    NSArray* entries=EditableEntries(source,error);
    if(!entries)return NO;
    if(!entries.count)return YES;
    if(![self relocationSharesVolumeFrom:old to:destination])
        return MoveError(error,@"This Collection contains editable documents. To preserve edits safely, choose a Collection folder on the same disk.");
    // The destination is still unpublished. Replace its disposable copied tree
    // with a self-pointing symlink, then atomically exchange it with the ORIGINAL
    // directory. Both old paths and already-open file descriptors retain the same
    // live inodes; a save after initial copying cannot be discarded.
    if(![NSFileManager.defaultManager removeItemAtURL:target error:error])return NO;
    if(![NSFileManager.defaultManager createSymbolicLinkAtURL:target withDestinationURL:target error:error])return NO;
    if(renameatx_np(AT_FDCWD,source.fileSystemRepresentation,AT_FDCWD,target.fileSystemRepresentation,RENAME_SWAP))
        return MoveError(error,@"Editable Collection files could not be transferred safely. Original storage is unchanged.");
    *transferred=YES;
    return SyncDirectory(old,error) && SyncDirectory(destination,error);
}
- (BOOL)relocateToURL:(NSURL*)URL error:(NSError**)error {
    URL=URL.URLByStandardizingPath;
    NSURL* old=self.rootURL;
    NSString* destination=URL.path.stringByResolvingSymlinksInPath, *source=old.path.stringByResolvingSymlinksInPath;
    if([destination isEqual:source])return FinishRedirectCleanup(self.originalRootURL,old,error);
    if([destination hasPrefix:[source stringByAppendingString:@"/"]] || [source hasPrefix:[destination stringByAppendingString:@"/"]])
        return MoveError(error,@"Choose a separate, empty Collection folder.");
    NSArray* existing=[NSFileManager.defaultManager contentsOfDirectoryAtPath:URL.path error:nil];
    if(existing.count)return MoveError(error,@"The new Collection folder must be empty.");
    BOOL moved=[self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        if(![self.rootURL isEqual:old])return MoveError(failure,@"Another window moved Collection. Retry from its new location.");
        NSURL* editableRoot=[old URLByAppendingPathComponent:@"editable"];struct stat editableInfo={};
        if(lstat(editableRoot.fileSystemRepresentation,&editableInfo)==0 && S_ISLNK(editableInfo.st_mode)) {
            NSString* retained=[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:editableRoot.path error:nil] ?: editableRoot.path;
            return MoveError(failure,[NSString stringWithFormat:@"A previous Collection move was interrupted. Editable documents remain available at %@. Preserve that folder and recover the interrupted move before choosing another location.",retained]);
        }
        if(!SPDFCollectionMakeDirectory(URL.URLByDeletingLastPathComponent,failure))return NO;
        NSURL* staging=[URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".szpdf-collection-move-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if(!SPDFCollectionMakeDirectory(staging,failure))return NO;
        BOOL installed=NO,switched=NO,editableTransferred=NO;
        @try {
            NSURL* editable=[old URLByAppendingPathComponent:@"editable"];
            NSArray* entries=EditableEntries(editable,failure);
            if(!entries)return NO;
            if(entries.count && ![self relocationSharesVolumeFrom:old to:staging])
                return MoveError(failure,@"This Collection contains editable documents. To preserve edits safely, choose a Collection folder on the same disk.");
            __block NSError* enumerationError=nil;
            NSDirectoryEnumerator* enumerator=[NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:source]
                includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey] options:0
                errorHandler:^BOOL(NSURL* item,NSError* error){(void)item;enumerationError=error;return NO;}];
            NSMutableArray* directories=[NSMutableArray arrayWithObject:staging];
            for(NSURL* item in enumerator) {
                NSDictionary* values=[item resourceValuesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey] error:failure];
                if(!values)return NO;
                if([values[NSURLIsSymbolicLinkKey] boolValue]){[enumerator skipDescendants];continue;}
                NSString* canonical=item.path.stringByResolvingSymlinksInPath;
                if(![canonical hasPrefix:[source stringByAppendingString:@"/"]])
                    return MoveError(failure,@"A Collection file moved outside its source folder during relocation.");
                NSString* relative=[canonical substringFromIndex:source.length+1];
                if([@[@"collection.lock",@"redirect.json",@"manifest.json"] containsObject:relative])continue;
                NSURL* target=[staging URLByAppendingPathComponent:relative];
                if([values[NSURLIsDirectoryKey] boolValue]) {
                    if(!SPDFCollectionMakeDirectory(target,failure))return NO;
                    [directories addObject:target];continue;
                }
                if(!CopyVerified(item,target,[relative hasPrefix:@"editable/"] ? 0600 : 0400,failure))return NO;
            }
            if(enumerationError){if(failure)*failure=enumerationError;return NO;}
            NSData* bytes=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:failure];
            if(!bytes || !SPDFCollectionAtomicData(bytes,[staging URLByAppendingPathComponent:@"manifest.json"],0600,failure))return NO;
            for(NSURL* directory in directories.reverseObjectEnumerator)if(!SyncDirectory(directory,failure))return NO;
            // rmdir refuses a racing nonempty destination; exclusive rename never overwrites it.
            struct stat destinationInfo={};
            if(lstat(URL.fileSystemRepresentation,&destinationInfo)==0 && rmdir(URL.fileSystemRepresentation))
                return MoveError(failure,@"The destination is no longer an empty folder.");
            if(renameatx_np(AT_FDCWD,staging.fileSystemRepresentation,AT_FDCWD,URL.fileSystemRepresentation,RENAME_EXCL))
                return MoveError(failure,@"The destination changed while Collection was moving. Original storage is unchanged.");
            installed=YES;
            if(!SyncDirectory(URL.URLByDeletingLastPathComponent,failure))return NO;
            if(![self transferEditableTreeFrom:old to:URL transferred:&editableTransferred error:failure])return NO;
            NSData* redirect=[NSJSONSerialization dataWithJSONObject:@{@"path":URL.path} options:0 error:failure];
            if(!redirect || !SPDFCollectionAtomicData(redirect,[old URLByAppendingPathComponent:@"redirect.json"],0600,failure)) {
                // AtomicData can install the redirect before a directory fsync fails.
                // Never roll back the destination once any reader can follow that redirect.
                NSData* installedRedirect=[NSData dataWithContentsOfURL:[old URLByAppendingPathComponent:@"redirect.json"]];
                NSDictionary* routing=installedRedirect ? [NSJSONSerialization JSONObjectWithData:installedRedirect options:0 error:nil] : nil;
                switched=[routing[@"path"] isEqual:URL.path];return NO;
            }
            switched=YES;
            if(!RemoveOldPayload(old,URL,failure)) {
                if(failure)*failure=SPDFCollectionError(21,@"Collection is safe at its new location, but previous files could not all be removed. Select the same location again to finish cleanup.");
                return NO;
            }
            return YES;
        } @finally {
            BOOL safeToRemove=!switched;
            if(!switched && editableTransferred) {
                NSURL* from=[old URLByAppendingPathComponent:@"editable"],*to=[URL URLByAppendingPathComponent:@"editable"];
                if(renameatx_np(AT_FDCWD,from.fileSystemRepresentation,AT_FDCWD,to.fileSystemRepresentation,RENAME_SWAP)) {
                    safeToRemove=NO;
                    if(failure)*failure=SPDFCollectionError(21,@"Collection move stopped. Editable documents remain accessible through the original folder and are retained at the destination for recovery.");
                }
            }
            if(safeToRemove)[NSFileManager.defaultManager removeItemAtURL:installed ? URL : staging error:nil];
        }
    } error:error];
    return moved && FinishRedirectCleanup(self.originalRootURL,URL,error);
}
@end
