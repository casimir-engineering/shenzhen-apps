// Per-document tab state that has to survive a session write/read cycle.
// Keep-image-colors is the case this suite exists for: it used to be one global
// preference, and the contract now is that every open document carries its own
// choice, defaulting to on.

#import <Cocoa/Cocoa.h>

#import "SPDFMacModels.h"

static int gFailures;

static void Expect(const char* what, BOOL condition) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what);
    ++gFailures;
}

static SPDFDocumentTab* TabWithPath(NSString* path) {
    SPDFDocumentTab* tab = [[SPDFDocumentTab alloc] init];
    tab.path = path;
    tab.title = path.lastPathComponent;
    return tab;
}

static NSDictionary* RoundTrip(SPDFDocumentTab* tab) {
    return spdf_dictionary_from_tab(tab, 7);
}

int main(void) {
    @autoreleasepool {
        // --- The default ------------------------------------------------
        // "Default being on" is the whole user-visible promise: a document
        // nobody has configured keeps its image colors in the dark theme.
        SPDFDocumentTab* fresh = TabWithPath(@"/tmp/fresh.pdf");
        fresh.lastViewedAt=12345;
        Expect("last-viewed order survives session restoration",spdf_tab_from_dictionary(RoundTrip(fresh)).lastViewedAt==12345);
        Expect("last-viewed timestamp survives tab copies",spdf_copy_document_tab(fresh).lastViewedAt==12345);
        Expect("a new document keeps image colors by default", fresh.preservesImageColors);

        // --- It is written, and read back --------------------------------
        NSDictionary* on = RoundTrip(fresh);
        Expect("the session records the choice", on[@"preservesImageColors"] != nil);
        Expect("the recorded choice is on", [on[@"preservesImageColors"] boolValue]);
        SPDFDocumentTab* restoredOn = spdf_tab_from_dictionary(on);
        Expect("restoring keeps it on", restoredOn != nil && restoredOn.preservesImageColors);

        fresh.collectionHistoryDocumentID = @"collection-history-example";
        SPDFDocumentTab* historyRestored = spdf_tab_from_dictionary(RoundTrip(fresh));
        Expect("history sidebar identity survives session restore", [historyRestored.collectionHistoryDocumentID isEqual:fresh.collectionHistoryDocumentID]);
        Expect("history sidebar identity survives detach", [spdf_copy_document_tab(fresh).collectionHistoryDocumentID isEqual:fresh.collectionHistoryDocumentID]);
        fresh.collectionVersionLabel = @"Archived · 23 Sep 2026 · Notes · Read-only";
        Expect("archive identity survives restore", [spdf_tab_from_dictionary(RoundTrip(fresh)).collectionVersionLabel isEqual:fresh.collectionVersionLabel]);
        Expect("archive identity survives detach", [spdf_copy_document_tab(fresh).collectionVersionLabel isEqual:fresh.collectionVersionLabel]);
        fresh.collectionVersionLabel = nil;
        fresh.collectionHistoryDocumentID = nil;
        Expect("ordinary tabs store no Collection history key", RoundTrip(fresh)[@"collectionHistoryID"] == nil);

        fresh.preservesImageColors = NO;
        SPDFDocumentTab* restoredOff = spdf_tab_from_dictionary(RoundTrip(fresh));
        Expect("restoring keeps it off", restoredOff != nil && !restoredOff.preservesImageColors);

        // --- Per document, not per app -----------------------------------
        // The defect this guards: one document's choice leaking onto another,
        // which is exactly what a single global preference did.
        SPDFDocumentTab* keeps = TabWithPath(@"/tmp/datasheet.pdf");
        SPDFDocumentTab* recolors = TabWithPath(@"/tmp/scan.pdf");
        recolors.preservesImageColors = NO;
        SPDFDocumentTab* keepsBack = spdf_tab_from_dictionary(RoundTrip(keeps));
        SPDFDocumentTab* recolorsBack = spdf_tab_from_dictionary(RoundTrip(recolors));
        Expect("two documents restore their own opposite choices",
               keepsBack.preservesImageColors && !recolorsBack.preservesImageColors);

        // --- A session written before the setting was per document --------
        // No key at all: the tab must land on the documented default so the
        // caller can seed it with the launch default instead of inheriting a
        // stale NO from a zero-initialized field.
        NSMutableDictionary* legacy = [RoundTrip(keeps) mutableCopy];
        [legacy removeObjectForKey:@"preservesImageColors"];
        SPDFDocumentTab* legacyTab = spdf_tab_from_dictionary(legacy);
        Expect("a session with no stored choice defaults to on",
               legacyTab != nil && legacyTab.preservesImageColors);

        // --- Detaching a tab into its own window carries it ---------------
        // A dragged-out tab is rebuilt from spdf_copy_document_tab; losing the
        // flag there would silently recolor the document in the new window.
        SPDFDocumentTab* copied = spdf_copy_document_tab(recolors);
        Expect("copying a tab carries its choice", copied != nil && !copied.preservesImageColors);

        // --- The neighbouring per-document flags still round-trip ---------
        keeps.markdownLandscape = YES;
        keeps.showMinimap = NO;
        SPDFDocumentTab* neighbours = spdf_tab_from_dictionary(RoundTrip(keeps));
        Expect("orientation and minimap stay per document",
               neighbours.markdownLandscape && !neighbours.showMinimap && neighbours.hasMinimapPreference);

        // --- One writer, or the round-trip above proves nothing ----------
        // The defect this guards, which the assertions above missed entirely:
        // a tab's persisted fields had TWO writers -- this shared one and a
        // second copy inlined in the session save, "kept in sync" by hand.
        // preservesImageColors was added here and to the reader, tested through
        // both, and still never reached session.yaml. Source contract, in the
        // style of SPDFMacTabLifecycleTests: the coordinator must delegate.
        NSString* testPath = @(__FILE__);
        NSString* dir = testPath.stringByDeletingLastPathComponent;
        NSError* readError = nil;
        NSString* coordinator =
            [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"../ShenzhenPDFMac.mm"]
                                      encoding:NSUTF8StringEncoding
                                         error:&readError];
        Expect("the coordinator source is readable", coordinator != nil);
        Expect("the session save uses the shared tab writer",
               [coordinator containsString:@"spdf_dictionary_from_tab(tab, _window.windowNumber)"]);
        // A field name that only a hand-rolled tab dictionary would contain.
        Expect("the coordinator no longer inlines a second tab dictionary",
               ![coordinator containsString:@"@(tab.hasScrollOrigin)"]);

        // --- Which window comes back focused -----------------------------
        // One process activates at launch, and it restores exactly one saved
        // window -- so that window is the one the reader sees focused. It has to
        // be the one they left focused, not whichever entry was written first.
        NSDictionary* older = @{@"id" : @"a", @"focusedAt" : @(1000.0)};
        NSDictionary* newer = @{@"id" : @"b", @"focusedAt" : @(2000.0)};
        Expect("the most recently focused window wins",
               spdf_session_focused_window_index(@[ older, newer ]) == 1);
        Expect("its position in the list does not matter",
               spdf_session_focused_window_index(@[ newer, older ]) == 0);
        // A session written before focusedAt existed has no times at all; it
        // must keep resolving to the first window, exactly as it used to.
        Expect("a session with no focus times restores the first window",
               spdf_session_focused_window_index(@[ @{@"id" : @"a"}, @{@"id" : @"b"} ]) == 0);
        Expect("an empty session restores nothing", spdf_session_focused_window_index(@[]) == NSNotFound);
        Expect("a malformed session restores nothing", spdf_session_focused_window_index(nil) == NSNotFound);
        Expect("a non-dictionary entry is skipped",
               spdf_session_focused_window_index(@[ @"junk", newer ]) == 1);

        // The coordinator must persist the time it reads back, or the pick above
        // always sees zeroes and silently degrades to "the first window".
        Expect("the window's session entry records when it was last focused",
               [coordinator containsString:@"currentWindow[@\"focusedAt\"] ="] &&
                   [coordinator containsString:@"focusedNow ? @(NSDate.timeIntervalSinceReferenceDate)"]);
        // ...only in the ACTIVE app. Measured: a two-window session restores as
        // two processes, and the spawned one's window becomes key inside its own
        // process, so keying alone stamped BOTH windows -- handing the focus to
        // whichever process happened to write last instead of to the window the
        // reader left in front.
        Expect("only the active app's key window is the focused one",
               [coordinator containsString:@"NSApp.isActive && self->_window.isKeyWindow"]);
        // It also has to reach disk while the window is still key: quitting from
        // another app leaves every window non-key, with nothing to stamp.
        Expect("becoming key writes the session",
               [coordinator containsString:@"if (!self->_suspendPersistentStateSaves) [self "
                                           @"writeSessionStateForCurrentWindow];"]);

        // --- Markdown page orientation belongs to the document ------------
        // A sheet turned for a wide table or a gantt chart is a property of that
        // FILE, so it has to outlive the tab: the rotate command records it
        // against the document, and a newly opened tab takes it back.
        NSString* orientation =
            [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"../SPDFMacMarkdownOrientation.mm"]
                                      encoding:NSUTF8StringEncoding
                                         error:&readError];
        Expect("the rotate command source is readable", orientation != nil);
        Expect("rotating records the orientation against the document",
               [orientation containsString:@"state[@\"markdownLandscape\"] = @(landscape);"]);
        NSString* tabViewState =
            [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"../SPDFMacTabViewState.mm"]
                                      encoding:NSUTF8StringEncoding
                                         error:&readError];
        Expect("the tab view-state source is readable", tabViewState != nil);
        Expect("a newly opened document takes back the orientation it was left on",
               [tabViewState containsString:@"tab.markdownLandscape = [state[@\"markdownLandscape\"] boolValue]"]);
        // Only when the document actually has one: an older session already
        // carries the tab's own orientation, and a missing key must not flip it
        // back to portrait.
        Expect("a document with no remembered orientation is left alone",
               [tabViewState containsString:@"if (state[@\"markdownLandscape\"] != nil)"]);
        Expect("new tabs go through that seeding",
               [coordinator containsString:@"[self seedNewTabFromDocumentMemory:tab];"]);

        // --- The detach handoff name -------------------------------------
        // Detaching a tab launches a NEW PROCESS, and the reading position is
        // handed over in a file both sides name from the document's path alone
        // -- no argument passes between them, so the two must agree exactly.
        NSString* handoff = spdf_mac_detach_handoff_name(@"/Users/someone/Reading/report.pdf");
        Expect("the handoff is a recognisable state file",
               [handoff hasPrefix:@"detach-"] && [handoff hasSuffix:@".yaml"]);
        Expect("the same path always names the same handoff",
               [handoff isEqualToString:spdf_mac_detach_handoff_name(@"/Users/someone/Reading/report.pdf")]);
        Expect("and so does a messier route to the same document",
               [handoff isEqualToString:
                            spdf_mac_detach_handoff_name(@"/Users/someone/Reading/../Reading/report.pdf")]);
        Expect("different documents never share one handoff",
               ![handoff isEqualToString:spdf_mac_detach_handoff_name(@"/Users/someone/Reading/report2.pdf")] &&
                   ![handoff isEqualToString:spdf_mac_detach_handoff_name(@"/Users/other/Reading/report.pdf")]);
        Expect("it is a bare name joined onto the state directory, never a path",
               [handoff rangeOfString:@"/"].location == NSNotFound);
        Expect("no path, no handoff", spdf_mac_detach_handoff_name(@"").length == 0);

        if (gFailures == 0) fprintf(stderr, "SPDFMacTabStateTests passed\n");
    }
    return gFailures == 0 ? 0 : 1;
}
