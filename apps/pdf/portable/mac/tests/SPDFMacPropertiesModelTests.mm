#import <Cocoa/Cocoa.h>
#import "SPDFMacPropertiesModel.h"
#import "SPDFMacPropertiesPanel.h"
#import "SPDFMacPropertiesFormat.h"

@interface SPDFPropertiesPanelController (Testing)
- (void)buildPanelWithSourcePath:(NSString*)path parentWindow:(NSWindow*)parent;
- (void)startWordCountForText:(NSString*)text;
- (void)close;
- (NSTextField*)valueFieldForRow:(NSDictionary*)row;
@end
static void Check(BOOL value, NSString* label) { if (!value) { NSLog(@"FAIL %@",label); exit(1); } }
static NSMutableDictionary* Row(NSArray* sections, NSString* label) {
    for (NSDictionary* section in sections) for (NSMutableDictionary* row in section[@"rows"])
        if ([row[@"label"] isEqual:label]) return row;
    return nil;
}
static void RenderPanel(NSArray* sections, NSString* path, NSString* name, NSString* text) {
    SPDFPropertiesPanelController* controller = [SPDFPropertiesPanelController new];
    [controller setValue:sections forKey:@"sections"];
    [controller setValue:Row(sections,@"Text") forKey:@"textStatsRow"];
    [controller buildPanelWithSourcePath:path parentWindow:nil];
    NSPanel* panel = [controller valueForKey:@"panel"];
    Check(!panel.visible,@"construction remains offscreen");
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if (text) {
        [controller startWordCountForText:text];
        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while ([Row(sections,@"Text")[@"value"] isEqual:@"Counting…"] && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        NSUInteger words=0,characters=0; spdf_properties_count_text(text,&words,&characters);
        NSString* expected = [NSString stringWithFormat:@"%lu words · %lu characters",words,characters];
        Check([Row(sections,@"Text")[@"value"] isEqual:expected],@"text snapshot count completes without opening source in MuPDF");
    }
    [panel.contentView layoutSubtreeIfNeeded];
    Check(panel.contentView.fittingSize.width >= 500,@"readable panel width");
    NSString* directory = NSProcessInfo.processInfo.environment[@"SPDF_PROPERTIES_EVIDENCE_DIR"];
    if (directory.length) {
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSBitmapImageRep* pixels = [panel.contentView bitmapImageRepForCachingDisplayInRect:panel.contentView.bounds];
        [panel.appearance performAsCurrentDrawingAppearance:^{
            [panel.contentView cacheDisplayInRect:panel.contentView.bounds toBitmapImageRep:pixels];
        }];
        NSBitmapImageRep* opaque = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:pixels.pixelsWide pixelsHigh:pixels.pixelsHigh bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:opaque];
        NSRect rect = NSMakeRect(0,0,opaque.pixelsWide,opaque.pixelsHigh);
        [[NSColor colorWithWhite:.96 alpha:1] setFill]; NSRectFill(rect);
        [pixels drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:1 respectFlipped:YES hints:nil];
        [NSGraphicsContext restoreGraphicsState];
        pixels = opaque;
        [[pixels representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:
            [directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    }
    [controller close];
}
int main(int argc,const char** argv) {
    @autoreleasepool {
        Check(argc==2,@"repo path supplied");
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* textPath = [root stringByAppendingPathComponent:@"notes.txt"];
        [@"Hello reader" writeToFile:textPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* text = @{@"format":@"Text / source document",@"language":@"Plain Text",@"text":@"Hello reader",
            @"pageCount":@2,@"pageSize":[NSValue valueWithSize:NSMakeSize(595,842)]};
        NSArray* sections=SPDFPropertiesSections(NULL,textPath,textPath,0,0,0,text);
        Check([Row(sections,@"Pages")[@"value"] isEqual:@"2"] && Row(sections,@"Language"),@"text reader has relevant live page/language stats");
        Check(!Row(sections,@"Security") && !Row(sections,@"Annotations"),@"text does not inherit PDF metadata");
        RenderPanel(sections,textPath,@"text",text[@"text"]);
        NSDictionary* ai=@{@"summary":@"A compact summary of the circuit board.",@"language":@"fr",@"tags":@[@"Électronique",@"Carte"]};
        NSMutableDictionary* withAI=[text mutableCopy];withAI[@"aiAnalysis"]=ai;
        sections=SPDFPropertiesSections(NULL,textPath,textPath,0,0,0,withAI);
        Check([Row(sections,@"Tags")[@"value"] isEqual:@"Électronique · Carte"] &&
            [Row(sections,@"AI language")[@"value"] isEqual:@"French"] &&
            [Row(sections,@"Summary")[@"value"] isEqual:ai[@"summary"]],@"cached document metadata appears in Properties");
        RenderPanel(sections,textPath,@"ai-metadata",text[@"text"]);
        NSString* longPath=[@"/" stringByAppendingString:[@"Long directory name/" stringByPaddingToLength:600 withString:@"Long directory name/" startingAtIndex:0]];
        NSDictionary* pathRow=Row(SPDFPropertiesSections(NULL,longPath,longPath,0,0,0,nil),@"Location");
        NSTextField* pathField=[[SPDFPropertiesPanelController new] valueFieldForRow:pathRow];
        Check([pathField.stringValue isEqual:longPath] && pathField.selectable && !pathField.editable &&
            pathField.maximumNumberOfLines==0 && !pathField.cell.truncatesLastVisibleLine &&
            pathField.lineBreakMode==NSLineBreakByCharWrapping,@"full path wraps without truncation and supports selection/copy");
        NSString* missing=[root stringByAppendingPathComponent:@"missing.pdf"];
        sections=SPDFPropertiesSections(NULL,missing,missing,0,0,0,nil);
        Check(Row(sections,@"Location") && Row(sections,@"Availability"),@"missing and unloaded tabs retain Properties");
        Check(!Row(sections,@"Pages") && !Row(sections,@"Text") && !Row(sections,@"Security"),@"unloaded content is not fabricated");
        NSString* png=[root stringByAppendingPathComponent:@"image.png"];
        NSBitmapImageRep* pixels=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:48 pixelsHigh:32
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:192 bitsPerPixel:32];
        memset(pixels.bitmapData,128,48*32*4);
        [[pixels representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:png atomically:YES];
        sections=SPDFPropertiesSections(NULL,png,png,0,0,0,nil);
        Check([Row(sections,@"Pixel dimensions")[@"value"] containsString:@"48 × 32"],@"image properties work without a loaded core document");
        Check(!Row(sections,@"Text") && !Row(sections,@"Annotations") && !Row(sections,@"Security"),@"pictures never request PDF/text stats");
        RenderPanel(sections,png,@"image",nil);
        Check(Row(SPDFPropertiesSections(NULL,png,png,0,0,0,@{@"aiAnalysis":ai}),@"Tags")!=nil,@"image properties accept cached AI metadata too");
        NSString* pdf=[root stringByAppendingPathComponent:@"sample.pdf"];
        CGRect bounds=CGRectMake(0,0,300,400);
        CGContextRef context=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:pdf],&bounds,NULL);
        CGPDFContextBeginPage(context,NULL); CGPDFContextEndPage(context); CGPDFContextClose(context); CGContextRelease(context);
        char error[512]; spdf_document* doc=spdf_open(pdf.UTF8String,error,sizeof(error)); Check(doc!=NULL,@"PDF fixture opens");
        sections=SPDFPropertiesSections(doc,pdf,pdf,0,2,3,nil);
        Check(Row(sections,@"Security") && [Row(sections,@"Annotations")[@"value"] isEqual:@"3"],@"PDF retains PDF-specific metadata");
        Check(Row(sections,@"Text") && Row(sections,@"Page size"),@"PDF retains text counting and page geometry"); spdf_close(doc);
        NSString* svg=[root stringByAppendingPathComponent:@"vector.svg"];
        [@"<svg xmlns='http://www.w3.org/2000/svg' width='100' height='200'><rect width='100' height='200'/></svg>"
            writeToFile:svg atomically:YES encoding:NSUTF8StringEncoding error:nil];
        doc=spdf_open(svg.UTF8String,error,sizeof(error)); Check(doc!=NULL,@"SVG fixture opens");
        sections=SPDFPropertiesSections(doc,svg,svg,0,0,0,nil);
        Check(Row(sections,@"Vector page size") && !Row(sections,@"Pixel dimensions") && !Row(sections,@"Text"),@"vector properties do not invent pixel resolution");spdf_close(doc);
        NSString* coordinator=[NSString stringWithContentsOfFile:[@(argv[1]) stringByAppendingPathComponent:@"portable/mac/ShenzhenPDFMac.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([coordinator containsString:@"[fileMenu addItemWithTitle:@\"Properties...\""] &&
            [coordinator containsString:@"if (action == @selector(showProperties:)) return [self selectedTab].path.length > 0;"],@"File menu enables Properties for every selected file");
        NSString* menu=[NSString stringWithContentsOfFile:[@(argv[1]) stringByAppendingPathComponent:@"portable/mac/SPDFMacContextMenuIntegration.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([menu containsString:@"properties.enabled = [self selectedTab].path.length > 0;"],@"context menu agrees with File menu");
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        puts("SPDFMacPropertiesModelTests passed");
    }
}
