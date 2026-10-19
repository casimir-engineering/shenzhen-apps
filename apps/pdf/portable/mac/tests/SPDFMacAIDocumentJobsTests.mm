#import <Cocoa/Cocoa.h>
#import "SPDFMacAIDocumentJobs.h"
#import "SPDFMacToolEnvironment.h"
#include "shenzhen_pdf_core.h"
#include <sys/stat.h>
#include <unistd.h>

static void Check(BOOL condition, NSString* message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static NSString* Tool(NSString* directory, NSString* body) {
    NSString* path=[directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(path.fileSystemRepresentation,0700);
    return path;
}
static void PDF(NSString* path) {
    CGRect bounds=CGRectMake(0,0,300,300);
    CGContextRef context=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&bounds,NULL);
    CGPDFContextBeginPage(context,NULL); [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
    [@"Hello world" drawAtPoint:NSMakePoint(20,250) withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Helvetica" size:16]}];
    [NSGraphicsContext restoreGraphicsState]; CGPDFContextEndPage(context); CGPDFContextClose(context); CGContextRelease(context);
}
int main(void) { @autoreleasepool {
    NSFileManager* fm=NSFileManager.defaultManager;
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* source=[directory stringByAppendingPathComponent:@"original.pdf"]; PDF(source);
    NSData* original=[NSData dataWithContentsOfFile:source];
    NSString* output=[directory stringByAppendingPathComponent:@"result.pdf"];
    NSString* copy=Tool(directory,@"#!/bin/sh\nfor arg do prev=\"$last\"; last=\"$arg\"; done\ncp \"$prev\" \"$last\"\n");
    NSDictionary* environment=spdf_mac_tool_environment(@{@"PYTHONHOME":@"/wrong"},@[copy],@{});
    NSProgress* progress=[NSProgress progressWithTotalUnitCount:1]; NSError* error=nil;
    NSDictionary* receipt=SPDFAIRunPDFJob(@"ocr",source,output,copy,environment,@{@"language":@"eng"},progress,&error);
    Check(receipt!=nil,error.localizedDescription ?: @"fake OCR succeeds");
    Check(SPDFAIJobReceiptIsCurrent(receipt),@"completed output has a verifiable identity");
    Check([original isEqual:[NSData dataWithContentsOfFile:source]],@"OCR never edits its source");
    Check(SPDFAIRemoveJobOutput(receipt),@"Undo removes its own unchanged output");
    Check(!SPDFAIRemoveJobOutput(receipt),@"duplicate Undo cannot remove a later replacement");

    receipt=SPDFAIRunPDFJob(@"export-pdf",source,output,@"",environment,@{},progress,&error);
    Check(receipt!=nil,@"export verifies a real PDF");
    NSFileHandle* handle=[NSFileHandle fileHandleForWritingAtPath:output]; [handle seekToEndOfFile];
    [handle writeData:[@"% human edit\n" dataUsingEncoding:NSUTF8StringEncoding]]; [handle closeFile];
    Check(!SPDFAIRemoveJobOutput(receipt),@"Undo preserves intervening output edits");
    Check(!SPDFAIRunPDFJob(@"export-pdf",source,output,@"",environment,@{},progress,&error),@"existing output is never overwritten");
    [fm removeItemAtPath:output error:nil];

    NSString* bad=Tool(directory,@"#!/bin/sh\necho 'fake tool failed' >&2\nexit 9\n");
    Check(!SPDFAIRunPDFJob(@"ocr",source,output,bad,environment,@{},progress,&error),@"nonzero tool exit fails");
    Check(![fm fileExistsAtPath:output],@"failure leaves no installed output");
    NSString* invalid=Tool(directory,@"#!/bin/sh\nfor arg do last=\"$arg\"; done\necho broken > \"$last\"\n");
    Check(!SPDFAIRunPDFJob(@"ocr",source,output,invalid,environment,@{},progress,&error),@"zero exit with invalid PDF still fails");
    Check(![fm fileExistsAtPath:output],@"invalid output is discarded");

    NSString* translate=Tool(directory,@"#!/bin/sh\necho 'WARNING: Language en package test expects a newer version'\n/usr/bin/sed 's/Hello world/Bonjour monde/'\n");
    error=nil; receipt=SPDFAIRunPDFJob(@"translate",source,output,translate,environment,
        @{@"sourceLanguage":@"en",@"targetLanguage":@"fr"},progress,&error);
    Check(receipt!=nil,error.localizedDescription ?: @"translation writes a PDF");
    char message[1024]={}; spdf_document* doc=spdf_open(output.fileSystemRepresentation,message,sizeof(message));
    spdf_text_lines lines={}; Check(doc && spdf_extract_page_text_lines(doc,0,&lines,message,sizeof(message)),@"translated PDF opens");
    BOOL found=NO; for (int i=0;i<lines.count;i++) if (strstr(lines.items[i].text,"Bonjour")) found=YES;
    spdf_free_text_lines(&lines); spdf_close(doc); Check(found,@"production translation writer applied tool output");
    Check(SPDFAIRemoveJobOutput(receipt),@"translated output undo");

    NSString* marker=[directory stringByAppendingPathComponent:@"started"];
    NSString* slow=Tool(directory,[NSString stringWithFormat:@"#!/bin/sh\necho started > '%@'\ntrap '' TERM\nwhile :; do :; done\n",marker]);
    NSProgress* cancel=[NSProgress progressWithTotalUnitCount:1];
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSDictionary* cancelledReceipt=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        cancelledReceipt=SPDFAIRunPDFJob(@"ocr",source,output,slow,environment,@{},cancel,nil);
        dispatch_semaphore_signal(done);
    });
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (![fm fileExistsAtPath:marker] && deadline.timeIntervalSinceNow>0) [NSThread sleepForTimeInterval:0.01];
    Check([fm fileExistsAtPath:marker],@"cancellation fixture actually launched");
    [cancel cancel];
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,@"Stop terminates an uncooperative tool promptly");
    Check(!cancelledReceipt && ![fm fileExistsAtPath:output],@"cancelled tool cannot install late output");
    [fm removeItemAtPath:marker error:nil];
    NSString* lateMarker=[directory stringByAppendingPathComponent:@"orphan-output"];
    NSString* childTool=Tool(directory,[NSString stringWithFormat:
        @"#!/bin/sh\ntrap '' TERM\n/bin/sh -c 'trap \"\" TERM; sleep 1; echo orphan > \"%@\"' &\necho started > '%@'\nwait\n",lateMarker,marker]);
    NSProgress* childCancel=[NSProgress progressWithTotalUnitCount:1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        SPDFAIRunPDFJob(@"ocr",source,output,childTool,environment,@{},childCancel,nil);
        dispatch_semaphore_signal(done);
    });
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (![fm fileExistsAtPath:marker] && deadline.timeIntervalSinceNow>0) [NSThread sleepForTimeInterval:0.01];
    Check([fm fileExistsAtPath:marker],@"descendant cancellation fixture actually launched");
    [childCancel cancel];
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,@"Stop completes with subprocess children");
    [NSThread sleepForTimeInterval:1.2];
    Check(![fm fileExistsAtPath:lateMarker],@"Stop kills descendants, not only the root NSTask");
    [fm removeItemAtPath:marker error:nil];
    Check(!SPDFAIRunPDFJob(@"ocr",source,output,slow,environment,@{},cancel,nil),@"cancel before launch fails");
    Check(![fm fileExistsAtPath:marker],@"cancel before launch performs no executable work");
    Check([original isEqual:[NSData dataWithContentsOfFile:source]],@"all jobs preserve original bytes");
    for (NSString* name in [fm contentsOfDirectoryAtPath:directory error:nil])
        Check(![name hasPrefix:@".job-"],@"every job cleans its private scratch inputs and diagnostics");
    [fm removeItemAtPath:directory error:nil];
    puts("SPDFMacAIDocumentJobsTests passed");
} return 0; }
