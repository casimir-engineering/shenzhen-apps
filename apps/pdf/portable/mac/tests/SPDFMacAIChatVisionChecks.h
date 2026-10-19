#import "SPDFMacAIChatVision.h"
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
@interface VisionStore : SPDFMacAIChatStore
@property NSUInteger assetReads;
@property BOOL readOnMain;
@end
@implementation VisionStore
- (NSData*)previewData:(NSDictionary*)preview chatID:(NSString*)identifier {
    self.assetReads++; self.readOnMain=self.readOnMain || NSThread.isMainThread;
    return [super previewData:preview chatID:identifier];
}
@end
static BOOL VisionWait(BOOL (^predicate)(void)) {
    NSDate* until=[NSDate dateWithTimeIntervalSinceNow:4];
    while (!predicate() && until.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    return predicate();
}
static NSData* VisionPNG(void) {
    unsigned char pixels[32*16*4];
    for (NSUInteger i=0;i<sizeof(pixels);i+=4) { pixels[i]=210; pixels[i+1]=(i%5)*40; pixels[i+2]=24; pixels[i+3]=255; }
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels,32,16,8,32*4,color,kCGImageAlphaPremultipliedLast);
    CGImageRef image=CGBitmapContextCreateImage(context); NSMutableData* bytes=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)bytes,CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(destination,image,NULL); CGImageDestinationFinalize(destination);
    CFRelease(destination); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(color); return bytes;
}
static NSUInteger VisionImageCount(NSArray* wire) {
    NSUInteger count=0;
    for (NSDictionary* m in wire) if ([m[@"content"] isKindOfClass:NSArray.class])
        for (NSDictionary* part in m[@"content"]) if ([part[@"type"] isEqual:@"image_url"]) count++;
    return count;
}
static void CheckChatVision(NSURL* root) {
    VisionStore* store=[[VisionStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    [session send:@"Inspect drawing" model:@"fake/vision" apiKey:@"test"];
    CHECK(transport.sends==1 && store.assetReads==0,"plain text send remains synchronous and image-work-free");
    transport.reply(@{@"content":@"",@"tool_calls":@[
        @{@"id":@"render",@"type":@"function",@"function":@{@"name":@"render_page",@"arguments":@"{}"}},
        @{@"id":@"text",@"type":@"function",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}}]},nil);
    NSString* source=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".png"]];
    NSData* png=VisionPNG(); [png writeToFile:source atomically:YES];
    tools.reply(@{@"_localPreview":@{@"path":source,@"page":@2,@"title":@"Drawing",@"region":@{@"x":@0.2,@"y":@0.3,@"width":@0.4,@"height":@0.5},@"citation":@"spdf-ai://document?path=doc:test&page=2"}});
    CHECK(transport.sends==1,"render pixels wait for rest of tool batch");
    tools.reply(@{@"text":@"page text"});
    CHECK(VisionWait(^BOOL{return transport.sends==2;}),"vision request follows completed batch");
    CHECK(store.assetReads==1 && !store.readOnMain,"model asset reading and conversion run off main thread");
    NSArray* wire=transport.messages;
    CHECK(VisionImageCount(wire)==1,"model receives actual image part");
    if (VisionImageCount(wire)!=1) return;
    CHECK([wire[3][@"role"] isEqual:@"tool"] && [wire[4][@"role"] isEqual:@"tool"] && [wire[5][@"role"] isEqual:@"user"],"all tool results precede image-bearing user message");
    NSArray* parts=wire[5][@"content"];
    NSString* encoded=parts[1][@"image_url"][@"url"];
    NSURLRequest* http=SPDFMacAIChatRequest(wire,nil,@"test/vision",@"offline-test-key",nil);
    NSDictionary* body=[NSJSONSerialization JSONObjectWithData:http.HTTPBody options:0 error:nil];
    CHECK([body[@"messages"][5][@"content"][1][@"image_url"][@"url"] isEqual:encoded],"valid rendered image survives full HTTP serialization");
    CHECK([[[NSData alloc] initWithBase64EncodedString:[encoded substringFromIndex:[@"data:image/png;base64," length]] options:0] isEqual:png],"rendered PNG bytes, not a local path, reach model");
    CHECK([parts[0][@"text"] containsString:@"render"] && [parts[0][@"text"] containsString:@"region"] && [parts[0][@"text"] containsString:@"spdf-ai"],"pixels retain call/page/region/citation provenance");
    NSDictionary* persisted=[store chatWithID:session.chat[@"id"]];
    NSString* json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:persisted options:0 error:nil] encoding:NSUTF8StringEncoding];
    CHECK(![json containsString:@"base64"],"chat persistence never duplicates base64");
    [session cancel]; [session loadChat:[store chatWithID:session.chat[@"id"]]];
    NSUInteger before=transport.sends; [session send:@"Inspect again" model:@"fake/vision" apiKey:@"test"];
    CHECK(VisionWait(^BOOL{return transport.sends>before;}),"reopened chat reconstructs vision input lazily");
    CHECK(VisionImageCount(transport.messages)==1,"reopened chat preserves image evidence");
    [session cancel]; before=transport.sends; [session send:@"Cancel image request" model:@"fake/vision" apiKey:@"test"]; [session cancel];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    CHECK(transport.sends==before,"stop during image preparation prevents network send");
    NSDictionary* preview=nil;
    for (NSDictionary* m in session.chat[@"messages"]) if ([m[@"role"] isEqual:@"preview"]) preview=m[@"preview"];
    for (id malformedID in @[@42,NSNull.null]) {
        NSArray* malformed=@[@{@"role":@"preview",@"local":@YES,@"preview":preview,@"tool_call_id":malformedID}];
        CHECK(VisionImageCount(SPDFMacAIChatVisionMessages(malformed,session.chat[@"id"],store,nil))==1,"malformed persisted call ID is ignored safely");
    }
    CHECK(!VisionImageCount(SPDFMacAIChatVisionMessages(@[@{@"role":@"preview",@"local":@YES,@"preview":NSNull.null}],session.chat[@"id"],store,nil)),"malformed preview object safely reports unavailable");
    NSMutableDictionary* forged=[preview mutableCopy]; forged[@"path"]=source;
    CHECK(![store previewData:forged chatID:session.chat[@"id"]],"outside chat assets cannot be exfiltrated");
    NSString* target=preview[@"path"];
    [NSFileManager.defaultManager removeItemAtPath:target error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:target withDestinationPath:source error:nil];
    CHECK(![store previewData:preview chatID:session.chat[@"id"]],"asset symlink escape rejected");
    [NSFileManager.defaultManager removeItemAtPath:target error:nil];
    mkfifo(target.fileSystemRepresentation,0600);
    CHECK(![store previewData:preview chatID:session.chat[@"id"]],"FIFO asset rejected without blocking");
    [NSFileManager.defaultManager removeItemAtPath:target error:nil];
    NSArray* unavailable=SPDFMacAIChatVisionMessages(session.chat[@"messages"],session.chat[@"id"],store,nil);
    CHECK(!VisionImageCount(unavailable),"missing asset sends no fabricated pixels");
    BOOL explicitMissing=NO;
    for (NSDictionary* m in unavailable) if ([m[@"content"] isKindOfClass:NSArray.class]) for (NSDictionary* part in m[@"content"])
        if ([part[@"text"] containsString:@"pixels unavailable"]) explicitMissing=YES;
    CHECK(explicitMissing,"missing pixels are explicitly disclosed to model");
    NSMutableArray* many=[NSMutableArray array]; [png writeToFile:target atomically:YES];
    for (int i=0;i<6;i++) [many addObject:@{@"role":@"preview",@"local":@YES,@"preview":preview}];
    CHECK(VisionImageCount(SPDFMacAIChatVisionMessages(many,session.chat[@"id"],store,nil))==4,"only four most recent image requests are retained");
    NSMutableArray* crops=[NSMutableArray array];
    NSDictionary* provenance=@{@"path":@"doc:drawing",@"page":@1,@"revision":@"drawing-revision"};
    for(NSUInteger i=0;i<6;i++) {
        NSMutableDictionary* asset=[preview mutableCopy];asset[@"citation"]=provenance;
        asset[@"caption"]=i ? @"detail" : @"overview";
        asset[@"region"]=i ? @{@"x":@.2,@"y":@.3,@"width":@.3,@"height":@.2} : @{@"x":@0,@"y":@0,@"width":@1,@"height":@1};
        [crops addObject:@{@"role":@"preview",@"local":@YES,@"preview":asset}];
    }
    NSArray* paired=SPDFMacAIChatVisionMessages(crops,session.chat[@"id"],store,nil);BOOL overviewRetained=NO;
    for(NSDictionary* message in paired) {
        NSArray* parts=message[@"content"];
        if([parts isKindOfClass:NSArray.class] && parts.count==2 && [parts[0][@"text"] containsString:@"overview"] && [parts[1][@"type"] isEqual:@"image_url"])overviewRetained=YES;
    }
    CHECK(overviewRetained && VisionImageCount(paired)==4,"repeated details retain full-page spatial context within four-image budget");
    [@"not a PNG" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CHECK(!VisionImageCount(SPDFMacAIChatVisionMessages(many,session.chat[@"id"],store,nil)),"forged invalid PNG never enters request");
    CHECK(!SPDFMacAIChatVisionMessages(many,session.chat[@"id"],store,^BOOL{return YES;}),"cancelled projection exits before assets");
    [NSFileManager.defaultManager removeItemAtPath:source error:nil];
}
