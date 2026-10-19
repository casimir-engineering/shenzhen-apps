#pragma once

#import <Foundation/Foundation.h>

// Kept dynamically linked so focused reader/editor tests do not instantiate or
// link the Collection store. In the app this calls defaultStore/isArchivePath:
// exactly; absent Collection code means an ordinary source path.
@protocol SPDFMacCollectionArchiveChecking <NSObject>
+ (id<SPDFMacCollectionArchiveChecking>)defaultStore;
- (BOOL)isArchivePath:(NSString*)path;
@end

static inline BOOL SPDFMacPathIsCollectionArchive(NSString* path) {
    Class storeClass = NSClassFromString(@"SPDFMacCollectionStore");
    if (!storeClass || ![storeClass respondsToSelector:@selector(defaultStore)]) return NO;
    id<SPDFMacCollectionArchiveChecking> store =
        [(id<SPDFMacCollectionArchiveChecking>)storeClass defaultStore];
    return path.length && [store respondsToSelector:@selector(isArchivePath:)] && [store isArchivePath:path];
}
