#import <Foundation/Foundation.h>
#import "SPDFMacCollectionPipe.h"
static int failures;
static void Expect(NSString* label,BOOL ok) { if (!ok) { fprintf(stderr,"FAIL %s\n",label.UTF8String); failures++; } }
static BOOL Wait(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0;
}
int main(void) {
    @autoreleasepool {
        NSString* mac=[@(__FILE__).stringByDeletingLastPathComponent stringByDeletingLastPathComponent];
        NSString* source=[NSString stringWithContentsOfFile:[mac stringByAppendingPathComponent:@"ShenzhenPDFMac.mm"]
                                                  encoding:NSUTF8StringEncoding error:nil];
        NSRange main=[source rangeOfString:@"int main(int argc, const char* argv[])"];
        NSString* launch=main.location!=NSNotFound ? [source substringFromIndex:main.location] : @"";
        NSRange helper=[launch rangeOfString:@"--collection-companion"];
        NSRange reader=[launch rangeOfString:@"ShenzhenMacDelegate* delegate ="];
        Expect(@"companion exits into its own lifecycle before constructing the reader",
            source.length && helper.location!=NSNotFound && helper.location<reader.location);
        Expect(@"ordinary launch does not instantiate or show Collection",
            [launch rangeOfString:@"SPDFCollectionCompanionHost alloc"].location==NSNotFound &&
            [launch rangeOfString:@"showCollectionManager"].location==NSNotFound);
        NSString* runtime=[NSString stringWithContentsOfFile:[mac stringByAppendingPathComponent:@"SPDFMacCollectionCompanionRuntime.mm"] encoding:NSUTF8StringEncoding error:nil];
        NSString* host=[NSString stringWithContentsOfFile:[mac stringByAppendingPathComponent:@"SPDFMacCollectionCompanionHost.mm"] encoding:NSUTF8StringEncoding error:nil];
        Expect(@"Return to reader uses the existing companion activation channel",
            [runtime containsString:@"returnHandler"] && [runtime containsString:@"activateReader"] && [host containsString:@"activateReader"]);
        NSString* integration=[NSString stringWithContentsOfFile:[mac stringByAppendingPathComponent:@"SPDFMacCollectionIntegration.mm"] encoding:NSUTF8StringEncoding error:nil];
        NSRange capGuard=[integration rangeOfString:@"if ([note.userInfo[@\"storageLimitOnly\"] boolValue]) return;"];
        NSRange capture=[integration rangeOfString:@"for (SPDFDocumentTab* tab in owner->_tabs)"];
        Expect(@"storage-only changes refresh History without recapturing or reimporting documents",
            [runtime containsString:@"storageLimitOnly"] && [host containsString:@"storageLimitOnly"] &&
            capGuard.location != NSNotFound && capGuard.location < capture.location);
        NSPipe* outgoing=[NSPipe pipe], *incoming=[NSPipe pipe];
        SPDFCollectionPipe* parent=[[SPDFCollectionPipe alloc] initWithReader:incoming.fileHandleForReading
                                                                      writer:outgoing.fileHandleForWriting];
        SPDFCollectionPipe* child=[[SPDFCollectionPipe alloc] initWithReader:outgoing.fileHandleForReading
                                                                     writer:incoming.fileHandleForWriting];
        dispatch_semaphore_t received=dispatch_semaphore_create(0), closed=dispatch_semaphore_create(0);
        __block NSDictionary* reply=nil;
        parent.messageHandler=^(NSDictionary* message) { reply=message; dispatch_semaphore_signal(received); };
        parent.closedHandler=^{ dispatch_semaphore_signal(closed); };
        __weak SPDFCollectionPipe* weakChild=child;
        child.messageHandler=^(NSDictionary* message) { [weakChild send:message]; };
        [parent start]; [child start];
        NSDictionary* message=@{@"kind":@"navigate",@"documentID":@"doc",@"versionID":@"version",
            @"query":@"café\nline two",@"history":@YES,@"page":@4};
        Expect(@"intent sent over private pipe",[parent send:message]);
        Expect(@"Unicode/newline intent survives bidirectional transport",Wait(received) && [reply isEqual:message]);
        NSDictionary* settings=@{@"kind":@"settings",@"storageLimitOnly":@YES};
        Expect(@"storage-only setting flag survives companion transport",[parent send:settings] &&
            Wait(received) && [reply isEqual:settings]);
        // A broken/partial frame must not hide the next complete valid frame.
        [outgoing.fileHandleForWriting writeData:[@"not-json\n{\"kind\":\"frag" dataUsingEncoding:NSUTF8StringEncoding]];
        [outgoing.fileHandleForWriting writeData:[@"mented\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
        Expect(@"partial frames reassemble and malformed frames are ignored",Wait(received) && [reply[@"kind"] isEqual:@"fragmented"]);
        dispatch_apply(20,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t index) {
            [parent send:@{@"kind":@"concurrent",@"index":@(index)}];
        });
        BOOL all=YES; for (NSUInteger i=0;i<20;++i) all=Wait(received) && all;
        Expect(@"concurrent writers retain message boundaries",all);
        [child close]; Expect(@"helper exit is detected by EOF",Wait(closed));
        Expect(@"closed channel fails safely instead of SIGPIPE",![parent send:message]);
        [parent close];
        if (!failures) puts("SPDFMacCollectionCompanionTests passed");
        return failures ? 1 : 0;
    }
}
