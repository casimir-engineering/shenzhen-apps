#import "SPDFMacAIOutputFiles.h"
#import "SPDFMacAILanguage.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <limits.h>
#include <stdlib.h>

static NSString* gDownloadsOverride;

void SPDFMacAISetDownloadsDirectoryForTesting(NSString* directory) {
    @synchronized (NSFileManager.class) { gDownloadsOverride = [directory copy]; }
}

NSString* SPDFMacAIDownloadsDirectory(void) {
    @synchronized (NSFileManager.class) { if (gDownloadsOverride.length) return gDownloadsOverride; }
    const char* state = getenv("SPDF_STATE_DIR");
    if (state && state[0])
        return [[NSFileManager.defaultManager stringWithFileSystemRepresentation:state length:strlen(state)]
            stringByAppendingPathComponent:@"Downloads"];
    NSURL* downloads = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    return downloads.path ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
}

static id Fail(NSError** error, NSString* message) {
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.AI.Output" code:1
                                        userInfo:@{NSLocalizedDescriptionKey : message}];
    return nil;
}

static NSString* RealPath(NSString* path) {
    char resolved[PATH_MAX];
    return path.length && realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : nil;
}

NSString* SPDFMacAIDownloadsSubfolder(NSString* relative, NSString** problem) {
    NSString* why = nil;
    NSString* base = SPDFMacAIDownloadsDirectory();
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* root = RealPath(base), *current = root;
    NSArray* parts = [relative isKindOfClass:NSString.class] && relative.length ?
        [relative componentsSeparatedByString:@"/"] : @[];
    if (!root) why = @"The Downloads folder is not available.";
    else if ([relative hasPrefix:@"/"] || [relative hasPrefix:@"~"] || parts.count > 4)
        why = @"folder must be a path inside Downloads, such as \"Reports/October\", at most 4 levels.";
    for (NSString* part in why ? @[] : parts) {
        if (!part.length || [part hasPrefix:@"."] || [part containsString:@":"] || [part containsString:@"\\"] ||
            part.length > 80 || [part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            why = @"Each part of folder must be a plain name: no \"..\", no leading dot, no colon.";
            break;
        }
        current = [current stringByAppendingPathComponent:part];
        struct stat info;
        if (lstat(current.fileSystemRepresentation, &info) == 0) {
            if (!S_ISDIR(info.st_mode)) { why = @"A file or link of that name is already in the way."; break; }
        } else if (mkdir(current.fileSystemRepresentation, 0755) != 0 && errno != EEXIST) {
            why = [NSString stringWithFormat:@"The folder could not be made: %s.", strerror(errno)];
            break;
        }
    }
    NSString* real = why ? nil : RealPath(current);
    if (!why && (!real || !([real isEqual:root] || [real hasPrefix:[root stringByAppendingString:@"/"]])))
        why = @"folder must stay inside Downloads.";
    if (problem) *problem = why;
    return why ? nil : real;
}

NSString* SPDFMacAIOutputNumberedName(NSString* name, NSUInteger n) {
    if (n <= 1) return name;
    NSString* extension = name.pathExtension;
    NSString* base = extension.length ? name.stringByDeletingPathExtension : name;
    NSString* numbered = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n];
    return extension.length ? [numbered stringByAppendingPathExtension:extension] : numbered;
}

NSString* SPDFMacAIOutputFileName(NSString* text, NSString* fallback, NSString* extension) {
    NSString* name = [text isKindOfClass:NSString.class] ? text : @"";
    if ([name.pathExtension.lowercaseString isEqual:extension.lowercaseString])
        name = name.stringByDeletingPathExtension;
    NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@"/:\\"];
    name = [[name componentsSeparatedByCharactersInSet:separators] componentsJoinedByString:@"-"];
    name = [[name componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet]
        componentsJoinedByString:@""];
    NSCharacterSet* trimmed = [NSCharacterSet characterSetWithCharactersInString:@". \t"];
    name = [name stringByTrimmingCharactersInSet:trimmed];
    if (name.length > 80)
        name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 80)]];
    name = [name stringByTrimmingCharactersInSet:trimmed];
    return [(name.length ? name : fallback) stringByAppendingPathExtension:extension];
}

