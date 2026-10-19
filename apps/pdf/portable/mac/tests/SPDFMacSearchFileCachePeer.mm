#import "SPDFMacSearchFileCache.h"

id SPDFSearchFileCachePeerRead(NSString* path, id (^load)(void)) {
    return SPDFSearchCachedFile(path,@"cross-tu",128,load);
}
NSCache* SPDFSearchFileCachePeerIdentity(void) { return SPDFSharedSearchFileCache(); }
