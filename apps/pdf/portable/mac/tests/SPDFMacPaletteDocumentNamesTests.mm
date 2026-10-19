#import <Foundation/Foundation.h>
#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacPaletteDocumentNames.h"
#import "SPDFMacPaletteResults.h"
#import "SPDFMacSupport.h"

// How Cmd+K rows are named, located, merged and moved through. Pure: no window,
// no file is read.
static int failures;
static void Expect(NSString* name, BOOL success) {
    if (!success) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); failures++; }
}

static NSString* const kHome = @"/Users/reader";
static NSString* const kSupport = @"/Users/reader/Library/Application Support/ShenzhenPDF";
static NSString* const kCopy = @"/Users/reader/Library/Application Support/ShenzhenPDF/Collection/editable/"
                               @"4F17B704-EDC7-4310-8DDF-6CD981B30371/C7E545D3-C2AE-4554-9745-F3A63A73F995/"
                               @"Sample_Before_vs_After_4_Images.pdf";
static NSString* const kOriginal =
    @"/Users/reader/Projects/Site_Survey/output/pdf/Sample_Before_vs_After_4_Images.pdf";
static NSString* const kDocumentID = @"4F17B704-EDC7-4310-8DDF-6CD981B30371";

static void CheckTitles(void) {
    Expect(@"a Collection working copy is titled by its document name, never by its folder path",
           [spdf_palette_document_title(kCopy, nil, nil) isEqualToString:@"Sample_Before_vs_After_4_Images"]);
    Expect(@"hash and id file names are recognised",
           spdf_palette_name_is_opaque(@"dc1b3a737e85d8e2fb6486cbbd108a8b.pdf") &&
           spdf_palette_name_is_opaque(@"2f6fa8b5ebba154de171778d8d99b38f") &&
           spdf_palette_name_is_opaque(@"DT100000001_1700000000000.PDF") &&
           spdf_palette_name_is_opaque(@"C7E545D3-C2AE-4554-9745-F3A63A73F995.pdf"));
    for (NSString* name in @[@"Sample50-4B_DS_2.0_A.pdf", @"Motor-SPEC-0A.pdf",
                             @"Controller-QFN.pdf", @"receiver-pin6.pdf",
                             @"Bracket-V1.0 结构图-2D 20260916.pdf", @"summary.md"])
        Expect([@"a person's file name is not opaque: " stringByAppendingString:name],
               !spdf_palette_name_is_opaque(name));
    Expect(@"an opaque file name gives way to the document's own title",
           [spdf_palette_document_title(@"/tmp/2f6fa8b5ebba154de171778d8d99b38f.pdf", nil, @"  Motor   torque curves ")
               isEqualToString:@"Motor torque curves"]);
    Expect(@"a readable file name is kept even when the document has a title",
           [spdf_palette_document_title(@"/d/summary.pdf", nil, @"Microsoft Word - draft") isEqualToString:@"summary"]);
    Expect(@"an empty or placeholder document title does not replace the file name",
           [spdf_palette_document_title(@"/d/2f6fa8b5ebba154de171778d8d99b38f.pdf", nil, @"untitled")
               isEqualToString:@"2f6fa8b5ebba154de171778d8d99b38f"]);
    Expect(@"a saved version keeps its own label",
           [spdf_palette_document_title(kCopy, @"Archived · Sep 23 · Notes", @"x")
               isEqualToString:@"Archived · Sep 23 · Notes"]);
    Expect(@"only document extensions are dropped",
           [spdf_palette_file_display_name(@"/d/Report v2.0") isEqualToString:@"Report v2.0"] &&
           [spdf_palette_file_display_name(@"/d/Sample50-4B_DS_2.0_A.pdf")
               isEqualToString:@"Sample50-4B_DS_2.0_A"]);
}

static void CheckLocations(void) {
    NSDictionary* expected = @{
        kCopy : @"Collection",
        kOriginal : @"Site_Survey",
        @"/Users/reader/Downloads/Sample40_DS_1.02.pdf" : @"Downloads",
        @"/Users/reader/Library/Containers/com.apple.Safari/Data/tmp/WebKitPDFs-Itpu6J/2f6f.pdf" : @"Safari",
        @"/Users/reader/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/95C6/DT1.PDF" : @"Mail",
        @"/Users/reader/Library/Containers/com.tencent.xinWeChat/Data/Documents/msg/file/2026-10/S.pdf" : @"WeChat",
        @"/Users/reader/Library/Application Support/ShenzhenPDF/Pasted Images/Pasted Image 1.png" : @"Pasted images",
        @"/Users/reader/notes.md" : @"Home",
        @"/private/var/folders/zw/abc/T/report.pdf" : @"Temporary folder",
        @"/Users/reader/Projects/survey/artifacts/sample-rig/exports/Cover.pdf" : @"sample-rig",
    };
    for (NSString* path in expected) {
        NSString* label = spdf_palette_location_label(path, kHome, kSupport);
        Expect([NSString stringWithFormat:@"%@ lives in %@ (got %@)", path.lastPathComponent, expected[path], label],
               [label isEqualToString:expected[path]]);
    }
}

