static void CheckLanguageAnalysis(NSURL* root) {
    AnalysisTransport* transport=[AnalysisTransport new];
    transport.reply=@"{\"summary\":\"Résumé\",\"tags\":[\" Électronique \",\"électronique\",\"Carte\"],\"keywords\":[],\"chapters\":[{\"title\":\"Présentation\",\"page\":1}]}";
    SPDFMacAIAnalysisCache* cache=[[SPDFMacAIAnalysisCache alloc] initWithRootURL:root];
    SPDFMacAIAnalysisService* service=[[SPDFMacAIAnalysisService alloc] initWithCache:cache transport:transport
        contextProvider:^NSDictionary*(NSString* p,BOOL l,NSProgress* g,NSError** e) {
            return @{@"pageCount":@1,@"pages":@[@{@"page":@1,@"text":@"A circuit board"}],@"outline":@[]};
        } hashProvider:^NSString*(NSString* p,NSProgress* g,NSError** e) {
            return [@"d" stringByPaddingToLength:64 withString:@"d" startingAtIndex:0];
        } keyProvider:^NSString*(NSError** e){return @"test-key";}];
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:[root URLByAppendingPathComponent:@"settings"]];
    settings.language=@"fr";
    __block BOOL done=NO; __block NSDictionary* result;
    void (^finish)(NSDictionary*,NSError*)=^(NSDictionary* value,NSError* error){result=value;done=YES;};
    [service analyzeDocumentAtPath:@"/language.pdf" landscape:NO settings:settings completion:finish];
    Check(Wait(^BOOL{return done;}) && result && transport.calls==1,"one request generates summary, chapters and tags together");
    Check([transport.payload[@"outputLanguage"] isEqual:@"French"] && [transport.instruction containsString:@"chapter titles in outputLanguage"],"background language applies to chapters and all metadata");
    Check([transport.instruction containsString:@"without emojis"] && [transport.instruction containsString:@"specific subject"],"chapter instruction requires plain descriptive topics");
    Check([result[@"tags"] isEqual:@[@"Électronique",@"Carte"]] && [result[@"language"] isEqual:@"fr"],"tags are trimmed, deduplicated and language-stamped");
    NSString* frenchKey=result[@"cacheKey"];
    SPDFMacAIAnalysisCache* reloaded=[[SPDFMacAIAnalysisCache alloc] initWithRootURL:root];
    Check([[reloaded analysisForHash:frenchKey][@"tags"] isEqual:result[@"tags"]],"document tags survive cache reopening");
    settings.language=@"ja";done=NO;
    [service analyzeDocumentAtPath:@"/language.pdf" landscape:NO settings:settings completion:finish];
    Check(Wait(^BOOL{return done;}) && result && transport.calls==2 && ![frenchKey isEqual:result[@"cacheKey"]],"new language cannot reuse metadata in the old language");
    Check([transport.payload[@"outputLanguage"] isEqual:@"Japanese"] && !transport.payload[@"previousAnalysis"],"language change cannot reuse a revision baseline in the wrong language");
    settings.language=@"fr";done=NO;
    [service analyzeDocumentAtPath:@"/language.pdf" landscape:NO settings:settings completion:finish];
    Check(Wait(^BOOL{return done;}) && result && transport.calls==2,"returning to a cached language makes no paid request");
    NSMutableDictionary* invalid=[result mutableCopy];invalid[@"tags"]=@[@"1",@"2",@"3",@"4",@"5",@"6",@"7"];
    Check(!SPDFAIValidateAnalysis(invalid,1,NO,nil),"more than six tags rejected");
    invalid[@"tags"]=@[@"1",@"2",@"3",@"4",@"5",@"6"];Check(SPDFAIValidateAnalysis(invalid,1,NO,nil)!=nil,"six tags accepted");
    invalid[@"tags"]=@[@42];Check(!SPDFAIValidateAnalysis(invalid,1,NO,nil),"non-string tags rejected");
    invalid[@"tags"]=@[@"two\nlines"];Check(!SPDFAIValidateAnalysis(invalid,1,NO,nil),"multiline tags rejected");
    invalid[@"tags"]=@[@" "];Check(!SPDFAIValidateAnalysis(invalid,1,NO,nil),"empty tags rejected");
}
