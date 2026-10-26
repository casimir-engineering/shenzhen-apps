#import "SPDFMacAIChatSessionGrants.h"

#import "SPDFMacAIChatGrants.h"
#import "SPDFMacAIChatSessionInternal.h"

static const NSUInteger kSPDFMaxGrants = 32;

@implementation SPDFMacAIChatSession (Grants)

- (NSArray<NSDictionary*>*)grants {
    id grants = _mutableChat[@"grants"];
    return [grants isKindOfClass:NSArray.class] ? grants : @[];
}

// A chat already on disk is saved at once, so the grant is there when it is reopened; a new chat keeps it until its
// first message saves the chat.
- (void)saveGrants:(NSArray*)grants {
    if (grants.count) _mutableChat[@"grants"] = [grants copy];
    else [_mutableChat removeObjectForKey:@"grants"];
    if (_messages.count) [self persist];
    [self notify];
}

- (NSArray<NSString*>*)addGrantsForURLs:(NSArray<NSURL*>*)URLs {
    NSMutableArray* grants = [self.grants mutableCopy], *problems = [NSMutableArray array];
    NSMutableSet* paths = [NSMutableSet set];
    for (NSDictionary* grant in grants) {
        NSString* path = SPDFMacAIChatGrantResolvedPath(grant);
        if (path) [paths addObject:path];
    }
    BOOL changed = NO;
    for (NSURL* URL in URLs) {
        NSString* reason = nil;
        NSDictionary* grant = SPDFMacAIChatGrantForURL(URL, &reason);
        if (!grant) { [problems addObject:[NSString stringWithFormat:@"%@: %@", URL.lastPathComponent, reason]]; continue; }
        if ([paths containsObject:grant[@"path"]]) continue;
        if (grants.count >= kSPDFMaxGrants) {
            [problems addObject:[NSString stringWithFormat:@"%@: A chat can hold 32 files and folders. Remove one "
                                                           @"first.", URL.lastPathComponent]];
            continue;
        }
        [grants addObject:grant];
        [paths addObject:grant[@"path"]];
        changed = YES;
    }
    if (changed) [self saveGrants:grants];
    return problems;
}

- (void)removeGrantWithIdentifier:(NSString*)identifier {
    NSMutableArray* grants = [self.grants mutableCopy];
    NSUInteger before = grants.count;
    [grants filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* grant, NSDictionary* bindings) {
        (void)bindings;
        return ![grant[@"id"] isEqual:identifier];
    }]];
    if (grants.count != before) [self saveGrants:grants];
}

- (NSArray<SPDFMacAIRequestChip*>*)grantChips { return SPDFMacAIChatGrantChips(self.grants); }

@end
