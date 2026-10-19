// A controlled encoding boundary exercises real lazy reader routing/queueing.
#import "SPDFMacImageRotationIntegration.h"
#import "SPDFMacImageRotation.h"
#import <atomic>
static std::atomic<unsigned> encodes;
static dispatch_semaphore_t firstStarted,releaseFirst;
static NSMutableArray<NSNumber*>* turns;
static unsigned protections,captures,reloads,invalidations;
static BOOL permit=YES,hadError;
static void Check(BOOL value,const char* label) { if(!value) { fprintf(stderr,"FAIL: %s\n",label); exit(1); } }
BOOL SPDFPathIsRasterImage(NSString* path) { return [path.pathExtension isEqual:@"png"]; }
BOOL SPDFRotateImageAtPath(NSString* path,int degrees,NSError** error) {
    (void)path; (void)error;
    if(encodes.fetch_add(1)==0) {
        dispatch_semaphore_signal(firstStarted);
        dispatch_semaphore_wait(releaseFirst,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
    }
    @synchronized(turns) { [turns addObject:@(degrees)]; }
    return YES;
}
@implementation SPDFDocumentTab
@end
@implementation ShenzhenMacDelegate
- (SPDFDocumentTab*)selectedTab { return _tabs.firstObject; }
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation {
    (void)path; (void)operation; Check(NSThread.isMainThread,"protection runs on reader thread"); protections++; return permit;
}
- (void)collectionDidSavePath:(NSString*)path { (void)path; captures++; }
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab { (void)tab; invalidations++; }
- (void)loadSelectedTab { reloads++; }
- (void)showError:(NSString*)message detail:(NSString*)detail { (void)message; (void)detail; hadError=YES; }
@end
@interface RotationFixture : ShenzhenMacDelegate
- (void)prepare;
- (void)setReadOnly:(BOOL)value;
@end
@implementation RotationFixture
- (void)prepare {
    _doc=(spdf_document*)1; _path=@"/fixture/image.png";
    SPDFDocumentTab* tab=[SPDFDocumentTab new]; tab.path=_path;
    _tabs=[NSMutableArray arrayWithObject:tab];
}
- (void)setReadOnly:(BOOL)value { _tabs.firstObject.readOnly=value; }
@end
static void DrainUntil(unsigned wanted) {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(captures<wanted && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
}
int main(void) {
    @autoreleasepool {
        turns=[NSMutableArray array]; firstStarted=dispatch_semaphore_create(0); releaseFirst=dispatch_semaphore_create(0);
        RotationFixture* reader=[RotationFixture new]; [reader prepare];
        Check(encodes==0 && protections==0,"reader setup does no image decoding, copying or protection work");
        [reader setReadOnly:YES]; [reader rotateActiveImageByDegrees:90];
        Check(hadError && encodes==0 && protections==0,"read-only copy never reaches protection or file writer");
        [reader setReadOnly:NO]; permit=NO; [reader rotateActiveImageByDegrees:90];
        Check(encodes==0,"cancelled Collection protection prevents image write");
        permit=YES; [reader rotateActiveImageByDegrees:90];
        Check(dispatch_semaphore_wait(firstStarted,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,"explicit command starts worker");
        [reader rotateActiveImageByDegrees:90]; [reader rotateActiveImageByDegrees:-90];
        Check(encodes==1,"pending rotations do not race the first file write");
        dispatch_semaphore_signal(releaseFirst); DrainUntil(3);
        Check(captures==3 && reloads==3 && invalidations==3,"every completed edit updates history and reader runtime");
        Check([turns isEqual:@[@90,@90,@(-90)]],"rapid repeated commands run in order without dropped input");
        puts("SPDFMacImageRotationIntegrationTests passed");
    }
    return 0;
}
