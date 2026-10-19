// Public documentation fixture: actual native UI, fictional documents and chat.
// No provider requests, credentials, visible windows or user's saved state.
#define SPDF_WORKSPACE_PROBE_REUSE
#import "SPDFMacWorkspaceProbe.mm"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAIChatView.h"
#import "SPDFMacAITools.h"
#import "SPDFMacSearchFileCache.h"

@interface ShenzhenMacDelegate (AIReadmeAccess)
- (id)readerAIState;
- (void)showAIChat:(id)sender;
- (void)showAIChats:(id)sender;
@end

static NSURL* Plan(NSString* root, BOOL extended) {
    NSString* title=extended ? @"Extended advisory plan" : @"Service plan";
    NSString* duration=extended ? @"24 months" : @"18 months";
    NSMutableData* data=[NSMutableData data]; CGRect paper=CGRectMake(0,0,595,842);
    CGDataConsumerRef consumer=CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGContextRef context=CGPDFContextCreate(consumer,&paper,NULL); CGDataConsumerRelease(consumer);
    CGPDFContextBeginPage(context,NULL);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
    NSColor* ink=[NSColor colorWithSRGBRed:.12 green:.15 blue:.19 alpha:1];
    NSColor* accent=[NSColor colorWithSRGBRed:.30 green:.35 blue:.62 alpha:1];
    NSDictionary* body=@{NSFontAttributeName:[NSFont systemFontOfSize:14],NSForegroundColorAttributeName:ink};
    NSDictionary* heading=@{NSFontAttributeName:[NSFont boldSystemFontOfSize:19],NSForegroundColorAttributeName:ink};
    NSDictionary* small=@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:accent};
    [NSColor.whiteColor setFill]; NSRectFill(NSRectFromCGRect(paper));
    [@"NORTHLINE / CUSTOMER SUPPORT" drawAtPoint:NSMakePoint(48,787) withAttributes:small];
    [title drawAtPoint:NSMakePoint(48,734) withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:29],NSForegroundColorAttributeName:ink}];
    [@"Plan terms · Effective 1 October 2026" drawAtPoint:NSMakePoint(48,702) withAttributes:body];
    [accent setFill]; NSRectFill(NSMakeRect(48,678,499,2));
    [[NSColor colorWithSRGBRed:.93 green:.92 blue:.98 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(48,548,499,103) xRadius:10 yRadius:10] fill];
    [@"COVERAGE TERM" drawAtPoint:NSMakePoint(68,622) withAttributes:small];
    [duration drawAtPoint:NSMakePoint(68,566) withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:38],NSForegroundColorAttributeName:ink}];
    [@"01  What is included" drawAtPoint:NSMakePoint(48,504) withAttributes:heading];
    [(extended ? @"Remote troubleshooting, setup advice and quarterly\nmaintenance reviews throughout the coverage term."
        : @"Remote troubleshooting and covered equipment repairs\nthroughout the coverage term.") drawInRect:NSMakeRect(48,433,499,56) withAttributes:body];
    [@"02  Repairs and replacement parts" drawAtPoint:NSMakePoint(48,389) withAttributes:heading];
    [(extended ? @"Repairs are not included. Labor and replacement parts\nare quoted separately before any work begins."
        : @"Covered repairs include labor and replacement parts.\nAccidental damage is excluded.") drawInRect:NSMakeRect(48,318,499,56) withAttributes:body];
    [@"03  Renewal" drawAtPoint:NSMakePoint(48,274) withAttributes:heading];
    [@"Renewal is optional. A renewal price is not stated\nin this document; request a quote before the term ends."
        drawInRect:NSMakeRect(48,203,499,56) withAttributes:body];
    [@"Fictional example / ShenzhenPDF                                      Page 1 of 1" drawAtPoint:NSMakePoint(48,36) withAttributes:small];
    [NSGraphicsContext restoreGraphicsState]; CGPDFContextEndPage(context); CGPDFContextClose(context); CGContextRelease(context);
    NSURL* URL=[NSURL fileURLWithPath:[root stringByAppendingPathComponent:[title stringByAppendingPathExtension:@"pdf"]]];
    Check([data writeToURL:URL atomically:YES],@"fictional plan written"); return URL;
}

static NSView* FindControl(NSView* view,NSString* identifier) {
    if([view.identifier isEqual:identifier]) return view;
    for(NSView* child in view.subviews) { NSView* result=FindControl(child,identifier); if(result) return result; }
    return nil;
}

