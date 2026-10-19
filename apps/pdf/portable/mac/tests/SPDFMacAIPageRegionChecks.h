// Headless fixtures use actual renderer pixels, including the top-left crop convention.
static void PageRegionChecks(NSString* root) {
    NSString* path=[root stringByAppendingPathComponent:@"quadrants.pdf"];
    CGRect media=CGRectMake(0,0,200,100);
    CGContextRef pdf=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&media,NULL);
    CGPDFContextBeginPage(pdf,NULL);
    CGContextSetRGBFillColor(pdf,1,0,0,1); CGContextFillRect(pdf,CGRectMake(0,50,100,50));
    CGContextSetRGBFillColor(pdf,0,1,0,1); CGContextFillRect(pdf,CGRectMake(100,50,100,50));
    CGContextSetRGBFillColor(pdf,0,0,1,1); CGContextFillRect(pdf,CGRectMake(0,0,100,50));
    CGContextSetRGBFillColor(pdf,1,1,0,1); CGContextFillRect(pdf,CGRectMake(100,0,100,50));
    CGPDFContextEndPage(pdf); CGPDFContextClose(pdf); CGContextRelease(pdf);
    NSProgress* progress=[NSProgress progressWithTotalUnitCount:1];
    NSDictionary* full=SPDFAIPagePreviewWithOptions(path,NO,1,@{@"maxDimension":@600},progress,nil);
    Check(full && [full[@"pixelWidth"] unsignedIntegerValue]<=600 && [full[@"pixelHeight"] unsignedIntegerValue]<=300,
        "full-page image obeys requested dimensions");
    NSBitmapImageRep* all=[[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:full[@"path"]]];
    NSColor* top=[[all colorAtX:50 y:50] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Check(top.redComponent>.95 && top.blueComponent<.05,"page images keep original red colors");
    for (NSUInteger quadrant=0;quadrant<4;quadrant++) {
        NSDictionary* region=@{@"x":@(quadrant%2*.5),@"y":@(quadrant/2*.5),@"width":@.5,@"height":@.5};
        NSDictionary* crop=SPDFAIPagePreviewWithOptions(path,NO,1,@{@"region":region,@"maxDimension":@1200},progress,nil);
        Check(crop && [crop[@"region"] isEqual:region],"crop coordinates are returned unchanged");
        NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:crop[@"path"]]];
        Check(bitmap.pixelsWide>1100 && bitmap.pixelsWide<=1200 && bitmap.pixelsHigh<=600,
            "small regions receive independent detail budget without a full-page raster");
        NSColor* color=[[bitmap colorAtX:bitmap.pixelsWide/2 y:bitmap.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        Check((color.redComponent>.95)==(quadrant==0 || quadrant==3) &&
            (color.greenComponent>.95)==(quadrant==1 || quadrant==3) &&
            (color.blueComponent>.95)==(quadrant==2),"normalized crop selects the correct page quadrant");
        [NSFileManager.defaultManager removeItemAtPath:[crop[@"path"] stringByDeletingLastPathComponent] error:nil];
    }
    NSArray* invalid=@[@{@"region":@{@"x":@-.1,@"y":@0,@"width":@.5,@"height":@.5}},
        @{@"region":@{@"x":@.9,@"y":@0,@"width":@.5,@"height":@.5}},
        @{@"region":@{@"x":@0,@"y":@0,@"width":@0,@"height":@1}},
        @{@"region":@{@"x":@0,@"y":@0,@"width":@1}}, @{@"region":@[@0,@0,@1,@1]},
        @{@"region":@{@"x":@(NAN),@"y":@0,@"width":@1,@"height":@1}},
        @{@"maxDimension":@2401},@{@"maxDimension":@128},@{@"maxDimension":@256.5},@{@"maxDimension":@"1600"}];
    for (NSDictionary* options in invalid)
        Check(!SPDFAIPagePreviewWithOptions(path,NO,1,options,progress,nil),"malformed or overbudget region rejected");
    Check(!SPDFAIPagePreviewWithOptions(path,NO,2,nil,progress,nil),"out-of-range image page rejected");
    Check(!SPDFAIPagePreviewForCandidateWithOptions(@{@"readPath":path,@"revision":@"old"},1,nil,progress,nil),
        "PDF stale revision rejected before rendering");
    [progress cancel];
    Check(!SPDFAIPagePreviewWithOptions(path,NO,1,nil,progress,nil),"cancelled image request produces no artifact");
    NSString* markdown=[root stringByAppendingPathComponent:@"image-region.md"];
    [@"# Region title\n\nParagraph with original text." writeToFile:markdown atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* text=SPDFAIPagePreviewWithOptions(markdown,NO,1,
        @{@"region":@{@"x":@0,@"y":@0,@"width":@1,@"height":@.25},@"maxDimension":@800},nil,nil);
    Check(text && [text[@"pixelWidth"] unsignedIntegerValue]==800 && [text[@"pixelHeight"] unsignedIntegerValue]<400,
        "Markdown crops render directly at the requested detail");
    NSBitmapImageRep* textImage=[[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:text[@"path"]]];
    NSUInteger ink=0;
    for (NSInteger y=0;y<textImage.pixelsHigh;y+=4) for (NSInteger x=0;x<textImage.pixelsWide;x+=4) {
        NSColor* pixel=[[textImage colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (pixel.redComponent<.5) ink++;
    }
    Check(ink>15,"top-left Markdown crop contains the heading and paragraph, not blank bottom margin");
    for (NSDictionary* result in @[full,text])
        [NSFileManager.defaultManager removeItemAtPath:[result[@"path"] stringByDeletingLastPathComponent] error:nil];
}
