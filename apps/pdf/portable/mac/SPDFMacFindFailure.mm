#import "SPDFMacFindFailure.h"
#import <objc/runtime.h>
@interface ShenzhenMacDelegate (FindFailureHost)
- (BOOL)hasActiveDocument;
- (void)invalidateFindMarkers;
@end
static char findFailureKey;
@implementation ShenzhenMacDelegate (SPDFMacFindFailure)
- (NSString*)findFailureMessage { return objc_getAssociatedObject(self,&findFailureKey); }
- (void)setFindFailureMessage:(NSString*)message {
    objc_setAssociatedObject(self,&findFailureKey,message,OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void)updateFindCountLabel {
    if (!_findCountLabel) return;
    if (![self hasActiveDocument] || _searchField.stringValue.length == 0) {
        _findCountLabel.stringValue = @"";
    } else if (_findSearchInProgress) {
        _findCountLabel.stringValue = @"...";
    } else if (self.findFailureMessage.length) {
        _findCountLabel.stringValue = @"Error";
    } else if (_findMatches.count == 0) {
        _findCountLabel.stringValue = @"0 / 0";
    } else {
        NSInteger current = _findMatchIndex >= 0 ? _findMatchIndex + 1 : 1;
        _findCountLabel.stringValue =
            [NSString stringWithFormat:@"%ld / %ld", (long)current, (long)_findMatches.count];
    }
}

- (void)updateFindControls {
    BOOL hasMatches = _findMatches.count > 0;
    BOOL hasQuery = _searchField.stringValue.length > 0;
    _findSegments.hidden = !hasQuery;
    _findCountLabel.hidden = !hasQuery;
    [_findSegments setEnabled:hasMatches forSegment:0];
    [_findSegments setEnabled:hasMatches forSegment:1];
    [self updateFindCountLabel];
    [self invalidateFindMarkers];
}

@end
