// document_job through the reader (mac/SPDFMacAIOutputs.h): the output goes to Downloads (this run's, never the
// person's) under a clear name, " 2" beside a file already there, which stays untouched; Collection keeps it with
// reason "Made by the assistant" while Collection is on and not while it is off; Undo closes the tab and removes only
// the exact file made, leaving Collection's history. Included by SPDFMacAIDocumentContextTests.mm.
#pragma once
#import "SPDFMacAIOutputs.h"

static NSDictionary* RunExportJob(SPDFMacAITools* tools, NSString* path) {
    __block NSDictionary* result=nil;
    [tools performTool:@"document_job" arguments:@{@"path":SPDFAIDocumentIdentifier(path),@"kind":@"export-pdf",
        @"revision":SPDFSearchFileStamp(path)} completion:^(NSDictionary* value){ result=value; }];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while (!result && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return result;
}

static NSString* LastReason(SPDFMacCollectionStore* store, NSString* path) {
    NSDictionary* document=[store documentForPath:path];
    return [[store versionsForDocumentID:document[@"id"] ?: @""] lastObject][@"reason"];
}

static void CheckJobOutputs(AIContextProbe* reader, NSString* path, SPDFTabGroup* group, NSString* root,
                            SPDFMacCollectionStore* collection) {
    NSFileManager* fm=NSFileManager.defaultManager;
    NSString* downloads=[root stringByAppendingPathComponent:@"Downloads"];
    SPDFMacAISetDownloadsDirectoryForTesting(downloads);
    [reader seedTabs:@[Tab(path,group)]];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check(![fm fileExistsAtPath:downloads],"tool creation and ordinary reads write nothing to Downloads");
    NSString* expected=[downloads stringByAppendingPathComponent:
        [path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@" (copy).pdf"]];

    NSDictionary* result=RunExportJob(tools,path);
    NSString* generated=[reader visiblePath];
    Check([result[@"completed"] boolValue] && [result[@"undoable"] boolValue] && !result[@"documentReceipt"] &&
        [result[@"path"] hasPrefix:@"doc:"] && [generated isEqual:expected] && [fm fileExistsAtPath:generated],
        "an export is saved to Downloads under a clear name, opened, and returned as an opaque, undoable result");
    Check([result[@"savedTo"] isEqual:@"Downloads"] && [result[@"filename"] isEqual:expected.lastPathComponent],
        "the model hears where the file went and its name");
    Check([LastReason(collection,generated) isEqual:@"Made by the assistant"],
        "Collection keeps it at once, with reason \"Made by the assistant\"");
    Check([tools undoLastAction:nil] && [[reader visiblePath] isEqual:path] && ![fm fileExistsAtPath:generated],
        "job Undo closes the output and removes only the file it made");
    Check([collection documentForPath:generated]!=nil,"Undo leaves Collection's history of it");

    [@"the person's own" writeToFile:expected atomically:YES encoding:NSUTF8StringEncoding error:nil];
    result=RunExportJob(tools,path); generated=[reader visiblePath];
    Check([generated.lastPathComponent isEqual:[expected.lastPathComponent stringByReplacingOccurrencesOfString:
        @" (copy).pdf" withString:@" (copy) 2.pdf"]] && [[NSString stringWithContentsOfFile:expected
        encoding:NSUTF8StringEncoding error:nil] isEqual:@"the person's own"],
        "beside a file already there the output gets \" 2\" and that file is untouched");
    Check([tools undoLastAction:nil] && ![fm fileExistsAtPath:generated] && [fm fileExistsAtPath:expected],
        "Undo removes the numbered output and nothing else");

    Check([collection updateSettings:@{@"choice":@"disabled"} error:nil],"Collection turned off");
    NSArray* documents=[collection documents];
    result=RunExportJob(tools,path); generated=[reader visiblePath];
    Check([result[@"completed"] boolValue] && [fm fileExistsAtPath:generated] &&
        [[collection documents] isEqual:documents],
        "with Collection off the output is still saved to Downloads, and not captured");
    Check([tools undoLastAction:nil] && ![fm fileExistsAtPath:generated],"Undo with Collection off");
    Check([collection updateSettings:@{@"choice":@"enabled"} error:nil],"Collection back on");
    [fm removeItemAtPath:expected error:nil];
    SPDFMacAISetDownloadsDirectoryForTesting(nil);
}
