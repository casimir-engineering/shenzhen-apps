#import "SPDFMacFindFailure.h"
#import <objc/runtime.h>
@interface ShenzhenMacDelegate (FindFailureHost)
- (BOOL)hasActiveDocument;
- (void)invalidateFindMarkers;
@end
static char findFailureKey;
static char findLiveCountKey;
static char findProgressLineKey;

// The thin line under the search field that fills as a search covers the
// document.
@interface SPDFFindProgressLine : NSView
@property(nonatomic) double fraction;
@end
@implementation SPDFFindProgressLine
- (void)setFraction:(double)fraction {
    _fraction = MAX(0.0, MIN(1.0, fraction));
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.8] setFill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds) * _fraction, NSHeight(self.bounds)));
}
@end

@implementation ShenzhenMacDelegate (SPDFMacFindFailure)
- (NSString*)findFailureMessage { return objc_getAssociatedObject(self,&findFailureKey); }
- (void)setFindFailureMessage:(NSString*)message {
    objc_setAssociatedObject(self,&findFailureKey,message,OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSUInteger)findLiveMatchCount { return [objc_getAssociatedObject(self,&findLiveCountKey) unsignedIntegerValue]; }
- (void)setFindLiveMatchCount:(NSUInteger)count {
    objc_setAssociatedObject(self,&findLiveCountKey,@(count),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)setFindProgress:(double)fraction {
    SPDFFindProgressLine* line = objc_getAssociatedObject(self,&findProgressLineKey);
    NSView* host = _searchField.superview;
    if (!host) return;
    if (line.superview != host) {
        [line removeFromSuperview];
        line = [[SPDFFindProgressLine alloc] initWithFrame:NSZeroRect];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:_searchField.leadingAnchor constant:4],
            [line.trailingAnchor constraintEqualToAnchor:_searchField.trailingAnchor constant:-4],
            [line.bottomAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:1],
            [line.heightAnchor constraintEqualToConstant:2],
        ]];
        objc_setAssociatedObject(self,&findProgressLineKey,line,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    line.hidden = fraction >= 1.0 || fraction < 0.0;
    line.fraction = fraction;
}
- (void)updateFindCountLabel {
    if (!_findCountLabel) return;
    if (![self hasActiveDocument] || _searchField.stringValue.length == 0) {
        _findCountLabel.stringValue = @"";
    } else if (_findSearchInProgress) {
        NSUInteger found = self.findLiveMatchCount;
        _findCountLabel.stringValue =
            found == 0 ? @"..."
                       : [NSString stringWithFormat:@"%@ %@…",
                                                    [NSNumberFormatter localizedStringFromNumber:@(found)
                                                                                     numberStyle:NSNumberFormatterDecimalStyle],
                                                    found == 1 ? @"match" : @"matches"];
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
    BOOL hasMatches = _findMatches.count > 0 || (_findSearchInProgress && self.findLiveMatchCount > 0);
    BOOL hasQuery = _searchField.stringValue.length > 0;
    _findSegments.hidden = !hasQuery;
    _findCountLabel.hidden = !hasQuery;
    [_findSegments setEnabled:hasMatches forSegment:0];
    [_findSegments setEnabled:hasMatches forSegment:1];
    [self updateFindCountLabel];
    [self invalidateFindMarkers];
}

@end
