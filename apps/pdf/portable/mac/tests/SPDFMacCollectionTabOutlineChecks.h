static void check_collection_copy_outline(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,42)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    SPDFGroupTestStrip* strip = [[SPDFGroupTestStrip alloc] initWithFrame:window.contentView.bounds];
    [window.contentView addSubview:strip];
    SPDFTabGroup* orange = [SPDFTabGroup groupWithColor:@"Orange"];
    SPDFGroupFakeTab* copy = tab(@"Notes",orange); copy.readOnly = YES;
    strip.tabs = (id)@[copy];
    for (NSString* appearanceName in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
        strip.appearance = [NSAppearance appearanceNamed:appearanceName];
        for (NSNumber* selected in @[@(-1),@0]) {
            strip.selectedIndex = selected.integerValue; copy.collectionVersionLabel = nil;
            NSRect frame = [strip groupedRectForTabAtIndex:0];
            NSBitmapImageRep* ordinary = [strip bitmapImageRepForCachingDisplayInRect:strip.bounds];
            [strip cacheDisplayInRect:strip.bounds toBitmapImageRep:ordinary];
            copy.collectionVersionLabel = @"Notes";
            NSBitmapImageRep* archived = [strip bitmapImageRepForCachingDisplayInRect:strip.bounds];
            [strip cacheDisplayInRect:strip.bounds toBitmapImageRep:archived];
            CGFloat scale = archived.pixelsWide/NSWidth(strip.bounds);
            NSInteger y = (NSInteger)((NSMinY(frame)+1)*scale), changed = 0;
            for (NSInteger x=(NSInteger)((NSMinX(frame)+10)*scale); x<(NSMaxX(frame)-10)*scale; x++) {
                NSColor* a = [[ordinary colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                NSColor* b = [[archived colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                if (fabs(a.redComponent-b.redComponent)+fabs(a.greenComponent-b.greenComponent)+
                    fabs(a.blueComponent-b.blueComponent)+fabs(a.alphaComponent-b.alphaComponent)>.08) changed++;
            }
            expect(changed>20,@"saved copies keep a visible pale rim distinct from an ordinary Orange group in both themes");
        }
    }
}
