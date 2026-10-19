#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>
// A historical path can exist again while belonging to an unrelated document.
// Availability follows Collection identity, not just the filesystem entry.
static inline BOOL SPDFCollectionOriginalAvailable(NSDictionary* document) {
    NSString* path = document[@"path"];
    if (!path.length || [document[@"sourceReplaced"] boolValue] || [document[@"originalUnavailable"] boolValue]) return NO;
    struct stat current = {};
    if (stat(path.fileSystemRepresentation,&current) != 0 || !S_ISREG(current.st_mode)) return NO;
    NSString* expected = document[@"fileIdentity"];
    if (!expected.length) return YES;
    NSString* identity = [NSString stringWithFormat:@"%llu:%llu",
        (unsigned long long)current.st_dev,(unsigned long long)current.st_ino];
    return [identity isEqual:expected];
}
