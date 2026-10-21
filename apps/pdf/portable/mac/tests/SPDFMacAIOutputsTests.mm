// Documents the assistant makes (mac/SPDFMacAIOutputs.h): saved to Downloads under a free name, never over a file,
// kept in Collection with reason "Made by the assistant" only while Collection is on, and shown in the chat as
// "Saved to Downloads" with Open and Show in Finder. Headless: a temporary Downloads and a temporary Collection; the
// person's own are never touched, and Open and Show in Finder are recorded instead of run.
#import <Cocoa/Cocoa.h>
#import "SPDFMacAIOutputs.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacCollectionStore.h"

static int failures;
static void Check(BOOL condition, const char* message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); failures++; }
}
static NSString* Reason(SPDFMacCollectionStore* store, NSString* path) {
    NSDictionary* document = [store documentForPath:path];
    return [[store versionsForDocumentID:document[@"id"] ?: @""] lastObject][@"reason"];
}
static NSData* PNG(void) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:3
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static BOOL Spin(BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return done();
}

static void CheckNames(void) {
    Check([SPDFMacAIOutputNumberedName(@"Report.pdf", 1) isEqual:@"Report.pdf"] &&
          [SPDFMacAIOutputNumberedName(@"Report.pdf", 2) isEqual:@"Report (2).pdf"] &&
          [SPDFMacAIOutputNumberedName(@"Notes", 3) isEqual:@"Notes (3)"], "numbered names go before the extension");
    Check([SPDFMacAIOutputFileName(@"../a/b:c.png", @"Chart", @"png") isEqual:@"-a-b-c.png"] &&
          [SPDFMacAIOutputFileName(@"", @"Chart", @"png") isEqual:@"Chart.png"] &&
          [SPDFMacAIOutputFileName(@".hidden", @"Chart", @"png") isEqual:@"hidden.png"] &&
          [SPDFMacAIOutputFileName(@"sales by month", @"Chart", @"png") isEqual:@"sales by month.png"],
          "a caption becomes a plain visible file name with no folder in it");
    Check([SPDFMacAIJobOutputName(@"/x/Report.pdf", @"ocr", nil) isEqual:@"Report (OCR).pdf"] &&
          [SPDFMacAIJobOutputName(@"/x/Report.pdf", @"translate", @"fr") isEqual:@"Report (French).pdf"] &&
          [SPDFMacAIJobOutputName(@"/x/Notes.md", @"export-pdf", nil) isEqual:@"Notes.pdf"] &&
          [SPDFMacAIJobOutputName(@"/x/Report.pdf", @"export-pdf", nil) isEqual:@"Report (copy).pdf"],
          "job outputs get clear names");
}

static void CheckDownloadsFolder(NSString* root) {
    setenv("SPDF_STATE_DIR", [root stringByAppendingPathComponent:@"state"].fileSystemRepresentation, 1);
    SPDFMacAISetDownloadsDirectoryForTesting(nil);
    Check([SPDFMacAIDownloadsDirectory() isEqual:[root stringByAppendingPathComponent:@"state/Downloads"]],
          "a private state folder keeps its outputs inside itself, never in the real Downloads");
    NSString* downloads = [root stringByAppendingPathComponent:@"Downloads"];
    SPDFMacAISetDownloadsDirectoryForTesting(downloads);
    Check([SPDFMacAIDownloadsDirectory() isEqual:downloads], "tests choose the Downloads folder");
}

