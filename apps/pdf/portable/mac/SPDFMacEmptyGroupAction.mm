#import "SPDFMacTabGroupIntegration.h"

@interface SPDFTabStripView (EmptyGroupPrompt)
- (void)promptForGroup:(SPDFTabGroup*)group creating:(BOOL)creating;
@end
@implementation ShenzhenMacDelegate (SPDFMacEmptyGroupAction)
- (void)createEmptyTabGroupFromPlus:(id)sender {
    (void)sender;
    SPDFTabGroup* group=[self createEmptyTabGroup];
    // Let native menu tracking finish before presenting the anchored name field.
    // The group already exists; dismissing the prompt keeps its default name.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[self emptyTabGroups] containsObject:group]) [self->_tabStrip promptForGroup:group creating:YES];
    });
}
@end