static void CheckMerging(void) {
    NSArray* candidates = @[
        @{@"path" : kCopy, @"title" : @"Sample_Before_vs_After_4_Images", @"lastViewedAt" : @50, @"_live" : @YES},
        @{@"path" : @"/Users/reader/Downloads/a.pdf", @"title" : @"a", @"_live" : @YES},
        @{@"path" : kOriginal, @"title" : @"Sample_Before_vs_After_4_Images", @"lastViewedAt" : @10, @"_live" : @YES},
    ];
    NSDictionary* originals = @{@"4F17B704-EDC7-4310-8DDF-6CD981B30371" : kOriginal};
    NSArray* merged = spdf_palette_merge_collection_copies(candidates, originals);
    Expect(@"a Collection working copy and its open original are one row", merged.count == 2);
    NSDictionary* document = merged.firstObject;
    Expect(@"the merged row opens the original and keeps the later viewing time",
           [document[@"path"] isEqualToString:kOriginal] && [document[@"lastViewedAt"] isEqual:@50] &&
           [document[@"mergedPaths"] containsObject:kCopy]);
    NSSet* open = spdf_collection_palette_open_paths(merged);
    Expect(@"both files count as open, so the Collection section does not list the document again",
           [open containsObject:kCopy] && [open containsObject:kOriginal]);
    NSArray* byHistory = spdf_palette_merge_collection_copies(@[
        @{@"path" : kOriginal, @"collectionHistoryID" : @"4F17B704-EDC7-4310-8DDF-6CD981B30371"},
        @{@"path" : kCopy}], @{});
    Expect(@"a tab that knows its Collection document merges without reading the Collection",
           byHistory.count == 1 && [byHistory[0][@"path"] isEqualToString:kOriginal]);
    NSArray* alone = spdf_palette_merge_collection_copies(@[@{@"path" : kCopy}], originals);
    Expect(@"a working copy whose original is closed stays, and hides that original from the Collection section",
           alone.count == 1 && [spdf_collection_palette_open_paths(alone) containsObject:kOriginal]);
    // While a document is still loading its tab does not know its Collection
    // document yet; the working copy's tab knows where the original is.
    NSDictionary* liveWindow = @{@"tabs" : @[@{@"path" : kOriginal}, @{@"path" : kCopy}]};
    NSArray* loading = spdf_palette_merge_collection_copies(spdf_collection_palette_open_candidates(@[
        @{@"path" : kOriginal, @"title" : @"Sample_Before_vs_After_4_Images"},
        @{@"path" : kCopy, @"title" : @"Sample_Before_vs_After_4_Images", @"collectionHistoryID" : kDocumentID,
          @"originalPath" : kOriginal}], @{@"windows" : @[liveWindow]}), @{});
    Expect(@"an original still loading folds with its open working copy without reading the Collection",
           loading.count == 1 && [loading[0][@"path"] isEqualToString:kOriginal] &&
               [loading[0][@"mergedPaths"] isEqual:@[kCopy]]);
    NSArray* versions = spdf_palette_merge_collection_copies(@[
        @{@"path" : kOriginal, @"collectionHistoryID" : @"4F17B704-EDC7-4310-8DDF-6CD981B30371"},
        @{@"path" : @"/c/previews/doc/v/Sample.pdf", @"collectionHistoryID" : @"4F17B704-EDC7-4310-8DDF-6CD981B30371",
          @"collectionVersionLabel" : @"Archived · Sep 23"}], originals);
    Expect(@"a saved version shown under its own label stays its own row", versions.count == 2);
}