static void CheckNoOverwrite(NSString* downloads) {
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* existing = [downloads stringByAppendingPathComponent:@"Summary.md"];
    [@"mine" writeToFile:existing atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm createDirectoryAtPath:[downloads stringByAppendingPathComponent:@"Summary (2).md"]
  withIntermediateDirectories:NO attributes:nil error:nil];
    NSError* error = nil;
    NSDictionary* first = SPDFMacAIOutputWriteData([@"new" dataUsingEncoding:NSUTF8StringEncoding], downloads,
                                                   @"Summary.md", &error);
    Check([first[@"path"] isEqual:[downloads stringByAppendingPathComponent:@"Summary (3).md"]],
          "a taken name, even by a folder, moves on to the next free number");
    Check([[NSString stringWithContentsOfFile:existing encoding:NSUTF8StringEncoding error:nil] isEqual:@"mine"],
          "the person's file is never overwritten");
    NSDictionary* fresh = SPDFMacAIOutputWriteData([@"x" dataUsingEncoding:NSUTF8StringEncoding], downloads,
                                                   @"Fresh.md", nil);
    Check([[fresh[@"path"] lastPathComponent] isEqual:@"Fresh.md"], "a free name is used as it is");
    Check(SPDFMacAIOutputIsCurrent(first), "a saved file is recognised as the one saved");
    [@"edited" writeToFile:first[@"path"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    Check(!SPDFMacAIOutputRemove(first) && [fm fileExistsAtPath:first[@"path"]],
          "Undo leaves a saved file the person has changed since");
    Check(SPDFMacAIOutputRemove(fresh) && ![fm fileExistsAtPath:fresh[@"path"]] && !SPDFMacAIOutputRemove(fresh),
          "Undo removes an unchanged saved file, once");
    for (NSString* name in [fm contentsOfDirectoryAtPath:downloads error:nil])
        Check(![name hasPrefix:@"."], "nothing hidden is left behind in Downloads");
    Check(!SPDFMacAIOutputWriteData([NSData data], downloads, @"a/b.md", nil), "a name with a folder is refused");
}

static void CheckCollection(NSString* root, NSString* downloads) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSURL* location = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Collection"]];
    SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:location];
    NSDictionary* unset = SPDFMacAIOutputSaveData(PNG(), @"Chart.png", store, nil);
    Check(unset && ![store documentForPath:unset[@"path"]] && ![fm fileExistsAtPath:location.path],
          "Collection not yet chosen: saved to Downloads, nothing captured, no Collection created");
    Check([store updateSettings:@{@"choice" : @"disabled"} error:nil], "Collection turned off");
    NSDictionary* off = SPDFMacAIOutputSaveData(PNG(), @"Chart.png", store, nil);
    Check([[off[@"path"] lastPathComponent] isEqual:@"Chart (2).png"] && ![store documentForPath:off[@"path"]],
          "Collection off: saved to Downloads, nothing captured");
    Check([store updateSettings:@{@"choice" : @"enabled"} error:nil], "Collection turned on");
    NSDictionary* on = SPDFMacAIOutputSaveData(PNG(), @"Chart.png", store, nil);
    Check([[on[@"path"] lastPathComponent] isEqual:@"Chart (3).png"] &&
          [Reason(store, on[@"path"]) isEqual:@"Made by the assistant"],
          "Collection on: captured at once with reason \"Made by the assistant\"");
    Check(SPDFMacAIOutputRemove(on) && [store documentForPath:on[@"path"]],
          "removing the Downloads copy leaves its Collection history, as removing any original does");
    (void)downloads;
}