NSString* SPDFMacAIJobOutputName(NSString* source, NSString* kind, NSString* targetLanguage) {
    NSString* base = source.lastPathComponent.stringByDeletingPathExtension;
    NSString* label = nil;
    if ([kind isEqual:@"ocr"]) label = @"OCR";
    else if ([kind isEqual:@"translate"]) {
        // "fr" or "French" is "French"; a language not in the list keeps the name it was given ("Breton").
        NSDictionary* names = SPDFMacAILanguageNames();
        label = [targetLanguage stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for (NSString* code in names)
            if ([code caseInsensitiveCompare:label ?: @""] == NSOrderedSame ||
                [names[code] caseInsensitiveCompare:label ?: @""] == NSOrderedSame) label = names[code];
    } else if ([source.pathExtension.lowercaseString isEqual:@"pdf"]) label = @"copy";
    NSString* name = label.length ? [NSString stringWithFormat:@"%@ (%@)", base, label] : base;
    return SPDFMacAIOutputFileName(name, @"Document", @"pdf");
}

NSDictionary* SPDFMacAIOutputIdentity(NSString* path) {
    struct stat before = {}, after = {};
    if (!path.length || lstat(path.fileSystemRepresentation, &before) || !S_ISREG(before.st_mode)) return nil;
    NSInputStream* stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    uint8_t buffer[65536];
    NSInteger count = 0;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
    [stream close];
    // A file written while it was hashed is not the one the hash describes.
    if (count < 0 || lstat(path.fileSystemRepresentation, &after) || before.st_ino != after.st_ino ||
        before.st_dev != after.st_dev || before.st_size != after.st_size ||
        before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
        before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    return @{@"device" : @(after.st_dev), @"inode" : @(after.st_ino), @"size" : @(after.st_size),
             @"modified" : @(after.st_mtimespec.tv_sec), @"modifiedNS" : @(after.st_mtimespec.tv_nsec),
             @"hash" : [NSData dataWithBytes:digest length:sizeof(digest)]};
}

BOOL SPDFMacAIOutputIsCurrent(NSDictionary* receipt) {
    if (![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"path"] isKindOfClass:NSString.class]) return NO;
    return receipt[@"identity"] && [receipt[@"identity"] isEqual:SPDFMacAIOutputIdentity(receipt[@"path"])];
}

BOOL SPDFMacAIOutputRemove(NSDictionary* receipt) {
    if (!SPDFMacAIOutputIsCurrent(receipt)) return NO;
    return [NSFileManager.defaultManager removeItemAtPath:receipt[@"path"] error:nil];
}

NSDictionary* SPDFMacAIOutputInstallFile(NSString* staged, NSString* directory, NSString* name, NSError** error) {
    if (!name.length || ![name isEqual:name.lastPathComponent] || [name hasPrefix:@"."])
        return Fail(error, @"Choose a file name without folder separators.");
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSString* source = staged, *copied = nil;
    NSDictionary* receipt = nil;
    for (NSUInteger n = 1; n <= 999 && !receipt; n++) {
        NSString* destination = [directory stringByAppendingPathComponent:SPDFMacAIOutputNumberedName(name, n)];
        // RENAME_EXCL fails on any existing entry, file, folder or link, so nothing is replaced, even by a race.
        if (!renameatx_np(AT_FDCWD, source.fileSystemRepresentation, AT_FDCWD, destination.fileSystemRepresentation,
                          RENAME_EXCL)) {
            NSDictionary* identity = SPDFMacAIOutputIdentity(destination);
            if (!identity) {
                [fm removeItemAtPath:destination error:nil];
                return Fail(error, @"The file could not be saved. Try again.");
            }
            receipt = @{@"path" : destination, @"identity" : identity};
        } else if (errno == EXDEV && !copied) {
            copied = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@".shenzhenpdf-%@", NSUUID.UUID.UUIDString]];
            if (![fm copyItemAtPath:staged toPath:copied error:error]) {
                [fm removeItemAtPath:copied error:nil];
                return nil;
            }
            source = copied;
            n--;
        } else if (errno != EEXIST) {
            if (copied) [fm removeItemAtPath:copied error:nil];
            return Fail(error, [NSString stringWithFormat:@"The file could not be saved in %@: %s.",
                                directory.lastPathComponent, strerror(errno)]);
        }
    }
    if (!receipt) {
        if (copied) [fm removeItemAtPath:copied error:nil];
        return Fail(error, @"Too many files already have this name. Choose another name.");
    }
    if (copied) [fm removeItemAtPath:staged error:nil];
    return receipt;
}

NSDictionary* SPDFMacAIOutputWriteData(NSData* data, NSString* directory, NSString* name, NSError** error) {
    NSString* scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ShenzhenPDF-output-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:scratch withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions : @0700} error:error]) return nil;
    NSString* staged = [scratch stringByAppendingPathComponent:@"output"];
    NSDictionary* receipt = nil;
    if ([data writeToFile:staged options:NSDataWritingWithoutOverwriting error:error]) {
        chmod(staged.fileSystemRepresentation, 0644);
        receipt = SPDFMacAIOutputInstallFile(staged, directory, name, error);
    }
    [fm removeItemAtPath:scratch error:nil];
    return receipt;
}
