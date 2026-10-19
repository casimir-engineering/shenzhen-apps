#import "SPDFMacUIHelpers.h"

void spdf_set_menu_item_system_symbol(NSMenuItem* item, NSString* symbolName) {
    if (!item || symbolName.length == 0) return;
    if (@available(macOS 11.0, *)) {
        NSImage* image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:item.title];
        if (!image) return;
        [image setTemplate:YES];
        item.image = image;
    }
}