static void CheckChat(NSString* root, NSString* downloads) {
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    activity.anchor = ^NSUInteger { return 0; };
    NSString* assets = [root stringByAppendingPathComponent:@"chat"];
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:assets withIntermediateDirectories:YES attributes:nil error:nil];
    activity.saveImage = ^NSDictionary*(NSDictionary* image) {
        NSString* kept = [assets stringByAppendingPathComponent:
            [NSUUID.UUID.UUIDString stringByAppendingString:@".png"]];
        return [fm copyItemAtPath:image[@"path"] toPath:kept error:nil] ? @{@"path" : kept} : nil;
    };
    NSMutableArray* opened = [NSMutableArray array], *revealed = [NSMutableArray array];
    SPDFMacAIOutputActions* actions = [SPDFMacAIOutputActions new];
    actions.open = ^(NSString* path) { [opened addObject:path]; };
    actions.reveal = ^(NSString* path) { [revealed addObject:path]; };

    NSDictionary* saved = SPDFMacAIOutputWriteData(PNG(), downloads, @"Report (OCR).pdf", nil);
    NSString* card = SPDFMacAIOutputShowSavedCard(activity, saved[@"path"], actions);
    NSDictionary* entry = activity.entries.lastObject;
    Check(card && [entry[SPDFMacAIActivityTitleKey] isEqual:@"Saved to Downloads"] &&
          [entry[SPDFMacAIActivityAttachmentsKey][0][@"name"] isEqual:@"Report (OCR).pdf"],
          "the chat says \"Saved to Downloads\" and names the file");
    NSArray* live = [activity liveActionsForEntry:card];
    Check([[live valueForKey:@"title"] isEqual:(@[@"Open", @"Show in Finder"])], "with Open and Show in Finder");
    Check([activity performAction:@"open" forEntry:card] && [activity performAction:@"reveal" forEntry:card] &&
          [opened isEqual:@[saved[@"path"]]] && [revealed isEqual:@[saved[@"path"]]],
          "Open opens the saved file and Show in Finder selects it");
    SPDFMacAIOutputRemove(saved);
    [activity performAction:@"open" forEntry:card];
    entry = activity.entries.lastObject;
    Check(opened.count == 1 && [entry[SPDFMacAIActivityStatusKey] isEqual:@"This file is no longer in Downloads."] &&
          ![activity liveActionsForEntry:card].count, "once the file is gone, the card says so and its buttons go");

    NSString* chart = [root stringByAppendingPathComponent:@"chart.png"];
    [PNG() writeToFile:chart atomically:YES];
    NSString* image = [activity addImageAtPath:chart caption:@"sales.png" options:SPDFMacAIActivityOptionsNone];
    NSString* stored = activity.entries.lastObject[SPDFMacAIActivityImageKey][@"path"];
    SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:
        [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"ChartCollection"]]];
    [store updateSettings:@{@"choice" : @"enabled"} error:nil];
    __block NSDictionary* receipt = nil;
    __block BOOL finished = NO;
    SPDFMacAIOutputSaveChatImage(activity, stored, @"sales.png", store, actions, ^(NSDictionary* r, NSError* e) {
        (void)e; receipt = r; finished = YES;
    });
    Check(Spin(^BOOL { return finished; }) && [[receipt[@"path"] lastPathComponent] isEqual:@"sales.png"] &&
          [receipt[@"path"] hasPrefix:downloads], "Save on a chart writes it to Downloads under its caption");
    Check([Reason(store, receipt[@"path"]) isEqual:@"Made by the assistant"], "and keeps it in Collection");
    NSDictionary* row = nil;
    for (NSDictionary* candidate in activity.entries)
        if ([candidate[SPDFMacAIActivityIDKey] isEqual:image]) row = candidate;
    Check([row[SPDFMacAIActivityStatusKey] isEqual:@"Saved to Downloads"] &&
          [[[activity liveActionsForEntry:image] valueForKey:@"id"] isEqual:(@[@"open", @"reveal"])],
          "the chart's row says \"Saved to Downloads\" with Open and Show in Finder");
    [activity performAction:@"reveal" forEntry:image];
    Check([revealed.lastObject isEqual:receipt[@"path"]], "Show in Finder selects the saved chart");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"SPDFMacAIOutputsTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil
                                                      error:nil];
        CheckNames();
        CheckDownloadsFolder(root);
        NSString* downloads = SPDFMacAIDownloadsDirectory();
        CheckNoOverwrite(downloads);
        CheckCollection(root, downloads);
        CheckChat(root, downloads);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (failures) { fprintf(stderr, "SPDFMacAIOutputsTests: %d failures\n", failures); return 1; }
    puts("SPDFMacAIOutputsTests passed");
    return 0;
}
