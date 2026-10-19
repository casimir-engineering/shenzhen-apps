#import <Foundation/Foundation.h>
#import "SPDFMacCollectionPaletteModel.h"

static int failures;
static void Expect(NSString* name, BOOL success) {
    if (!success) { fprintf(stderr, "FAIL %s\n", name.UTF8String); failures++; }
}
#import "SPDFMacPaletteCacheChecks.h"

static NSArray* HeaderNames(NSArray* rows) {
    NSMutableArray* names = [NSMutableArray array];
    for (NSDictionary* row in rows) if ([row[@"kind"] isEqual:@"header"]) [names addObject:row[@"title"]];
    return names;
}
int main(void) {
    @autoreleasepool {
        CheckPaletteSearchCache();
        NSDictionary* group = @{@"id":@"g", @"name":@"Research", @"color":@"Teal",
                                @"lastUsedPath":@"/tmp/last.pdf"};
        NSDictionary* session = @{@"windows":@[
            @{@"focusedAt":@10, @"tabs":@[@{@"path":@"/tmp/old.pdf", @"title":@"Report", @"group":group}]},
            @{@"focusedAt":@20, @"tabs":@[@{@"path":@"/tmp/new.pdf", @"title":@"Report", @"group":group,
                                               @"markdownLandscape":@YES}]}]};
        NSArray* candidates = spdf_collection_palette_open_candidates(
            @[@{@"path":@"/tmp/live.pdf", @"title":@"Live"}], session);
        Expect(@"session snapshots include documents open in other processes", candidates.count == 3);
        NSArray* reports = spdf_collection_palette_open_name_rows(candidates, @"Report");
        Expect(@"equal relevance uses most recently focused window", reports.count == 2 &&
               [reports[0][@"path"] isEqual:@"/tmp/new.pdf"]);
        NSArray* assembly = @[
            @{@"title":@"/Projects/bench-pcb/Mount/01 - Original R2/Assembly guide", @"path":@"/Projects/bench-pcb/Mount/01 - Original R2/Assembly guide.pdf", @"focusedAt":@100},
            @{@"title":@"bench-stand-r4-assembly", @"path":@"/Projects/bench-stand-r4-assembly.pdf"},
            @{@"title":@"bench-stand-r2-assembly", @"path":@"/Projects/bench-stand-r2-assembly.pdf"},
            @{@"title":@"assembly R2.pdf", @"path":@"/Projects/assembly R2.pdf", @"focusedAt":@1}];
        NSArray* matches = spdf_collection_palette_open_name_rows(assembly,@"assembly R2");
        Expect(@"exact document name precedes unordered name and path matches regardless of recency",
            matches.count == 3 && [matches[0][@"path"] isEqual:assembly[3][@"path"]] &&
            [matches[1][@"path"] isEqual:assembly[2][@"path"]] && [matches[2][@"path"] isEqual:assembly[0][@"path"]]);
        Expect(@"reverse words and mixed whitespace still match path context",
            spdf_collection_palette_open_name_rows(@[assembly[0]],@"  r2\tASSEMBLY  ").count == 1);
        Expect(@"all terms are required",spdf_collection_palette_open_name_rows(assembly,@"assembly R9").count == 0);
        NSArray* recentTabs=spdf_collection_palette_open_name_rows(@[
            @{@"path":@"/a.pdf",@"title":@"A",@"lastViewedAt":@10},
            @{@"path":@"/b.pdf",@"title":@"B",@"lastViewedAt":@30},
            @{@"path":@"/c.pdf",@"title":@"C",@"lastViewedAt":@20}],@"");
        Expect(@"open documents follow last viewed, not tab position",[[recentTabs valueForKey:@"title"] isEqual:@[@"B",@"C",@"A"]]);
        NSArray* searched=spdf_collection_palette_open_name_rows(@[
            @{@"path":@"/a.pdf",@"title":@"Report",@"lastViewedAt":@10,@"_order":@0},
            @{@"path":@"/b.pdf",@"title":@"Report",@"lastViewedAt":@30,@"_order":@1}],@"Report");
        Expect(@"typing preserves previous search ranking",[searched.firstObject[@"path"] isEqual:@"/a.pdf"]);
        NSArray* groups = spdf_collection_palette_group_rows(session, @"res");
        Expect(@"persisted group activates last-used path across processes", groups.count == 1 &&
               [groups[0][@"path"] isEqual:@"/tmp/last.pdf"] && [groups[0][@"count"] integerValue] == 2);
        NSDictionary* archivedSession=@{@"windows":@[@{@"tabs":@[@{@"path":@"/collection/previews/doc/version/Notes.md",
            @"title":@"version/Notes", @"collectionVersionLabel":@"Archived · Sep 23 · Notes · Read-only"}]}]};
        NSArray* archivedRows=spdf_collection_palette_open_name_rows(spdf_collection_palette_open_candidates(@[],archivedSession),@"Notes");
        Expect(@"restored archive palette result keeps explicit identity",[archivedRows.firstObject[@"title"] isEqual:@"Archived · Sep 23 · Notes · Read-only"]);
        NSMutableArray *openText=[NSMutableArray array], *names=[NSMutableArray array], *text=[NSMutableArray array];
        for (NSInteger i=0; i<7; i++) {
            NSString* title = [NSString stringWithFormat:@"%ld", (long)i];
            [openText addObject:@{@"kind":@"openText", @"title":title}];
            [names addObject:@{@"kind":@"collectionDocument", @"title":title}];
            [text addObject:@{@"kind":@"collectionDocument", @"title":title}];
        }
        NSArray* rows = spdf_collection_palette_rows(NO, @"report", reports, groups, openText, names, text, YES);
        Expect(@"normal scope has exact documented section order", [HeaderNames(rows) isEqual:@[
            @"Open documents", @"Tab groups", @"Text in open documents",
            @"Collection documents", @"Text in Collection"]]);
        NSUInteger capped = 0;
        for (NSDictionary* row in rows) if ([[row[@"title"] description] isEqual:@"4"]) capped++;
        Expect(@"all three text and collection sections stop at five", capped == 3 &&
               ![[rows valueForKey:@"kind"] containsObject:@"collectionShowAll"]);
        NSArray* scoped = spdf_collection_palette_rows(YES, @"invoice", reports, groups, openText, names, text, YES);
        Expect(@"col scope contains only Collection sections", [HeaderNames(scoped) isEqual:@[
            @"Collection documents", @"Text in Collection"]]);
        NSDictionary* showAll = scoped.lastObject;
        Expect(@"col show-all carries the entered query", [showAll[@"kind"] isEqual:@"collectionShowAll"] &&
               [showAll[@"query"] isEqual:@"invoice"]);
        NSDictionary* parsed = spdf_collection_palette_query(@"  COL:  résumé  ");
        Expect(@"col parsing is case insensitive and trims query", [parsed[@"collectionOnly"] boolValue] &&
               [parsed[@"query"] isEqual:@"résumé"]);
        Expect(@"palette snippets are one line with stable spacing",
               [spdf_collection_palette_single_line(@"first\n\tsecond   third") isEqual:@"first second third"]);
        NSSet* paths = spdf_collection_palette_open_paths(candidates);
        Expect(@"open exclusion set is standardized and complete", paths.count == 3 &&
               [paths containsObject:@"/tmp/new.pdf"]);
    }
    if (!failures) printf("SPDFMacCollectionPaletteTests passed\n");
    return failures ? 1 : 0;
}
