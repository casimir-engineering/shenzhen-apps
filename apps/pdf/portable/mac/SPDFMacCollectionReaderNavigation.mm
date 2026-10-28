#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionWindow.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacGroupActionButton.h"
#import <objc/runtime.h>

static char versionInfoKey, versionIndicatorKey, versionIndicatorRowKey, versionLocateKey, navigationGenerationKey;
@interface SPDFCollectionVersionPill : SPDFGroupActionButton
@property BOOL missing;
@property(copy) NSString* compactTitle;
@end
@implementation SPDFCollectionVersionPill
- (NSSize)intrinsicContentSize {
    return NSMakeSize(MIN(330,ceil([self.title sizeWithAttributes:@{NSFontAttributeName:self.font}].width)+22),24);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect bounds = NSInsetRect(self.bounds,.5,.5);
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:NSHeight(bounds)/2 yRadius:NSHeight(bounds)/2];
    NSColor* accent=self.missing ? SPDFCollectionColor(@"destructive") : SPDFCollectionColor(@"focus");
    [[accent colorWithAlphaComponent:self.highlighted ? .25 : .14] setFill]; [shape fill];
    [[accent colorWithAlphaComponent:.55] setStroke]; [shape stroke];
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter; style.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSDictionary* attributes = @{NSFontAttributeName:self.font,NSForegroundColorAttributeName:SPDFCollectionColor(@"text"),
                                 NSParagraphStyleAttributeName:style};
    CGFloat height = [self.title sizeWithAttributes:attributes].height;
    NSString* title = [self.title sizeWithAttributes:attributes].width > NSWidth(self.bounds)-20 ? self.compactTitle : self.title;
    [title drawInRect:NSMakeRect(10,(NSHeight(self.bounds)-height)/2,MAX(0,NSWidth(self.bounds)-20),height)
        withAttributes:attributes];
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:NSHeight(self.bounds)/2 yRadius:NSHeight(self.bounds)/2] fill];
}
@end
// Reader action chrome: the same quiet rounded surface as the zoom controls,
// with the shared full-bounds mouse tracking used by group actions.
@interface SPDFCollectionLocateButton : SPDFGroupActionButton
@end
@implementation SPDFCollectionLocateButton
- (NSSize)intrinsicContentSize { return NSMakeSize(64,24); }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    [[SPDFCollectionColor(@"text") colorWithAlphaComponent:self.highlighted ? .12 : .05] setFill]; [shape fill];
    [[SPDFCollectionColor(@"text") colorWithAlphaComponent:.09] setStroke]; [shape stroke];
    NSDictionary* attributes=@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:SPDFCollectionColor(@"text")};
    NSSize size=[self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(floor((NSWidth(self.bounds)-size.width)/2),floor((NSHeight(self.bounds)-size.height)/2)) withAttributes:attributes];
    if (self.window.firstResponder==self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState];
    }
}
@end
@implementation ShenzhenMacDelegate (SPDFMacCollectionReaderNavigation)
- (void)collectionNavigateDocument:(NSDictionary*)document version:(NSDictionary*)version
                             page:(NSUInteger)page query:(NSString*)query history:(BOOL)history {
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    NSUInteger generation = [objc_getAssociatedObject(self,&navigationGenerationKey) unsignedIntegerValue]+1;
    objc_setAssociatedObject(self,&navigationGenerationKey,@(generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (history) {
        version = [document[@"versions"] lastObject];
        for (NSDictionary* candidate in document[@"versions"])
            if ([candidate[@"id"] isEqual:document[@"latestVersionID"]]) { version = candidate; break; }
    }
    // Latest uses the live source when available; saved revisions open independent editable files.
    BOOL original = (history || SPDFCollectionVersionIsLatest(document,version)) && SPDFCollectionOriginalAvailable(document);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error = nil;
        NSURL* URL = original ? [NSURL fileURLWithPath:document[@"path"]] :
            [store editableVersionID:version[@"id"] documentID:document[@"id"] error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([objc_getAssociatedObject(self,&navigationGenerationKey) unsignedIntegerValue] != generation) return;
            if (!URL) { if (error) [self->_window presentError:error]; return; }
            [self collectionOpenPath:URL.path archived:!original];
            if (![[self selectedTab].path isEqual:URL.path]) return;
            [self->_window makeKeyAndOrderFront:nil];
            if (history) [self showCollectionHistory:nil];
            else [self collectionNavigateResult:@{@"page":@(page ? page-1 : 0),@"query":query ?: @""}
                path:URL.path attempts:100];
        });
    });
}
- (BOOL)collectionTabIsSavedVersion:(SPDFDocumentTab*)tab {
    return tab && objc_getAssociatedObject(tab,&versionInfoKey) != nil;
}
- (NSString*)collectionKnownDocumentPathForTab:(SPDFDocumentTab*)tab {
    NSDictionary* info = tab ? objc_getAssociatedObject(tab,&versionInfoKey) : nil;
    id path = [info[@"document"] isKindOfClass:NSDictionary.class] ? info[@"document"][@"path"] : nil;
    return [path isKindOfClass:NSString.class] ? path : nil;
}
- (void)collectionSetVersionInfo:(NSDictionary*)info forTab:(SPDFDocumentTab*)tab {
    if (!tab) return;
    objc_setAssociatedObject(tab,&versionInfoKey,info,OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self collectionUpdateVersionIndicator];
}
- (void)collectionRefreshVersionInfoForDocument:(NSDictionary*)document {
    if (![document[@"id"] length]) return;
    for (SPDFDocumentTab* tab in _tabs) {
        NSDictionary* info = objc_getAssociatedObject(tab,&versionInfoKey);
        if (![info[@"document"][@"id"] isEqual:document[@"id"]]) continue;
        NSDictionary* version = info[@"version"];
        for (NSDictionary* candidate in document[@"versions"])
            if ([candidate[@"id"] isEqual:version[@"id"]]) { version = candidate; break; }
        objc_setAssociatedObject(tab,&versionInfoKey,@{@"document":document,@"version":version ?: @{}},OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    [self collectionUpdateVersionIndicator];
}
- (void)collectionUpdateVersionIndicator {
    NSDictionary* info = objc_getAssociatedObject([self selectedTab],&versionInfoKey);
    SPDFCollectionVersionPill* pill = objc_getAssociatedObject(self,&versionIndicatorKey);
    NSStackView* row = objc_getAssociatedObject(self,&versionIndicatorRowKey);
    if (!info || !_toolbarSpacer) { pill.hidden = YES; row.hidden = YES; return; }
    if (!pill) {
        pill = [SPDFCollectionVersionPill new]; pill.bordered = NO;
        pill.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        pill.target = self; pill.action = @selector(collectionLocateFromIndicator:);
        pill.identifier = @"CollectionVersionIndicator";
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [pill.widthAnchor constraintLessThanOrEqualToConstant:330].active = YES;
        pill.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [pill.heightAnchor constraintEqualToConstant:24].active=YES;
        [pill setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton* locate=[SPDFCollectionLocateButton buttonWithTitle:@"Locate…" target:self action:@selector(collectionLocateFromIndicator:)];
        locate.bordered=NO; locate.font=[NSFont systemFontOfSize:12];
        locate.translatesAutoresizingMaskIntoConstraints=NO;
        [locate.widthAnchor constraintEqualToConstant:64].active=YES;
        [locate.heightAnchor constraintEqualToConstant:24].active=YES;
        locate.identifier=@"CollectionLocateDocument"; locate.accessibilityLabel=@"Locate original document";
        locate.toolTip=@"Find the missing original automatically or choose it manually";
        row=[NSStackView stackViewWithViews:@[pill,locate]]; row.spacing=6; row.identifier=@"CollectionVersionStatusRow";
        row.alignment=NSLayoutAttributeCenterY; row.translatesAutoresizingMaskIntoConstraints=NO;
        // Use the existing flexible gap, never a second status bar. The chrome
        // moves this gap alongside the tools when its existing rows wrap.
        [_toolbarSpacer addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.centerXAnchor constraintEqualToAnchor:_toolbarSpacer.centerXAnchor],
            [row.centerYAnchor constraintEqualToAnchor:_toolbarSpacer.centerYAnchor],
            [row.widthAnchor constraintLessThanOrEqualToAnchor:_toolbarSpacer.widthAnchor constant:-8]]];
        objc_setAssociatedObject(self,&versionIndicatorRowKey,row,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self,&versionLocateKey,locate,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self,&versionIndicatorKey,pill,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSDictionary* doc = info[@"document"], *version = info[@"version"];
    BOOL missing = !SPDFCollectionOriginalAvailable(doc);
    BOOL older = !SPDFCollectionVersionIsLatest(doc,version);
    NSDateFormatter* format = [NSDateFormatter new]; format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyy.MM.dd";
    NSString* date = [version[@"capturedAt"] isKindOfClass:NSNumber.class] ?
        [format stringFromDate:[NSDate dateWithTimeIntervalSince1970:[version[@"capturedAt"] doubleValue]]] : @"date unavailable";
    NSString* title = older ? [@"Older version — " stringByAppendingString:date] : @"Collection document";
    if (missing) title = [title stringByAppendingFormat:@" · %@", [doc[@"status"] isEqual:@"Original unavailable"] ? @"Original unavailable" : @"Original missing"];
    pill.compactTitle = missing ? ([doc[@"status"] isEqual:@"Original unavailable"] ? @"Original unavailable" : @"Original missing") : older ? @"Older version" : @"Collection document";
    pill.title = title; [pill invalidateIntrinsicContentSize]; pill.accessibilityLabel = title; pill.hidden = NO;
    pill.missing=missing; pill.needsDisplay=YES; row.hidden=NO;
    [objc_getAssociatedObject(self,&versionLocateKey) setHidden:!missing];
    pill.enabled = missing;
    pill.toolTip = missing ? @"This saved copy has no available original. Click to locate it." : @"Editable Collection document; previous versions remain in History";
}
- (void)collectionLocateFromIndicator:(id)sender {
    (void)sender;
    NSDictionary* info = objc_getAssociatedObject([self selectedTab],&versionInfoKey);
    NSDictionary* doc = info[@"document"];
    if (!doc || SPDFCollectionOriginalAvailable(doc)) return;
    [self showCollectionRecovery:nil];
}
@end