int main(int argc,const char* argv[]) { @autoreleasepool {
    if(argc!=2) return 2;
    NSString* output=[NSString stringWithUTF8String:argv[1]];
    NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("SPDF_STATE_DIR",root.UTF8String,1); setenv("SPDF_NO_WINDOW_FIRST","1",1);
    // Friends is on by default and attaches after first paint; its state must be the probe's, never the real one.
    setenv("SZFRIENDS_STATE_DIR",root.UTF8String,1);
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    spdf_sidebar_probe_install_order_guard();
    NSURL* extended=Plan(root,YES); NSURL* standard=Plan(root,NO);
    WorkspaceReaderProbe* reader=[WorkspaceReaderProbe new]; [reader prepare:extended width:1420 dark:YES];
    NSMutableArray* tabs=[reader valueForKey:@"tabs"];
    ((SPDFDocumentTab*)tabs[0]).title=@"Extended advisory plan";
    ((SPDFDocumentTab*)tabs[0]).group.name=@"Support plans";
    ((SPDFDocumentTab*)tabs[1]).title=@"Service plan"; ((SPDFDocumentTab*)tabs[1]).path=standard.path;
    ((SPDFDocumentTab*)tabs[2]).title=@"Comparison notes";
    [reader updateControls];
    NSMutableArray* messages=[NSMutableArray arrayWithObject:@{@"role":@"user",@"content":@"Compare these two plans. Which lasts longer, and does it include repairs?"}];
    NSMutableArray* links=[NSMutableArray array];
    for(NSURL* URL in @[standard,extended]) {
        NSString* identifier=SPDFAIDocumentIdentifier(URL.path);
        NSString* link=[NSString stringWithFormat:@"spdf-ai://document?path=%@&page=1&revision=%@",identifier,SPDFSearchFileStamp(URL.path)];
        [links addObject:link]; NSString* call=[NSString stringWithFormat:@"read-%lu",(unsigned long)links.count];
        NSDictionary* arguments=@{@"path":identifier,@"page":@1};
        NSString* args=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil] encoding:NSUTF8StringEncoding];
        PDFDocument* PDF=[[PDFDocument alloc] initWithURL:URL];
        NSString* tool=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"pages":@[@{@"page":@1,@"citation":link,@"text":PDF.string}]} options:0 error:nil] encoding:NSUTF8StringEncoding];
        [messages addObject:@{@"role":@"assistant",@"content":@"",@"tool_calls":@[@{@"id":call,@"type":@"function",@"function":@{@"name":@"read_pages",@"arguments":args}}]}];
        [messages addObject:@{@"role":@"tool",@"tool_call_id":call,@"content":tool}];
    }
    NSString* answer=[NSString stringWithFormat:@"**Extended advisory lasts longer:** 24 months versus 18 months for the [Service plan](%@).\n\n**Repairs are excluded** from the longer plan; labor and parts cost extra. [See the exclusion](%@).",links[0],links[1]];
    [messages addObject:@{@"role":@"assistant",@"content":answer}];
    [messages addObject:@{@"role":@"assistant",@"content":@"Extended advisory coverage: 24 months. Repairs excluded.",@"answerCard":@{@"label":@"Extended advisory · repairs excluded",@"value":@"24 months",@"citation":links[1]}}];
    id state=[reader readerAIState]; SPDFMacAIChatStore* store=[state valueForKey:@"store"];
    NSString* chatID=NSUUID.UUID.UUIDString;
    NSDictionary* chat=@{@"id":chatID,@"title":@"Coverage and repair exclusions",@"updated":@(NSDate.date.timeIntervalSince1970),@"messages":messages};
    Check([store saveChat:chat error:nil],@"scripted comparison saved");
    NSString* folder=[store createFolderNamed:@"Plan comparison" error:nil];
    Check([store moveChat:chatID toFolder:folder error:nil],@"comparison organized in folder");
    Check([store chatWithID:chatID]!=nil,@"comparison reloads with valid tool pairs");
    SPDFMacAIChatView* view=[state valueForKey:@"view"]; __block BOOL clicked=NO;
    view.openLink=^(NSURL* URL){ clicked=[URL.absoluteString isEqual:links[1]]; };
    [[state valueForKey:@"session"] loadChat:[store chatWithID:chatID]];
    [reader showAIChat:nil]; [reader showAIChats:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]];
    NSButton* evidence=(id)FindControl(view,@"answerEvidence");
    Check(evidence!=nil,@"comparison card has evidence button"); [evidence performClick:nil];
    Check(clicked,@"evidence forwards the longer plan source");
    [reader capture:[output stringByAppendingPathComponent:@"macos-ai-chat.png"] width:1420 sidebar:YES map:NO];
    for(NSWindow* window in NSApp.windows) Check(!window.visible,@"no window was shown");
    [fm removeItemAtPath:root error:nil];
    fprintf(stderr,"AI README comparison fixture: %lu failures\n",(unsigned long)failures);
    return failures ? 1 : 0;
}}