static void CheckRows(void) {
    NSArray* candidates = spdf_collection_palette_open_candidates(@[
        @{@"path" : @"/d/front.pdf", @"title" : @"front", @"_current" : @YES, @"lastViewedAt" : @99},
        @{@"path" : @"/d/back.pdf", @"title" : @"back", @"lastViewedAt" : @5}], @{});
    NSArray* browse = spdf_collection_palette_open_name_rows(candidates, @"");
    Expect(@"with nothing typed, the document in front is not offered as somewhere to switch to",
           browse.count == 1 && [browse[0][@"title"] isEqualToString:@"back"]);
    Expect(@"typing its name still finds the document in front",
           spdf_collection_palette_open_name_rows(candidates, @"front").count == 1);
    NSDictionary* session = @{@"windows" : @[@{@"tabs" : @[@{@"path" : @"/d/x/Spec.pdf", @"title" : @"/d/x/Spec"}]}]};
    NSArray* restored = spdf_collection_palette_open_candidates(@[], session);
    Expect(@"a saved window's title that is a path is replaced by the file name",
           [restored.firstObject[@"title"] isEqualToString:@"Spec"]);
    NSArray* slash = spdf_collection_palette_open_name_rows(@[
        @{@"path" : @"/d/A/B testing/plan.pdf", @"title" : @"plan", @"_order" : @0},
        @{@"path" : @"/d/ab.pdf", @"title" : @"A/B testing", @"_order" : @1}], @"A/B testing");
    Expect(@"a title with a slash is matched whole, ahead of a folder-name match",
           slash.count == 2 && [slash[0][@"title"] isEqualToString:@"A/B testing"]);
    NSArray* openText = @[@{@"kind" : @"collectionOpenText", @"path" : @"/d/back.pdf", @"page" : @2,
                            @"title" : @"back · page 3"}];
    NSArray* savedText = @[@{@"kind" : @"collectionDocument", @"path" : @"/d/back.pdf", @"page" : @2,
                             @"title" : @"back · page 3"},
                           @{@"kind" : @"collectionDocument", @"path" : @"/d/other.pdf", @"page" : @0,
                             @"title" : @"other"}];
    NSArray* rows = spdf_collection_palette_rows(NO, @"torque", @[], @[], openText, @[], savedText, NO);
    NSUInteger pages = 0;
    for (NSDictionary* row in rows) if ([row[@"title"] isEqual:@"back · page 3"]) pages++;
    Expect(@"a page found in an open document is not listed again from the Collection", pages == 1 && rows.count == 4);
    NSDictionary* chat = spdf_collection_palette_chat_row(@"");
    NSDictionary* ask = spdf_collection_palette_chat_row(@" torque\n curve ");
    Expect(@"the chat row says what it does and shows its shortcut",
           [chat[@"title"] isEqualToString:@"Chat with your documents"] &&
               [chat[@"shortcut"] isEqualToString:@"⌘↩"] &&
           [ask[@"title"] containsString:@"torque"] && [chat[@"kind"] isEqualToString:@"askAI"]);
}

static void CheckCollectionTitles(void) {
    NSString* hashed = @"/Users/reader/Downloads/dc1b3a737e85d8e2fb6486cbbd108a8b.pdf";
    NSDictionary* manifest = @{@"documents" : @{
        kDocumentID : @{@"path" : hashed, @"title" : @"Motor torque curves.pdf"},
        @"E1A3C0DE-0000-4000-8000-000000000001" : @{@"path" : @"/d/DT100000001_1700000000000.PDF",
                                                     @"title" : @"DT100000001_1700000000000.PDF"}}};
    NSDictionary* titles = spdf_palette_collection_titles(manifest);
    NSArray* rows = spdf_palette_titled_from_collection(@[
        @{@"path" : hashed, @"title" : @"dc1b3a737e85d8e2fb6486cbbd108a8b"},
        @{@"path" : @"/d/DT100000001_1700000000000.PDF", @"title" : @"DT100000001_1700000000000"},
        @{@"path" : @"/d/f00dfeed00112233445566778899aabb.pdf", @"title" : @"f00dfeed00112233445566778899aabb",
          @"collectionHistoryID" : kDocumentID},
        @{@"path" : hashed, @"title" : @"Spec sheet"}],
        spdf_palette_collection_original_paths(manifest), titles);
    Expect(@"a hash-named document takes the name the Collection keeps for it",
           [rows[0][@"title"] isEqualToString:@"Motor torque curves"]);
    Expect(@"a stored name that is itself an id changes nothing",
           [rows[1][@"title"] isEqualToString:@"DT100000001_1700000000000"]);
    Expect(@"another window's saved tab is named through its Collection document",
           [rows[2][@"title"] isEqualToString:@"Motor torque curves"]);
    Expect(@"a document's own readable title is kept", [rows[3][@"title"] isEqualToString:@"Spec sheet"]);
}

