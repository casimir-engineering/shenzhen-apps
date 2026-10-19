#import <Cocoa/Cocoa.h>
FOUNDATION_EXPORT NSMenu* SPDFMacTranslationChoiceMenu(id target);
NSMenu* SPDFMacTranslationChoiceMenu(id target) {
    NSMenu* menu=[[NSMenu alloc] initWithTitle:@"Translate"];
    for(NSDictionary* option in @[@{@"title":@"Local",@"action":@"translateDocumentLocally:",@"hint":@"Translate on this Mac with Argos"},
                                  @{@"title":@"AI",@"action":@"translateDocumentWithAI:",@"hint":@"Translate with OpenRouter"}]) {
        NSMenuItem* item=[[NSMenuItem alloc] initWithTitle:option[@"title"] action:NSSelectorFromString(option[@"action"]) keyEquivalent:@""];
        item.target=target;item.toolTip=option[@"hint"];[menu addItem:item];
    }
    return menu;
}
