#import "SPDFMacUIHelpers.h"

// A page's menu is built anew on every right-click with an icon on each item: the symbols are made once per name and
// label and reused, which takes about half a millisecond off every right-click.
void spdf_set_menu_item_system_symbol(NSMenuItem* item, NSString* symbolName) {
    if (!item || symbolName.length == 0) return;
    if (@available(macOS 11.0, *)) {
        static NSMutableDictionary<NSString*, NSImage*>* made;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ made = [NSMutableDictionary dictionary]; });
        NSString* key = [NSString stringWithFormat:@"%@\n%@", symbolName, item.title ?: @""];
        NSImage* image = NSThread.isMainThread ? made[key] : nil;
        if (!image) {
            image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:item.title];
            if (!image) return;
            [image setTemplate:YES];
            if (NSThread.isMainThread && made.count < 256) made[key] = image;
        }
        item.image = image;
    }
}
