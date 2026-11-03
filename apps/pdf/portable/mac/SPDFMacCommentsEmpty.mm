// The Comments panel with no card to show (SPDFMacCommentCards.h). Moved out of SPDFMacCommentCards.mm whole.
#import "SPDFMacCommentCards.h"
#import "SPDFMacCollectionStyle.h"

static NSString* Text(NSDictionary* item, NSString* key) {
    id value = item[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static CGFloat Measure(NSAttributedString* text, CGFloat width) {
    if (!text.length) return 0;
    NSRect r = [text boundingRectWithSize:NSMakeSize(MAX(1.0, width), CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin];
    return ceil(NSHeight(r));
}

NSDictionary* SPDFCommentsEmptyItem(NSString* filter) {
    NSString* title = filter.length ? [NSString stringWithFormat:@"No comments match “%@”.", filter]
                                    : @"No comments yet. Select text and choose Add Comment.";
    return @{@"kind" : @"commentsEmpty", @"title" : title, @"page" : @(-1)};
}

static NSAttributedString* EmptyText(NSDictionary* item) {
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    style.minimumLineHeight = style.maximumLineHeight = 17;
    return [[NSAttributedString alloc] initWithString:Text(item, @"title") attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:12], NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary"),
        NSParagraphStyleAttributeName : style}];
}

CGFloat SPDFCommentsEmptyRowHeight(NSDictionary* item, CGFloat width) {
    return Measure(EmptyText(item), MAX(40.0, width - 48)) + 48;
}

@interface SPDFCommentsEmptyView : NSView
@property(nonatomic, copy) NSDictionary* item;
@end
@implementation SPDFCommentsEmptyView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [EmptyText(_item) drawWithRect:NSMakeRect(24, 24, MAX(40.0, NSWidth(self.bounds) - 48), NSHeight(self.bounds) - 48)
                           options:NSStringDrawingUsesLineFragmentOrigin];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityStaticTextRole; }
- (NSString*)accessibilityValue { return Text(_item, @"title"); }
@end

NSView* SPDFCommentsEmptyCell(NSTableView* table, NSDictionary* item) {
    SPDFCommentsEmptyView* view = [table makeViewWithIdentifier:@"CommentsEmpty" owner:nil];
    if (!view) {
        view = [[SPDFCommentsEmptyView alloc] initWithFrame:NSMakeRect(0, 0, 240, 80)];
        view.identifier = @"CommentsEmpty";
    }
    view.item = item;
    view.needsDisplay = YES;
    return view;
}
