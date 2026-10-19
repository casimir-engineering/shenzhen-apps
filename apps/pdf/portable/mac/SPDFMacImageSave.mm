#import "SPDFMacImageSave.h"
#import "SPDFMacCollectionPathPolicy.h"
#include "spdf_document_export.h"
#include <sys/stat.h>
#include <stdio.h>
#include <fcntl.h>

static BOOL Failure(NSString* message, NSError** error) {
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.ImageSave" code:1
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Could not save the image."}];
    return NO;
}

NSDictionary* SPDFImageSaveDestinationIdentity(NSString* path) {
    struct stat value = {};
    if (lstat(path.fileSystemRepresentation, &value) != 0)
        return errno == ENOENT ? @{@"exists":@NO} : nil;
    return @{@"exists":@YES, @"device":@(value.st_dev), @"inode":@(value.st_ino), @"size":@(value.st_size),
        @"modified":@(value.st_mtimespec.tv_sec), @"modifiedNS":@(value.st_mtimespec.tv_nsec),
        @"changed":@(value.st_ctimespec.tv_sec), @"changedNS":@(value.st_ctimespec.tv_nsec)};
}

BOOL SPDFSaveImageCopy(NSString* source, NSString* destination, BOOL asPDF, NSError** error,
                       NSDictionary* expectedDestination) {
    if (!source.length || !destination.length) return Failure(@"Choose a file name for the copy.", error);
    if (SPDFMacPathIsCollectionArchive(destination))
        return Failure(@"Choose a location outside Collection. Saved backups are read-only.", error);
    NSDictionary* expected = expectedDestination ?: SPDFImageSaveDestinationIdentity(destination);
    if (!expected) return Failure(@"Could not inspect the destination. Choose another location.", error);
    NSString* sourcePath = source.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString* destinationPath = destination.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    struct stat sourceStat = {}, destinationStat = {};
    BOOL sameFile = stat(source.fileSystemRepresentation, &sourceStat) == 0 &&
        stat(destination.fileSystemRepresentation, &destinationStat) == 0 &&
        sourceStat.st_dev == destinationStat.st_dev && sourceStat.st_ino == destinationStat.st_ino;
    if ([sourcePath isEqualToString:destinationPath] || sameFile)
        return Failure(@"Choose a different name or folder. Save As keeps the original image unchanged.", error);
    NSString* temporary = [destination.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".szpdf-image-%@.pdf", NSUUID.UUID.UUIDString]];
    BOOL success = NO;
    if (asPDF) {
        char message[1024] = {};
        spdf_document* document = spdf_open(sourcePath.fileSystemRepresentation, message, sizeof(message));
        if (document) {
            success = spdf_document_export_pdf(document, temporary.fileSystemRepresentation, -1, message, sizeof(message));
            spdf_close(document);
        }
        if (!success) Failure(message[0] ? @(message) : @"Could not render the image as PDF.", error);
    } else {
        success = [NSFileManager.defaultManager copyItemAtPath:sourcePath toPath:temporary error:error];
    }
    if (success) success = [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600}
        ofItemAtPath:temporary error:error];
    if (success && (SPDFMacPathIsCollectionArchive(destination) ||
        ![SPDFImageSaveDestinationIdentity(destination) isEqual:expected]))
        success = Failure(@"The destination changed while saving. Use Save As again to review the current file.", error);
    if (success) {
        // A newly appeared file must never be overwritten without confirmation.
        // Existing destinations are rechecked against the identity protected by
        // Collection immediately before installing the completed output.
        unsigned flags = [expected[@"exists"] boolValue] ? 0 : RENAME_EXCL;
        if (renameatx_np(AT_FDCWD, temporary.fileSystemRepresentation,
                         AT_FDCWD, destination.fileSystemRepresentation, flags) != 0) {
            success = NO;
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
    }
    if (!success) [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    return success;
}
