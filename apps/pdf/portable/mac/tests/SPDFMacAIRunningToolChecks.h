// The session names the tool a request is running (runningTool), so each view can word it for the person instead of
// showing its identifier; its status meanwhile says only "Working…", never the identifier. Included by
// SPDFMacAIToolSeamTests.mm after SPDFMacAISessionSeamChecks.h.
#pragma once

static void CheckRunningTool(void) {
    SeamChat chat = SeamMakeChat(@"running-tool");
    SPDFMacAIChatSession* session = chat.session;
    chat.reader.deferCompletion = YES;
    CHECK(!session.runningTool, "an idle session runs no tool");
    [session sendContext:SeamRequest(session, @"Read page 2", nil, nil) model:@"fake/model" apiKey:@"TEST"];
    CHECK(session.running && !session.runningTool, "no tool runs while the model thinks");
    chat.model.reply(SeamToolTurn(@[SeamCall(@"r1", @"read_pages")]), nil);
    CHECK([session.runningTool isEqual:@"read_pages"] && session.activityState == SPDFMacAIChatActivityWorking &&
          [session.status isEqual:@"Working…"] && [session.activityDetail isEqual:@"Working…"],
          "while a tool runs the session names it for the views, and its status says Working… without the name");
    if (chat.reader.pending) chat.reader.pending(@{@"ok" : @YES});
    CHECK(!session.runningTool && session.activityState == SPDFMacAIChatActivityThinking,
          "once the tool is done and the model has the turn, no tool is named");
    chat.model.reply(SeamToolTurn(@[SeamCall(@"r2", @"read_pages")]), nil);
    [session cancel];
    CHECK(!session.runningTool && !session.running, "Stop while a tool runs leaves no tool named");
    [session performHistoryAction:NO];
    CHECK(!session.runningTool, "Undo is work, but no tool: the heading keeps its own words");
    [NSFileManager.defaultManager removeItemAtPath:chat.root error:nil];
}
