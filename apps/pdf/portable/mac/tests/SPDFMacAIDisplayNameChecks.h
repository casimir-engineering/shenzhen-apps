// Read-only documents through the assistant's tools: rename_document gives one a name shown in ShenzhenPDF (its file
// keeps its own, Collection keeps the name, the assistant hears it in list_workspace), with Undo; document_job works
// on it from the revision read_pages gives (its private copy's), shown or not, for every job kind; move-tab moves
// several documents in one call. The owner's chat failed on each: "Use Rename in the tab menu to choose Save As",
// and "Show the document and read its current revision" four times. Included by SPDFMacAIDocumentContextTests.mm.
#pragma once
#import "SPDFMacAIOutputs.h"
#include <sys/stat.h>

static NSDictionary* RunTool(SPDFMacAITools* tools, NSString* name, NSDictionary* arguments) {
    __block NSDictionary* result=nil;
    [tools performTool:name arguments:arguments completion:^(NSDictionary* value){ result=value; }];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while (!result && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return result;
}

static void CheckReadOnlyNamesAndJobs(AIContextProbe* reader, NSString* path, SPDFTabGroup* group, NSString* root,
                                      SPDFMacCollectionStore* collection) {
    NSFileManager* fm=NSFileManager.defaultManager;
    NSString* folder=[root stringByAppendingPathComponent:@"read-only"];
    [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* source=[folder stringByAppendingPathComponent:@"2f6fa8b5ebba154de171778d8d99b38f.pdf"];
    NSString* copy=[root stringByAppendingPathComponent:@"private-read-copy.pdf"];
    [fm copyItemAtPath:path toPath:source error:nil]; [fm copyItemAtPath:path toPath:copy error:nil];
    chmod(source.fileSystemRepresentation,0444);
    Check([collection capturePath:source reason:@"test" error:nil]!=nil,"the read-only document is in Collection");
    SPDFDocumentTab* shown=Tab(path,group), *readOnly=Tab(source,group);
    readOnly.readOnly=YES; readOnly.workingPath=copy;  // as the reader opens a read-only file: from a private copy
    [reader seedTabs:@[shown,readOnly]];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    NSString* identifier=SPDFAIDocumentIdentifier(source);
    NSString* revision=RunTool(tools,@"read_pages",@{@"path":identifier,@"page":@1,@"count":@1})[@"revision"];
    Check([revision isEqual:SPDFSearchFileStamp(copy)] && ![revision isEqual:SPDFSearchFileStamp(source)],
        "read_pages gives a read-only document the revision of the copy the reader reads");

    // document_job, on the document while another is in front.
    NSString* downloads=[root stringByAppendingPathComponent:@"Downloads-read-only"];
    SPDFMacAISetDownloadsDirectoryForTesting(downloads);
    NSDictionary* job=RunTool(tools,@"document_job",@{@"path":identifier,@"kind":@"export-pdf",@"revision":revision,
        @"name":@"LTE-C9901 datasheet.pdf"});
    NSString* saved=[downloads stringByAppendingPathComponent:@"LTE-C9901 datasheet.pdf"];
    Check([job[@"completed"] boolValue] && [fm fileExistsAtPath:saved],
        "export-pdf of a read-only document that isn't shown completes from the revision read_pages gave");
    Check([tools undoLastAction:nil] && ![fm fileExistsAtPath:saved],"its Undo removes the export");
    [reader selectTabAtIndex:1];
    job=RunTool(tools,@"document_job",@{@"path":identifier,@"kind":@"export-pdf",@"revision":SPDFSearchFileStamp(source)});
    Check([job[@"completed"] boolValue],"the original's own revision is accepted too");
    Check([tools undoLastAction:nil],"Undo"); [reader selectTabAtIndex:0];
    for (NSString* kind in @[@"ocr",@"translate"]) {
        NSMutableDictionary* arguments=[@{@"path":identifier,@"kind":kind,@"revision":revision} mutableCopy];
        if ([kind isEqual:@"translate"]) { arguments[@"sourceLanguage"]=@"zh"; arguments[@"targetLanguage"]=@"en"; }
        NSString* error=RunTool(tools,@"document_job",arguments)[@"error"] ?: @"";
        Check(![error containsString:@"Show the document"] && ![error containsString:@"changed since"],
            [[kind stringByAppendingString:@" passes the same revision check (it fails later only for its own tools)"] UTF8String]);
    }
    NSString* stale=RunTool(tools,@"document_job",@{@"path":identifier,@"kind":@"export-pdf",@"revision":@"0:0:0"})[@"error"];
    Check([stale containsString:@"Read it again"],"a stale revision is refused, saying what to do");

    // rename_document: the file keeps its name, ShenzhenPDF shows the new one.
    NSDictionary* renamed=RunTool(tools,@"rename_document",@{@"path":identifier,@"revision":revision,
        @"name":@"LTE-C9901 - IR emitter and detector - datasheet.pdf"});
    NSString* name=@"LTE-C9901 - IR emitter and detector - datasheet";
    Check([renamed[@"renamed"] boolValue] && [renamed[@"fileRenamed"] isEqual:@NO] && [renamed[@"undoable"] boolValue] &&
        [renamed[@"path"] isEqual:identifier] && [renamed[@"title"] isEqual:name],
        "a read-only document is renamed in ShenzhenPDF, with Undo, keeping its ID");
    Check([renamed[@"tellThePerson"] isEqual:[NSString stringWithFormat:@"It now shows as “%@” in its tab and in Collection. "
        "The file itself keeps its name, %@, because it is read-only.",name,source.lastPathComponent]],
        "the result tells the person plainly that the file keeps its name, and why");
    Check([fm fileExistsAtPath:source] && [readOnly.path isEqual:source] && [readOnly.displayName isEqual:name],
        "the file is untouched and its tab shows the name");
    Check([[collection documentForPath:source][@"displayName"] isEqual:name] &&
        [SPDFCollectionDocumentTitle([collection documentForPath:source]) isEqual:name],"Collection keeps the name");
    NSDictionary* row=nil;
    for (NSDictionary* tab in Listed(tools,@{})[@"tabs"]) if ([tab[@"path"] isEqual:identifier]) row=tab;
    Check([row[@"title"] isEqual:name] && [row[@"filename"] isEqual:source.lastPathComponent],
        "list_workspace gives the assistant the name, and the file's own name beside it");
    NSDictionary* tabState=spdf_dictionary_from_tab(readOnly,0);
    Check([tabState[@"displayName"] isEqual:name] && [spdf_tab_from_dictionary(tabState).displayName isEqual:name],
        "the name is saved with the session and restored");
    job=RunTool(tools,@"document_job",@{@"path":identifier,@"kind":@"export-pdf",@"revision":revision});
    Check([job[@"filename"] isEqual:[name stringByAppendingString:@" (copy).pdf"]],"an export is named after the shown name");
    Check([tools undoLastAction:nil],"Undo the export");
    Check([RunTool(tools,@"rename_document",@{@"path":identifier,@"revision":revision,@"name":name})[@"error"]
        containsString:@"already shows"],"renaming to the same name says nothing changes");
    Check([tools undoLastAction:nil] && !readOnly.displayName && ![collection documentForPath:source][@"displayName"],
        "Undo gives back the file's name, in the tab and in Collection");
    NSString* refused=RunTool(tools,@"rename_document",@{@"path":identifier,@"revision":revision,@"name":name,@"target":@"file"})[@"error"];
    Check([refused containsString:@"read-only"] && [refused containsString:@"\"title\""],
        "target file on a read-only document is refused, naming the title target");

    // A writable file the person doesn't want renamed: target title.
    NSString* writable=SPDFAIDocumentIdentifier(path);
    renamed=RunTool(tools,@"rename_document",@{@"path":writable,@"revision":SPDFSearchFileStamp(path),
        @"name":@"Evidence - audio amplifier - notes",@"target":@"title"});
    Check([renamed[@"fileRenamed"] isEqual:@NO] && [fm fileExistsAtPath:path] &&
        [shown.displayName isEqual:@"Evidence - audio amplifier - notes"] &&
        [renamed[@"tellThePerson"] containsString:@"because you asked to keep the file's name"],
        "target title keeps a writable file's name");
    Check([tools undoLastAction:nil] && !shown.displayName,"and Undo takes the name back");
    Check(!SPDFAIDisplayNameForRename(path,@"  ") && !SPDFAIDisplayNameForRename(path,@"two\nlines") &&
        [SPDFAIDisplayNameForRename(path,@" A.PDF ") isEqual:@"A"] && [SPDFAIDisplayNameForRename(path,@"A.txt") isEqual:@"A.txt"],
        "shown names: trimmed, one line, without the file's own extension");

    // move-tab with paths: several documents into one group, one Undo.
    SPDFTabGroup* other=[SPDFTabGroup groupWithColor:@"blue"];
    SPDFDocumentTab* a=Tab(@"/a.pdf",nil),*b=Tab(@"/b.pdf",nil),*c=Tab(@"/c.pdf",other);
    [reader seedTabs:@[c,a,b]];
    NSDictionary* moved=RunTool(tools,@"organize_groups",@{@"command":@{@"action":@"move-tab",@"groupID":other.identifier,
        @"paths":@[SPDFAIDocumentIdentifier(@"/a.pdf"),SPDFAIDocumentIdentifier(@"/b.pdf")]}});
    Check(!moved[@"error"] && [a.group.identifier isEqual:other.identifier] && [b.group.identifier isEqual:other.identifier] &&
        [moved[@"undoable"] boolValue],
        "move-tab with paths moves several documents into the group in one call");
    Check([tools undoLastAction:nil] && ![a.group.identifier isEqual:other.identifier] && ![b.group.identifier isEqual:other.identifier],
        "one Undo puts them all back");
    moved=RunTool(tools,@"organize_groups",@{@"command":@{@"action":@"move-tab",@"groupID":other.identifier,
        @"paths":@[SPDFAIDocumentIdentifier(@"/a.pdf"),@"doc:not-open"]}});
    Check(moved[@"error"] && ![a.group.identifier isEqual:other.identifier],"an ID that isn't open refuses the whole move");
    chmod(source.fileSystemRepresentation,0644);
    SPDFMacAISetDownloadsDirectoryForTesting(nil);
    fprintf(stdout,"Read-only names, document jobs from the read copy's revision, and moving several tabs passed\n");
}
