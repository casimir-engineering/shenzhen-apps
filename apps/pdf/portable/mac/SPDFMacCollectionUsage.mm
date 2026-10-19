#import "SPDFMacCollectionUsage.h"
@implementation SPDFCollectionOpenIntents {
    NSMutableDictionary<NSString*,NSNumber*>* _paths;
}
- (void)requestPaths:(NSArray<NSString*>*)paths {
    if (!_paths) _paths = [NSMutableDictionary dictionary];
    NSMutableSet* unique = [NSMutableSet set];
    for (id path in paths) if ([path isKindOfClass:NSString.class] && [path length])
        [unique addObject:[path stringByStandardizingPath]];
    for (NSString* path in unique) _paths[path] = @([_paths[path] unsignedIntegerValue]+1);
}
- (NSUInteger)consumePath:(NSString*)path {
    NSString* key = path.stringByStandardizingPath;
    if (!key) return 0;
    NSUInteger count = [_paths[key] unsignedIntegerValue];
    [_paths removeObjectForKey:key]; return count;
}
@end
