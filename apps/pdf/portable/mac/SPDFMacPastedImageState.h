#pragma once
#import "SPDFMacStateDirectory.h"

// A durable app-owned clipboard capture has no user-selected destination yet.
// Recognize only the generated names in the exact configured state directory;
// ordinary images or similarly named folders never acquire an unsaved badge.
// This check runs when a tab's path changes, never during tab drawing.
static inline BOOL SPDFPathIsUnsavedPastedImage(NSString* path) {
    NSString* parent = path.stringByDeletingLastPathComponent;
    if (![parent.lastPathComponent isEqualToString:@"Pasted Images"]) return NO;
    NSString* filename = path.lastPathComponent.stringByDeletingPathExtension;
    NSString* prefix = @"Pasted Image ";
    if (![filename hasPrefix:prefix] || ![[NSUUID alloc] initWithUUIDString:[filename substringFromIndex:prefix.length]])
        return NO;
    NSString* extension = path.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"png"] && ![extension isEqualToString:@"tiff"] && ![extension isEqualToString:@"jpg"])
        return NO;
    NSString* expected = [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Pasted Images"];
    return [parent.stringByStandardizingPath isEqualToString:expected.stringByStandardizingPath];
}
