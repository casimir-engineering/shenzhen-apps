// Edit-and-resend, Summarize and the model's context window through the production reader integration.
@interface ShenzhenMacDelegate (ComposerEditHost)
- (void)aiChatAction:(NSString*)action;
@end
static void CheckComposerEditAndSummary(ComposerReaderProbe* reader,SPDFMacAIChatView* view,
                                        SPDFMacAIChatSession* session) {
    reader.testKey=@"sk-or-v1-offline-acceptance-only"; reader.keyError=nil;
    Check(reader.catalogRequests==1 && !session.contextTokens,
        "an unknown model size is looked up once; a model missing from the list is not looked up on every send");
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    [settings load:nil]; settings.modelContextTokens=200000;
    Check([settings save:nil],"composer fixture saves a model size");
    NSUInteger catalog=reader.catalogRequests, before=ComposerRequestCount();
    Check(view.editMessage && view.editMessage(2,@"Edited second message"),"Edit sends through the reader integration");
    Check(ComposerWait(^BOOL{return [session.chat[@"messages"] count]==4 && !session.running;}),
        "the edited question gets a new reply");
    NSArray* messages=session.chat[@"messages"];
    Check([messages[2][@"content"] isEqual:@"Edited second message"] &&
        [messages[3][@"content"] isEqual:@"Offline acceptance reply"] && ComposerRequestCount()==before+1,
        "later messages are replaced by one new request from the edited question");
    Check(session.contextTokens==200000 && reader.catalogRequests==catalog,
        "a known model size is used without another lookup");
    before=ComposerRequestCount(); [reader aiChatAction:@"compact"];
    Check(ComposerWait(^BOOL{return !session.running && [session.chat[@"messages"] count]==5;}) &&
        [session.chat[@"messages"][2][@"role"] isEqual:@"compaction"] && ComposerRequestCount()==before+1,
        "Summarize earlier messages runs once and marks the transcript");
}
