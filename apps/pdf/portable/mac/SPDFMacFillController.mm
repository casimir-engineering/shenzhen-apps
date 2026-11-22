#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillEditor.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacModels.h"

#import <objc/runtime.h>

static char kSPDFFillSessionKey;

@implementation SPDFMacFillController {
    __weak id<SPDFMacFillHost> _host;
    NSString* _docKey;
    NSMutableDictionary<NSNumber*, NSArray<SPDFFillField*>*>* _fields;
    NSMutableDictionary<NSNumber*, NSArray<SPDFFillItem*>*>* _items;
    NSMutableDictionary<NSNumber*, SPDFFillSnapPage*>* _geometry;
    NSMutableSet<NSNumber*>* _geometryLoading;
    NSString* _geometryPath;
    NSUInteger _geometryGeneration;
    dispatch_queue_t _workerQueue;
    spdf_document* _workerDocument;  // touched on _workerQueue only
    NSString* _workerPath;           // idem
    NSMutableSet<NSValue*>* _tokens;  // render tokens of geometry loads in flight
    NSMutableDictionary<NSString*, SPDFMacSignature*>* _usedSignatures;
    CGFloat _topReserve;  // room kept above the first page while the palette shows
}

@synthesize usedSignatures = _usedSignatures;

- (instancetype)initWithHost:(id<SPDFMacFillHost>)host {
    if ((self = [super init])) {
        _host = host;
        _fields = [NSMutableDictionary dictionary];
        _items = [NSMutableDictionary dictionary];
        _geometry = [NSMutableDictionary dictionary];
        _geometryLoading = [NSMutableSet set];
        _tokens = [NSMutableSet set];
        _usedSignatures = [NSMutableDictionary dictionary];
        _workerQueue = dispatch_queue_create("com.intuition.shenzhenpdf.fill-sign",
                                             dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                     QOS_CLASS_UTILITY, 0));
    }
    return self;
}

- (void)dealloc {
    [self cancelGeometryLoads];
    dispatch_queue_t queue = _workerQueue;
    spdf_document* worker = _workerDocument;
    if (queue && worker) dispatch_async(queue, ^{ spdf_close(worker); });
}

- (id<SPDFMacFillHost>)host {
    return _host;
}

#pragma mark - Sessions

