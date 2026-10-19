#pragma once
#import <Cocoa/Cocoa.h>
// AI chat's Markdown: the chats' shared renderer (SPDFMacChatMarkdown.h) with the assistant's link rules, for a plain
// text view `width` wide that cannot scroll a block sideways (tables and code wrap, a wide diagram scales to fit).
// Chat messages themselves use SPDFMacChatMarkdownView, which keeps wide blocks at their size. Remote images wait
// for Load image; local and data images are never read.
NSAttributedString* SPDFMacAIChatMarkdown(NSString* text, CGFloat width, BOOL dark);
@class SPDFMacChatMarkdownOptions;
// The options both use: the assistant's link rules, and a link written as a file name or folder path
// ("[Report](docs/Report.pdf)") made a document link, or a site written without https:// a web link.
SPDFMacChatMarkdownOptions* SPDFMacAIChatMarkdownOptions(void);
// http(s) without credentials, document citations (spdf-ai://document) and Friends citations (shenzhenpdf-friends://).
BOOL SPDFMacAIChatLinkAllowed(NSURL* URL);
