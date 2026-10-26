#import "SPDFMacAIChatSessionGrants.h"

#import "SPDFMacAIChatGrants.h"
#import "SPDFMacAIChatSessionInternal.h"
#import "SPDFMacAIRequestContext.h"

static const NSUInteger kSPDFMaxGrants = 32, kSPDFMaxSaved = 256;
static NSString* const kSPDFSavedPrefix = @"attachment:saved-";

BOOL SPDFMacAIChatGrantIsSaved(NSString* identifier) {
    return [identifier isKindOfClass:NSString.class] && [identifier hasPrefix:kSPDFSavedPrefix];
}

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
        NSUInteger given = [grants filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* g,
            NSDictionary* bindings) { (void)bindings; return ![g[@"saved"] boolValue]; }]].count;
        if (given >= kSPDFMaxGrants) {
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

- (NSString*)addSavedFileAtPath:(NSString*)path {
    NSDictionary* made = path.length ? SPDFMacAIChatGrantForURL([NSURL fileURLWithPath:path], nil) : nil;
    if (![made[@"kind"] isEqual:@"file"]) return nil;
    NSMutableArray* grants = [self.grants mutableCopy];
    for (NSDictionary* grant in grants)
        if ([grant[@"saved"] boolValue] && [SPDFMacAIChatGrantResolvedPath(grant) isEqual:made[@"path"]]) return grant[@"id"];
    NSMutableDictionary* grant = [made mutableCopy];
    grant[@"id"] = [kSPDFSavedPrefix stringByAppendingString:[made[@"id"] substringFromIndex:@"attachment:".length]];
    grant[@"saved"] = @YES;
    NSUInteger saved = 0;
    for (NSDictionary* item in grants) saved += [item[@"saved"] boolValue];
    if (saved >= kSPDFMaxSaved) // the oldest saved file goes first; what the person gave stays
        for (NSUInteger index = 0; index < grants.count; index++)
            if ([grants[index][@"saved"] boolValue]) { [grants removeObjectAtIndex:index]; break; }
    [grants addObject:grant];
    [self saveGrants:grants];
    return grant[@"id"];
}

- (NSArray<SPDFMacAIRequestChip*>*)savedFileChips {
    return SPDFMacAIChatGrantChips([self.grants filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary* grant, NSDictionary* bindings) { (void)bindings; return [grant[@"saved"] boolValue]; }]]);
}

@end

NSArray<SPDFMacAIRequestChip*>* SPDFMacAIRequestReadableAttachments(SPDFMacAIRequestContext* context) {
    NSMutableArray* chips = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    NSArray* saved = context.depth ? @[] : context.session.savedFileChips ?: @[];
    for (SPDFMacAIRequestChip* chip in [[context chipsOfKind:SPDFMacAIChipKindAttachment] arrayByAddingObjectsFromArray:saved])
        if (chip.identifier.length && ![seen containsObject:chip.identifier]) {
            [seen addObject:chip.identifier];
            [chips addObject:chip];
        }
    return chips;
}