- (SPDFFillSession*)session {
    SPDFDocumentTab* tab = [_host fillTab];
    if (!tab) return nil;
    SPDFFillSession* session = objc_getAssociatedObject(tab, &kSPDFFillSessionKey);
    if (!session) {
        session = [SPDFFillSession new];
        objc_setAssociatedObject(tab, &kSPDFFillSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return session;
}

+ (SPDFFillSession*)existingSessionForTab:(SPDFDocumentTab*)tab {
    return tab ? objc_getAssociatedObject(tab, &kSPDFFillSessionKey) : nil;
}

- (BOOL)isShowing {
    SPDFDocumentTab* tab = [_host fillTab];
    SPDFFillSession* session = tab ? objc_getAssociatedObject(tab, &kSPDFFillSessionKey) : nil;
    return session.on && ![_host fillHidden] && [_host fillDocument];
}

- (void)setOn:(BOOL)on {
    SPDFFillSession* session = [self session];
    if (!session) return;
    if (!on) {
        [self endInteraction];
        session.dismissed = YES;
        session.pickedSignature = nil;
    }
    session.on = on;
    if (on) session.markCross = NO;  // a check each time the palette opens
    [self refreshChrome];
}

- (void)ensureViews {
    NSScrollView* scrollView = [_host fillScrollView];
    if (!scrollView) return;
    if (!self.overlay) {
        self.overlay = [[SPDFMacFillOverlayView alloc] initWithFrame:scrollView.contentView.frame];
        self.overlay.controller = self;
    }
    if (self.overlay.superview != scrollView) [self.overlay attachToScrollView:scrollView];
    if (!self.palette) {
        self.palette = [[SPDFMacFillPalette alloc] initWithController:self];
    }
    if (self.palette.superview != [_host fillContainer]) [self.palette attachToContainer:[_host fillContainer]
                                                                            aboveView:scrollView];
}

- (void)refreshChrome {
    BOOL showing = [self isShowing];
    if (showing) [self ensureViews];
    self.overlay.hidden = !showing;
    self.palette.hidden = !showing;
    if (showing) {
        [self.palette updateFromSession:[self session] progress:[self progressText] note:[self paletteNote]];
        // Room above the first page for the palette, so the top of the page can be seen. It only grows while the
        // palette shows, so the pages don't jump when its one-line hint goes away.
        [self.palette layoutSubtreeIfNeeded];
        _topReserve = MAX(_topReserve, ceil(self.palette.fittingSize.height) + 18);
    } else {
        _topReserve = 0;
    }
    [_host fillSetPageTopReserve:_topReserve];
    if (showing) {
        [self.overlay refresh];
        [self.overlay takeKeysFromPages];
    } else {
        [self.overlay clearTransientState];
    }
    [_host fillStateDidChange];
}

- (NSString*)paletteNote {
    // No-break spaces keep "File ▸ Save As…" on one line.
    return [_host fillIsEditedCopy] ? @"You're filling in a copy, because the original can't be changed. Choose "
                                      @"File\u00a0▸\u00a0Save\u00a0As… to put it where you want."
                                    : nil;
}

- (void)activeDocumentChanged {
    NSString* key = [self currentDocKey];
    if (![key isEqual:_docKey]) {
        [self dropInteraction];  // what was typed or drawn went into the file before the document was left
        [self discardPendingStrokes];
        [self.overlay dropDrawingHolds];
        [self dropCaches];
        _docKey = key;
        _topReserve = 0;  // the room above the pages fits this document's palette
    }
    [self refreshChrome];
}

- (void)endInteraction {
    [self.editor commitAndClose];
    [self writePendingStrokes];
    [self dropInteraction];
}

- (void)dropInteraction {
    [self.editor close];
    self.editor = nil;
    [self.overlay clearTransientState];
    SPDFFillSession* session = [SPDFMacFillController existingSessionForTab:[_host fillTab]];
    if (session.tool == SPDFFillToolSignature) {
        session.tool = SPDFFillToolText;
        session.pickedSignature = nil;
    }
}

- (void)flushEditor {
    [self.editor flushIfNeeded];
}

#pragma mark - Caches

- (NSString*)currentDocKey {
    spdf_document* doc = [_host fillDocument];
    return doc ? [NSString stringWithFormat:@"%p|%@", (void*)doc, [_host fillPath] ?: @""] : @"";
}

- (BOOL)checkDocKey {
    NSString* key = [self currentDocKey];
    if ([key isEqual:_docKey]) return key.length > 0;
    [self dropCaches];
    _docKey = key;
    return key.length > 0;
}

- (void)dropCaches {
    [_fields removeAllObjects];
    [_items removeAllObjects];
    NSString* working = [_host fillWorkingPath];
    if (![working isEqual:_geometryPath]) {
        [self cancelGeometryLoads];
        [_geometry removeAllObjects];
        [_geometryLoading removeAllObjects];
        _geometryGeneration++;
        _geometryPath = [working copy];
    }
}

- (void)invalidatePage:(NSInteger)page {
    [_fields removeObjectForKey:@(page)];
    [_items removeObjectForKey:@(page)];
}

- (NSInteger)pageCount {
    spdf_document* doc = [_host fillDocument];
    return doc ? spdf_page_count(doc) : 0;
}

- (NSArray<SPDFFillField*>*)fieldsOnPage:(NSInteger)page {
    if (![self checkDocKey] || page < 0 || page >= [self pageCount]) return @[];
    SPDFFillSession* session = [self session];
    // A PDF without fields to fill has none on any page: no page is loaded for them.
    if (session.hasSummary && session.summary.fillable_count == 0 && session.summary.signed_count == 0) return @[];
    NSArray* cached = _fields[@(page)];
    if (cached) return cached;
    spdf_form_widgets widgets;
    memset(&widgets, 0, sizeof(widgets));
    char err[512];
    NSArray* fields = @[];
    if (spdf_form_load_page_widgets([_host fillDocument], (int)page, &widgets, err, sizeof(err)))
        fields = [SPDFFillField fieldsFromWidgets:&widgets];
    spdf_free_form_widgets(&widgets);
    _fields[@(page)] = fields;
    return fields;
}

- (NSArray<SPDFFillItem*>*)itemsOnPage:(NSInteger)page {
    if (![self checkDocKey] || page < 0 || page >= [self pageCount]) return @[];
    NSArray* cached = _items[@(page)];
    if (cached) return cached;
    spdf_fill_items items;
    memset(&items, 0, sizeof(items));
    char err[512];
    NSArray* found = @[];
    if (spdf_fill_load_items([_host fillDocument], (int)page, &items, err, sizeof(err)))
        found = [SPDFFillItem itemsFromCore:&items];
    spdf_free_fill_items(&items);
    _items[@(page)] = found;
    return found;
}

- (const spdf_snap_geometry*)geometryForPage:(NSInteger)page {
    if (![self checkDocKey]) return NULL;
    SPDFFillSnapPage* loaded = _geometry[@(page)];
    if (loaded) return loaded.geometry;
    if ([_geometryLoading containsObject:@(page)]) return NULL;
    [_geometryLoading addObject:@(page)];
    NSString* path = [[_host fillWorkingPath] copy];
    NSUInteger generation = _geometryGeneration;
    spdf_render_token* token = spdf_render_token_new();
    NSValue* tokenValue = [NSValue valueWithPointer:token];
    @synchronized(_tokens) { [_tokens addObject:tokenValue]; }
    __weak SPDFMacFillController* weakSelf = self;
    id<SPDFMacFillHost> host = _host;
    dispatch_async(_workerQueue, ^{
      SPDFMacFillController* strongSelf = weakSelf;
      spdf_snap_geometry geometry;
      memset(&geometry, 0, sizeof(geometry));
      int result = 0;
      if (strongSelf) {
          char err[512];
          if (![strongSelf->_workerPath isEqual:path]) {
              if (strongSelf->_workerDocument) spdf_close(strongSelf->_workerDocument);
              strongSelf->_workerDocument = [host fillOpenReadDocumentAtPath:path error:err length:sizeof(err)];
              strongSelf->_workerPath = strongSelf->_workerDocument ? [path copy] : nil;
          }
          if (strongSelf->_workerDocument)
              result = spdf_snap_geometry_load(strongSelf->_workerDocument, (int)page, 50000, token, &geometry, err,
                                               sizeof(err));
          @synchronized(strongSelf->_tokens) { [strongSelf->_tokens removeObject:tokenValue]; }
      }
      spdf_render_token_free(token);
      SPDFFillSnapPage* holder = result == 1 ? [[SPDFFillSnapPage alloc] initTakingGeometry:geometry] : nil;
      if (result != 1) spdf_snap_geometry_free(&geometry);
      dispatch_async(dispatch_get_main_queue(), ^{
        SPDFMacFillController* me = weakSelf;
        if (!me || generation != me->_geometryGeneration) return;
        [me->_geometryLoading removeObject:@(page)];
        // A failed read leaves an empty geometry, so the page places freely instead of asking again on every move.
        spdf_snap_geometry empty;
        memset(&empty, 0, sizeof(empty));
        me->_geometry[@(page)] = holder ?: [[SPDFFillSnapPage alloc] initTakingGeometry:empty];
        [me.overlay refresh];
      });
    });
    return NULL;
}

- (void)cancelGeometryLoads {
    @synchronized(_tokens) {
        for (NSValue* value in _tokens) spdf_render_token_cancel((spdf_render_token*)value.pointerValue);
    }
}

#pragma mark - Progress

- (NSString*)progressText {
    SPDFFillSession* session = [self session];
    if (!session.isForm) return nil;
    NSInteger pages = [self pageCount];
    if (pages <= 0 || pages > 60) return nil;  // counting would read every page of a long document
    NSMutableDictionary<NSNumber*, NSNumber*>* filledByGroup = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* requiredGroups = [NSMutableSet set];
    for (NSInteger page = 0; page < pages; ++page)
        for (SPDFFillField* field in [self fieldsOnPage:page]) {
            if (field.readOnly || field.hidden || field.type == SPDF_FIELD_CHECKBOX) continue;
            NSNumber* group = @(field.groupID ?: field.objectNumber);
            BOOL filled = field.filled || [filledByGroup[group] boolValue];
            filledByGroup[group] = @(filled);
            if (field.flags & SPDF_FIELD_REQUIRED) [requiredGroups addObject:group];
        }
    if (!filledByGroup.count) return nil;
    NSUInteger filled = 0;
    BOOL requiredDone = requiredGroups.count > 0;
    for (NSNumber* group in filledByGroup) {
        if ([filledByGroup[group] boolValue]) filled++;
        else if ([requiredGroups containsObject:group]) requiredDone = NO;
    }
    if (requiredDone && filled < filledByGroup.count) return @"All required fields filled";
    return [NSString stringWithFormat:@"%lu of %lu filled", (unsigned long)filled, (unsigned long)filledByGroup.count];
}

@end
