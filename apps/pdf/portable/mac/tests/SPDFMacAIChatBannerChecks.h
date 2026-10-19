// The chat view's banner (SPDFMacAIChatView.h): a strip under the header for something in effect for every message,
// Friends' "The assistant can read all your Friends chats" bar. It sits between the latest prompt and the transcript,
// pushes the transcript down rather than covering it, and leaves no trace once removed. Included by
// SPDFMacAIChatViewTests.mm after ChatFixture, Check and ConstraintWatchWindow.
#pragma once
static void RunChatBannerChecks(void) {
    NSString* key=@"NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints";
    [NSUserDefaults.standardUserDefaults registerDefaults:@{key:@YES}];
    ConstraintWatchWindow* window=[[ConstraintWatchWindow alloc] initWithContentRect:NSMakeRect(0,0,400,600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView=view;
    ChatFixture* fixture=[ChatFixture new];
    fixture.chat=@{@"id":@"banner",@"messages":@[@{@"role":@"user",@"content":@"Hello"},
                                                 @{@"role":@"assistant",@"content":@"Hi."}]};
    [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
    NSView* transcript=[view valueForKey:@"scroll"], *prompt=[view valueForKey:@"prompt"];
    CGFloat top=NSMinY(transcript.frame);
    NSView* banner=[[NSView alloc] initWithFrame:NSZeroRect];
    [banner.heightAnchor constraintEqualToConstant:30].active=YES;
    view.banner=banner; [view layoutSubtreeIfNeeded];
    Check(banner.superview==view && fabs(NSMinY(banner.frame)-(NSMaxY(prompt.frame)+8))<.5 &&
          fabs(NSMinY(transcript.frame)-(NSMaxY(banner.frame)+8))<.5 &&
          NSWidth(banner.frame)==NSWidth(transcript.frame),
          @"the banner sits under the prompt and above the transcript, as wide as it");
    view.banner=banner; [view layoutSubtreeIfNeeded];
    Check(banner.superview==view && fabs(NSMinY(transcript.frame)-(NSMaxY(banner.frame)+8))<.5,
          @"setting the same banner again changes nothing");
    view.banner=nil; [view layoutSubtreeIfNeeded];
    Check(!banner.superview && !view.banner && fabs(NSMinY(transcript.frame)-top)<.5,
          @"removing the banner gives the transcript its place back");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Check(!window.conflicts,@"the banner lays out without breaking a constraint");
    [NSUserDefaults.standardUserDefaults registerDefaults:@{key:@NO}];
}
