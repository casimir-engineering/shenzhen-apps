#import "SPDFMacCollectionCompanion.h"
#import "SPDFMacCollectionPipe.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionCredentialIntegration.h"
// Credential paths are outside this event-delivery test; no Keychain backend is linked.
@implementation SPDFPasswordCredentialStore
+ (instancetype)sharedStore { return nil; }
@end
@implementation SPDFMacCollectionCredentials
@end
NSNotificationName const SPDFCollectionStoreDidChangeNotification=@"SPDFCollectionStoreDidChange";
static int failures;
static void Expect(NSString* label,BOOL ok) { if(!ok){fprintf(stderr,"FAIL %s\n",label.UTF8String);failures++;} }
int main(void) { @autoreleasepool {
    NSObject* store=[NSObject new], *unrelated=[NSObject new];
    SPDFCollectionCompanionHost* host=[[SPDFCollectionCompanionHost alloc] initWithStore:(id)store
        open:^(NSString* path,BOOL archived){(void)path;(void)archived;}
        navigate:^(NSDictionary* doc,NSDictionary* version,NSUInteger page,NSString* query,BOOL history){
            (void)doc;(void)version;(void)page;(void)query;(void)history;
        }];
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFCollectionStoreDidChangeNotification object:store];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    Expect(@"store change never launches dormant companion",[host valueForKey:@"task"]==nil && [host valueForKey:@"pipe"]==nil);
    NSPipe* incoming=[NSPipe pipe], *outgoing=[NSPipe pipe];
    SPDFCollectionPipe* parent=[[SPDFCollectionPipe alloc] initWithReader:outgoing.fileHandleForReading writer:incoming.fileHandleForWriting];
    SPDFCollectionPipe* child=[[SPDFCollectionPipe alloc] initWithReader:incoming.fileHandleForReading writer:outgoing.fileHandleForWriting];
    NSMutableArray* messages=[NSMutableArray array];
    child.messageHandler=^(NSDictionary* message){@synchronized(messages){[messages addObject:message];}};
    [parent start];[child start];[host setValue:parent forKey:@"pipe"];
    for(NSUInteger i=0;i<50;i++)
        [NSNotificationCenter.defaultCenter postNotificationName:SPDFCollectionStoreDidChangeNotification object:store];
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:2];
    BOOL received=NO;
    while(!received && end.timeIntervalSinceNow>0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        @synchronized(messages){received=messages.count>0;}
    }
    @synchronized(messages){Expect(@"commit burst sends one refresh through existing private pipe",
        messages.count==1 && [messages.firstObject isEqual:@{@"kind":@"refresh"}]);}
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFCollectionStoreDidChangeNotification object:unrelated];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
    @synchronized(messages){Expect(@"unrelated store does not refresh this companion",messages.count==1);}
    __weak SPDFCollectionCompanionHost* released=host; host=nil;
    Expect(@"observer does not retain host",released==nil);
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFCollectionStoreDidChangeNotification object:store];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    @synchronized(messages){Expect(@"destroyed host removes observer",messages.count==1);}
    [parent close];[child close];
    if(!failures)puts("SPDFMacCollectionRefreshHostTests passed");return failures ? 1 : 0;
}}