static void CheckHighlightAfterResults(void) {
    NSDictionary* chat = spdf_collection_palette_chat_row(@"sampl");
    NSDictionary* copyRow = @{@"kind" : @"openDoc", @"title" : @"Sample", @"path" : kCopy};
    NSArray* first = @[@{@"kind" : @"header", @"title" : @"Open documents"}, copyRow,
                       @{@"kind" : @"openDoc", @"title" : @"Sample", @"path" : kOriginal}, chat];
    NSArray* later = @[@{@"kind" : @"header", @"title" : @"Open documents"},
                       @{@"kind" : @"openDoc", @"title" : @"Other", @"path" : @"/d/other.pdf"},
                       @{@"kind" : @"openDoc", @"title" : @"Sample", @"path" : kOriginal, @"mergedPaths" : @[kCopy]},
                       chat];
    Expect(@"results that arrive later take the highlight to the best match unless the person moved it",
           spdf_palette_row_to_highlight(later, chat, NO) == 1 && spdf_palette_row_to_highlight(first, nil, NO) == 1);
    Expect(@"a highlight the person moved stays on its row", spdf_palette_row_to_highlight(later, chat, YES) == 3);
    Expect(@"a highlighted working copy stays highlighted once it folds into its original",
           spdf_palette_row_to_highlight(later, copyRow, YES) == 2);
    NSDictionary* renamed = @{@"kind" : @"openDoc", @"title" : @"Motor torque curves", @"path" : @"/d/other.pdf"};
    Expect(@"a row keeps the highlight when it is renamed", spdf_palette_row_to_highlight(@[renamed], @{
        @"kind" : @"openDoc", @"title" : @"dc1b3a737e85d8e2fb6486cbbd108a8b", @"path" : @"/d/other.pdf"}, YES) == 0);
    Expect(@"nothing to highlight on a status-only list",
           spdf_palette_row_to_highlight(@[@{@"kind" : @"status", @"title" : @"No matches"}], chat, YES) == -1);
}

static void CheckMovement(void) {
    NSArray* rows = @[@{@"kind" : @"askAI"}, @{@"kind" : @"header"}, @{@"kind" : @"openDoc"}, @{@"kind" : @"openDoc"},
                      @{@"kind" : @"header"}, @{@"kind" : @"menuCommand"}, @{@"kind" : @"status"}];
    Expect(@"down skips headings", spdf_palette_row_after_move(rows, 0, 1, YES) == 2);
    Expect(@"down from the last row wraps to the first", spdf_palette_row_after_move(rows, 5, 1, YES) == 0);
    Expect(@"up from the first row wraps to the last", spdf_palette_row_after_move(rows, 0, -1, YES) == 5);
    Expect(@"with nothing highlighted, down starts at the top", spdf_palette_row_after_move(rows, -1, 1, YES) == 0);
    Expect(@"a page down stops at the last row", spdf_palette_row_after_move(rows, 2, 10, NO) == 5);
    Expect(@"a page up stops at the first row", spdf_palette_row_after_move(rows, 5, -10, NO) == 0);
    Expect(@"a page lands on a row, not a heading", spdf_palette_row_after_move(rows, 0, 4, NO) == 5 &&
           spdf_palette_row_after_move(rows, 0, 1, NO) == 2);
    Expect(@"Home and End reach the first and last rows",
           spdf_palette_boundary_row(rows, NO) == 0 && spdf_palette_boundary_row(rows, YES) == 5);
    Expect(@"no rows to choose", spdf_palette_row_after_move(@[@{@"kind" : @"status"}], -1, 1, YES) == -1);
}

static void CheckTabNames(void) {
    NSArray* names = spdf_disambiguated_display_names_for_paths(@[
        @"/Users/reader/Projects/Cam/output/pdf/Sample.pdf", @"/Users/reader/Projects/Cam/output/pdf/Sample.pdf",
        @"/Users/reader/Library/Application Support/ShenzhenPDF/Collection/editable/A/B/Sample.pdf",
        @"/Users/reader/Downloads/datasheet.pdf", @"/Users/reader/Downloads/datasheet.pdf"]);
    Expect(@"the same file in two tabs does not turn same-named documents into full paths",
           ![names[0] hasPrefix:@"/"] && ![names[2] hasPrefix:@"/"] && [names[0] isEqualToString:names[1]] &&
           ![names[0] isEqualToString:names[2]]);
    Expect(@"a file open twice with no namesake keeps its plain name",
           [names[3] isEqualToString:@"datasheet"] && [names[4] isEqualToString:@"datasheet"]);
}

int main(void) {
    @autoreleasepool {
        CheckTitles();
        CheckLocations();
        CheckMerging();
        CheckRows();
        CheckCollectionTitles();
        CheckHighlightAfterResults();
        CheckMovement();
        CheckTabNames();
    }
    if (!failures) printf("SPDFMacPaletteDocumentNamesTests passed\n");
    return failures ? 1 : 0;
}
