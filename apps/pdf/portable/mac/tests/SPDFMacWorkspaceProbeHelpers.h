#pragma once
// Shared assertions and offscreen control inspection for the production reader probe.
static void Check(BOOL ok, NSString* message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); failures++; }
}
static void VisibleControls(NSView* view,NSMutableArray<NSControl*>* controls) {
    if(view.hidden) return;
    if([view isKindOfClass:NSControl.class]) { [controls addObject:(id)view]; return; }
    for(NSView* child in view.subviews) VisibleControls(child,controls);
}
static NSTableView* FindHistoryTable(NSView* view) {
    if ([view isKindOfClass:NSTableView.class] && [view.accessibilityLabel isEqual:@"Saved document versions"]) return (id)view;
    for (NSView* child in view.subviews) { NSTableView* found=FindHistoryTable(child); if(found) return found; }
    return nil;
}
static double Luma(NSColor* color) {
    color=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    double v[3]={color.redComponent,color.greenComponent,color.blueComponent};
    for(int i=0;i<3;i++) v[i]=v[i]<=.04045 ? v[i]/12.92 : pow((v[i]+.055)/1.055,2.4);
    return .2126*v[0]+.7152*v[1]+.0722*v[2];
}
static void CheckIconReadability(NSControl* control) {
    if(NSWidth(control.bounds)<16 || NSHeight(control.bounds)<16) return;
    BOOL enabled=control.enabled;
    for(NSNumber* state in @[@YES,@NO]) {
        control.enabled=state.boolValue;
        [control.effectiveAppearance performAsCurrentDrawingAppearance:^{
            NSInteger w=ceil(NSWidth(control.bounds)),h=ceil(NSHeight(control.bounds));
            NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            NSColor* background=SPDFCollectionColor(@"window"); [background setFill]; NSRectFill(control.bounds);
            [control drawRect:control.bounds]; [NSGraphicsContext restoreGraphicsState];
            NSUInteger visible=0; double base=Luma(background);
            // Ignore bezels: measure only the central glyph region.
            for(NSInteger y=MAX(0,h/2-8);y<MIN(h,h/2+8);y++) for(NSInteger x=MAX(0,w/2-8);x<MIN(w,w/2+8);x++) {
                double pixel=Luma([bitmap colorAtX:x y:y]);
                if((MAX(base,pixel)+.05)/(MIN(base,pixel)+.05)>=3) visible++;
            }
            Check(visible>=8,[NSString stringWithFormat:@"%@ %@ glyph remains readable (3:1 pixels=%lu)",
                control.accessibilityLabel ?: NSStringFromClass(control.class),state.boolValue ? @"enabled" : @"disabled",(unsigned long)visible]);
        }];
    }
    control.enabled=enabled;
}
