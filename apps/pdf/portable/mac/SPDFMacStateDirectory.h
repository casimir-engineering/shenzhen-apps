#pragma once
#import <Foundation/Foundation.h>

// Path calculation only. Call spdf_mac_support_directory() when actually
// reading/writing state: that existing API also creates the directory.
static inline NSString* SPDFMacStateDirectoryPath(void) {
    static NSString* directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char* override = getenv("SPDF_STATE_DIR");
        if (override && override[0]) {
            directory = [[NSFileManager.defaultManager stringWithFileSystemRepresentation:override
                length:strlen(override)] copy];
        } else {
            NSURL* base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                inDomains:NSUserDomainMask].firstObject;
            directory = [[base.path stringByAppendingPathComponent:@"ShenzhenPDF"] copy];
        }
    });
    return directory;
}
