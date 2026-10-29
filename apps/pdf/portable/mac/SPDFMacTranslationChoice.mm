#import "SPDFMacTranslationChoice.h"
#import "SPDFMacTranslationEnablement.h"
#import "SPDFMacTranslateLanguagePopover.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacModels.h"

@implementation ShenzhenMacDelegate (SPDFMacTranslationChoice)
- (void)translateDocument:(id)sender {
    if (!spdf_translation_command_enabled([self translationContext]) || ![self selectedTab].path.length) { NSBeep(); return; }
    // Under the button when it is in the toolbar; from the File or overflow menu, under the toolbar's right end.
    NSView* anchor=_translateButton.window && !_translateButton.hidden && _translateButton.superview ? _translateButton :
        ([sender isKindOfClass:NSView.class] ? sender : _toolbar);
    __weak ShenzhenMacDelegate* weakSelf=self;
    [SPDFMacTranslateLanguagePopover showRelativeToView:anchor translate:^(NSString* language) {
        [weakSelf translateShownDocumentInto:language];
    }];
}
- (BOOL)translateShownDocumentInto:(NSString*)language {
    SPDFDocumentTab* tab=[self selectedTab];
    if (!tab.path.length || !language.length) return NO;
    NSString* name=spdf_tab_display_name(tab) ?: tab.title.length ? tab.title : tab.path.lastPathComponent;
    return [self aiSendRequestInNewChat:[NSString stringWithFormat:@"Translate “%@” to %@.",name,language]];
}
@end
