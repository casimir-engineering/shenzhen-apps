#import "SPDFMacViewportCheckpoint.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
void spdf_schedule_markdown_checkpoint(SPDFMacViewportCheckpoint* checkpoint,
                                      ShenzhenMacDelegate* owner, SPDFDocumentTab* tab,
                                      SPDFMacMarkdownSession* session) {
    __weak ShenzhenMacDelegate* weakOwner = owner;
    __weak SPDFMacMarkdownSession* weakSession = session;
    [checkpoint scheduleAction:^{
        ShenzhenMacDelegate* activeOwner = weakOwner;
        if (!activeOwner || activeOwner.activeMarkdownSession != weakSession || [activeOwner selectedTab] != tab) return;
        [activeOwner persistActiveState];
    }];
}
