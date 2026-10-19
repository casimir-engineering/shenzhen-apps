#import "SPDFMacInactivePreload.h"

typedef NS_ENUM(NSInteger, SPDFMacInactivePreloadState) {
    SPDFMacInactivePreloadStatePreparing = 0,
    SPDFMacInactivePreloadStateOpening,
    SPDFMacInactivePreloadStateBackgroundWork,
    SPDFMacInactivePreloadStateFinished,
    SPDFMacInactivePreloadStateConsumed,
};

@implementation SPDFMacInactivePreload {
    SPDFMacInactivePreloadState _state;
    BOOL _foregroundClaimed;
    BOOL _groupFinished;
    void* _document;
    NSDictionary* _attributes;
    NSArray* _pages;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _completionGroup = dispatch_group_create();
    dispatch_group_enter(_completionGroup);
    return self;
}

- (BOOL)isForegroundClaimed {
    @synchronized(self) {
        return _foregroundClaimed;
    }
}

- (BOOL)workerMayBeginOpen {
    @synchronized(self) {
        if (_state != SPDFMacInactivePreloadStatePreparing || _foregroundClaimed) return NO;
        _state = SPDFMacInactivePreloadStateOpening;
        return YES;
    }
}

- (BOOL)workerMayContinueWithDocument:(void*)document attributes:(NSDictionary*)attributes {
    @synchronized(self) {
        _document = document;
        _attributes = [attributes copy];
        if (_foregroundClaimed) return NO;
        _state = SPDFMacInactivePreloadStateBackgroundWork;
        return YES;
    }
}

- (void)finishLocked {
    if (_state != SPDFMacInactivePreloadStateConsumed) _state = SPDFMacInactivePreloadStateFinished;
    if (_groupFinished) return;
    _groupFinished = YES;
    dispatch_group_leave(_completionGroup);
}

- (void)workerFinishedWithPages:(NSArray*)pages {
    @synchronized(self) {
        _pages = [pages copy];
        [self finishLocked];
    }
}

- (BOOL)workerFinishedCancelledDocument:(void*)document attributes:(NSDictionary*)attributes {
    @synchronized(self) {
        if (_foregroundClaimed) {
            _document = document;
            _attributes = [attributes copy];
        } else {
            _state = SPDFMacInactivePreloadStateConsumed;
        }
        BOOL retained = _foregroundClaimed;
        [self finishLocked];
        return retained;
    }
}

- (void)workerFinishedWithoutDocument {
    @synchronized(self) {
        _document = NULL;
        _attributes = nil;
        _pages = nil;
        [self finishLocked];
    }
}

- (BOOL)claimForForeground {
    @synchronized(self) {
        if (_state == SPDFMacInactivePreloadStateConsumed) return NO;
        _foregroundClaimed = YES;
        if (_state == SPDFMacInactivePreloadStatePreparing) [self finishLocked];
        return YES;
    }
}

- (void)discardForegroundDocumentWithHandler:(void (^)(void*))handler {
    dispatch_group_notify(_completionGroup, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        handler([self takeForegroundDocumentWithAttributes:nil]);
    });
}

- (void*)takeForegroundDocumentWithAttributes:(NSDictionary**)attributes {
    dispatch_group_wait(_completionGroup, DISPATCH_TIME_FOREVER);
    @synchronized(self) {
        if (!_foregroundClaimed || _state == SPDFMacInactivePreloadStateConsumed) return NULL;
        void* document = _document;
        if (attributes) *attributes = _attributes;
        _document = NULL;
        _pages = nil;
        _state = SPDFMacInactivePreloadStateConsumed;
        return document;
    }
}

- (void*)takeBackgroundDocumentWithAttributes:(NSDictionary**)attributes pages:(NSArray**)pages {
    @synchronized(self) {
        if (_foregroundClaimed || _state != SPDFMacInactivePreloadStateFinished) return NULL;
        void* document = _document;
        if (attributes) *attributes = _attributes;
        if (pages) *pages = _pages;
        _document = NULL;
        _pages = nil;
        _state = SPDFMacInactivePreloadStateConsumed;
        return document;
    }
}

@end
