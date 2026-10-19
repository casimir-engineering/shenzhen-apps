#pragma once
#import "SPDFMacPanelSearchField.h"
#import "SPDFMacPanelExpansionImage.h"

static void SPDFUpdateGroupSearchPlaceholder(NSSearchField* field) {
    if (field.stringValue.length) return;
    CGFloat width=NSWidth([(NSSearchFieldCell*)field.cell searchTextRectForBounds:field.bounds])-2;
    NSDictionary* attributes=@{NSFontAttributeName:field.font ?: [NSFont systemFontOfSize:13]};
    for (NSString* text in @[@"Search groups and documents",@"Search groups and docs",@"Groups & docs",@"Search…"]) {
        if ([text sizeWithAttributes:attributes].width<=width) { field.placeholderString=text; return; }
    }
    field.placeholderString=@"";
}
