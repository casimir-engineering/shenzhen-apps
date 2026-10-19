#pragma once
#import <Foundation/Foundation.h>

// Rename within the existing directory and retain the document format.
static inline NSString* SPDFDocumentRenameDestination(NSString* path, NSString* proposed) {
    NSString* name=[proposed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name isEqual:@"."] || [name isEqual:@".."] ||
        [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\n\r"]].location!=NSNotFound)
        return nil;
    NSString* extension=path.pathExtension;
    if (extension.length && [name.pathExtension caseInsensitiveCompare:extension]!=NSOrderedSame)
        name=[name stringByAppendingPathExtension:extension];
    return [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
}
static inline BOOL SPDFRenameDocumentFile(NSString* source, NSString* destination, NSError** error) {
    if ([source isEqual:destination]) return YES;
    // moveItem refuses replacement: an existing document is never overwritten.
    return [NSFileManager.defaultManager moveItemAtPath:source toPath:destination error:error];
}
