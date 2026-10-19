#import "SPDFMarkdownDecorations.h"

#import "SPDFMarkdownDiagramBand.h"
#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownTableDecorations.h"

const CGFloat SPDFMarkdownCodeBoxOuterMargin = 14.0;

@implementation SPDFMarkdownPageDecoration
- (instancetype)initWithType:(SPDFMarkdownPageDecorationType)type
                        rect:(NSRect)rect
                  blockIndex:(NSUInteger)blockIndex
               diagramLayout:(SPDFMarkdownDiagramLayout*)diagramLayout {
    self = [super init];
    if (self) {
        _type = type;
        _rect = rect;
        _blockIndex = blockIndex;
        _diagramLayout = diagramLayout;
    }
    return self;
}
- (instancetype)initWithType:(SPDFMarkdownPageDecorationType)type
                        rect:(NSRect)rect
                  blockIndex:(NSUInteger)blockIndex {
    return [self initWithType:type rect:rect blockIndex:blockIndex diagramLayout:nil];
}
@end

static const CGFloat kSPDFMarkdownHeadingRuleGap = 9.0;

NSArray<SPDFMarkdownPageDecoration*>* SPDFMarkdownDecorationsForPage(SPDFMarkdownPage* page,
                                                                     NSArray<SPDFMarkdownPaginationItem*>* items,
                                                                     CGFloat printableWidth) {
    NSMutableArray<SPDFMarkdownPageDecoration*>* decorations = [NSMutableArray array];
    NSArray<SPDFMarkdownPageFragment*>* fragments = page.fragments;
    NSUInteger index = 0;
    while (index < fragments.count) {
        SPDFMarkdownPageFragment* first = fragments[index];
        SPDFMarkdownPaginationItem* tableItem = first.itemIndex < items.count ? items[first.itemIndex] : nil;
        if (tableItem.tableRowInfo) {
            // Table rows are separate items; the table planner consumes every
            // consecutive row of the same table and emits its band, stripe and
            // grid decorations in one pass.
            index = SPDFMarkdownAppendTableDecorations(fragments, index, items, printableWidth, decorations);
            continue;
        }
        NSUInteger runEnd = index;
        while (runEnd + 1 < fragments.count && fragments[runEnd + 1].itemIndex == first.itemIndex) ++runEnd;
        SPDFMarkdownPageFragment* last = fragments[runEnd];
        SPDFMarkdownPaginationItem* item = tableItem;
        if (item.diagramInfo) {
            // A native diagram contributes one decoration carrying its whole
            // vector shape list; its labels are canonical text drawn by the
            // page's own text pass on top.
            index = SPDFMarkdownAppendDiagramDecoration(fragments, index, runEnd, item, decorations);
            continue;
        }
        if (item.kind == SPDFMarkdownBlockKindCode) {
            // The reserved spacer bands are fragments of the code item, so the
            // box covers them and each page portion gets its own box. The
            // outer margin stays unpainted: the box is inset at the item's
            // true top (a non-continuation lead band) and true bottom (the
            // trailing band), while mid-item page splits run edge to edge.
            CGFloat top = first.pageYOffset;
            CGFloat bottom = last.pageYOffset + last.height;
            if (!first.isContinuation) top += SPDFMarkdownCodeBoxOuterMargin;
            if (NSEqualRanges(last.attributedRange, item.lines.lastObject.attributedRange))
                bottom -= SPDFMarkdownCodeBoxOuterMargin;
            if (bottom - top >= 1) {
                [decorations addObject:[[SPDFMarkdownPageDecoration alloc]
                                           initWithType:SPDFMarkdownPageDecorationTypeCodeBox
                                                   rect:NSMakeRect(0, top, printableWidth, bottom - top)
                                             blockIndex:item.blockIndex]];
            }
        } else if (item.kind == SPDFMarkdownBlockKindThematicBreak) {
            // The break renders as an invisible blank line; the visible rule is
            // this 2px hairline centered in the reserved space.
            CGFloat top = first.pageYOffset;
            CGFloat bottom = last.pageYOffset + last.height;
            CGFloat y = MIN(MAX(top, top + (bottom - top) / 2 - 1), MAX(top, bottom - 2));
            [decorations addObject:[[SPDFMarkdownPageDecoration alloc]
                                       initWithType:SPDFMarkdownPageDecorationTypeThematicBreakRule
                                               rect:NSMakeRect(0, y, printableWidth, 2)
                                         blockIndex:item.blockIndex]];
        } else if (item.kind == SPDFMarkdownBlockKindHeading && item.headingLevel >= 1 && item.headingLevel <= 2 &&
                   NSEqualRanges(last.attributedRange, item.lines.lastObject.attributedRange)) {
            CGFloat y = last.pageYOffset + last.baselineOffset + kSPDFMarkdownHeadingRuleGap;
            y = MIN(y, last.pageYOffset + last.height - 1);
            [decorations addObject:[[SPDFMarkdownPageDecoration alloc]
                                       initWithType:SPDFMarkdownPageDecorationTypeHeadingRule
                                               rect:NSMakeRect(0, y, printableWidth, 1)
                                         blockIndex:item.blockIndex]];
        }
        index = runEnd + 1;
    }
    return decorations;
}
