// Assistant answers in the transcript (SPDFMacAIChatView.h § Answers): the answer's text with links to documents that
// can no longer be opened shown as plain words, and the source card when one document backs the answer.
#import "SPDFMacAIChatViewInternal.h"
#import "SPDFMacAICitations.h"
#import "SPDFMacAISourceCardView.h"

@implementation SPDFMacAIChatView (Answers)
- (void)addAnswer:(NSString*)text {
    BOOL (^available)(NSURL*) = self.documentLinkAvailable;
    NSDictionary* shown = SPDFMacAIAnswerPresentation(text, available);
    NSView* before = _messages.arrangedSubviews.lastObject;
    [self addText:shown[@"text"] role:@"Assistant"];
    NSView* message = _messages.arrangedSubviews.lastObject;
    NSDictionary* source = shown[@"source"];
    if (!source || message == before) return;
    __weak __typeof__(self) weakSelf = self;
    SPDFMacAISourceCardView* card = [[SPDFMacAISourceCardView alloc] initWithSource:source open:^(NSURL* link) {
        __typeof__(self) view = weakSelf;
        if (view.openLink) view.openLink(link);
    }];
    [_messages setCustomSpacing:8 afterView:message];
    [_messages addArrangedSubview:card];
    [card.widthAnchor constraintEqualToAnchor:_messages.widthAnchor].active = YES;
    [_messages setCustomSpacing:16 afterView:card];
    if (!self.sourceThumbnail) return;
    __weak SPDFMacAISourceCardView* weakCard = card;
    self.sourceThumbnail(card.link, card.page, ^(NSImage* image) { weakCard.thumbnail = image; });
}
- (void)redisplayAnswers { [self redisplayKeepingPosition]; }
@end
