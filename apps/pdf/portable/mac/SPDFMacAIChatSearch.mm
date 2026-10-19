#import "SPDFMacAIChatSearch.h"
BOOL SPDFMacAIChatHasTextMatch(NSDictionary* chat,NSString* query) {
    if (!query.length) return NO;
    for (NSDictionary* message in chat[@"messages"]) {
        if (![@[@"user",@"assistant"] containsObject:message[@"role"]]) continue;
        id text=message[@"content"];
        if ([text isKindOfClass:NSString.class] && [text rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound) return YES;
    }
    return NO;
}
@implementation SPDFMacAIChatSearch {
    __weak NSScrollView* _scroll;
    __weak NSStackView* _messages;
    NSArray<NSDictionary*>* _hits;
    NSInteger _index;
    NSUInteger _generation;
}
- (instancetype)initWithScrollView:(NSScrollView*)scroll messages:(NSStackView*)messages {
    if ((self=[super init])) { _scroll=scroll;_messages=messages; }
    return self;
}
- (void)updateQuery:(NSString*)query {
    ++_generation;
    for (NSDictionary* hit in _hits) {
        NSTextView* view=hit[@"view"];
        [view.layoutManager removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:[hit[@"range"] rangeValue]];
    }
    NSMutableArray* hits=[NSMutableArray array];
    if (query.length) for (NSView* row in _messages.arrangedSubviews) {
        if (![row isKindOfClass:NSTextView.class]) continue;
        NSTextView* view=(NSTextView*)row; NSRange rest=NSMakeRange(0,view.string.length),hit;
        while (rest.length && (hit=[view.string rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch range:rest]).location!=NSNotFound) {
            [hits addObject:@{@"view":view,@"range":[NSValue valueWithRange:hit]}];
            rest=NSMakeRange(NSMaxRange(hit),view.string.length-NSMaxRange(hit));
        }
    }
    _hits=hits;_index=0;[self reveal];
}
- (void)moveBy:(NSInteger)delta {
    if (!_hits.count) return;
    _index=(_index+delta+(NSInteger)_hits.count)%(NSInteger)_hits.count;[self reveal];
}
- (void)reveal {
    NSUInteger generation=++_generation;
    for (NSUInteger i=0;i<_hits.count;i++) {
        NSTextView* view=_hits[i][@"view"]; NSRange range=[_hits[i][@"range"] rangeValue];
        NSColor* color=[NSColor colorWithSRGBRed:.85 green:.62 blue:.12 alpha:i==(NSUInteger)_index ? .7 : .32];
        [view.layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:color forCharacterRange:range];
        view.needsDisplay=YES;
    }
    if (!_hits.count) return;
    // Row heights settle after stack layout. Resolve glyph geometry afterwards;
    // scrolling to the message's bounds leaves deep matches off-screen.
    [_scroll.superview layoutSubtreeIfNeeded];
    __weak SPDFMacAIChatSearch* weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        SPDFMacAIChatSearch* owner=weakSelf;
        if (!owner || generation!=owner->_generation || owner->_scroll.hiddenOrHasHiddenAncestor) return;
        [owner->_scroll.superview layoutSubtreeIfNeeded];
        [owner->_scroll.documentView layoutSubtreeIfNeeded];
        NSDictionary* hit=owner->_hits[(NSUInteger)owner->_index];NSTextView* view=hit[@"view"];
        [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
        NSRange glyphs=[view.layoutManager glyphRangeForCharacterRange:[hit[@"range"] rangeValue] actualCharacterRange:nil];
        if (!glyphs.length) return;
        NSRect rect=[view.layoutManager boundingRectForGlyphRange:NSMakeRange(glyphs.location,1) inTextContainer:view.textContainer];
        rect.origin.x+=view.textContainerOrigin.x;rect.origin.y+=view.textContainerOrigin.y;
        rect=[view convertRect:rect toView:owner->_scroll.documentView];
        CGFloat height=NSHeight(owner->_scroll.contentView.bounds);
        CGFloat y=MAX(0,MIN(NSMidY(rect)-height/2,NSHeight(owner->_scroll.documentView.bounds)-height));
        [owner->_scroll.contentView scrollToPoint:NSMakePoint(0,y)];
        [owner->_scroll reflectScrolledClipView:owner->_scroll.contentView];
    });
}
@end
