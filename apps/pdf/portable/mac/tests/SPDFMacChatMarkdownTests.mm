// Markdown in chats (SPDFMacChatMarkdown.h): chat scale, drawn blocks, link and image safety, diagram deadlines,
// table limits and render time, accessibility of drawn controls, table link menus, the AI chat message view, diagram
// spacing and contrast, and offscreen renders. Headless: no app, no network, no real pasteboard.
#import "SPDFMacChatMarkdownContentChecks.h"
#import "SPDFMacChatMarkdownSafetyChecks.h"
#import "SPDFMacChatMarkdownBudgetChecks.h"
#import "SPDFMacChatMarkdownViewChecks.h"
#import "SPDFMacChatMarkdownAccessChecks.h"
#import "SPDFMacChatMarkdownLinkChecks.h"
#import "SPDFMacChatMarkdownDiagramChecks.h"
#import "SPDFMacChatMarkdownRenderChecks.h"

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        RunChatScaleChecks();
        RunChatBlockChecks();
        RunChatLinkChecks();
        RunChatHTMLChecks();
        RunChatImageChecks();
        RunChatDeadlineChecks();
        RunChatTableLimitChecks();
        RunChatLayoutTimeChecks();
        RunChatRenderTimeChecks();
        RunChatAllowanceChecks();
        RunChatKeptBlockChecks();
        RunChatBlockClickChecks();
        RunChatAccessibilityChecks();
        RunChatLinkMenuChecks();
        RunChatViewChecks();
        RunChatViewInsetChecks();
        RunChatDiagramSpacingChecks();
        RunChatDiagramContrastChecks();
        RunChatRenderChecks();
        printf("SPDFMacChatMarkdownTests passed\n");
    }
    return 0;
}
