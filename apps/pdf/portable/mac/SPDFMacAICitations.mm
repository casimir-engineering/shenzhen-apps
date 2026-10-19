#import "SPDFMacAICitations.h"
#import "SPDFMacDocumentFormats.h"
NSDictionary* SPDFMacAICitationArguments(NSURL* URL) {
    if (![URL.scheme.lowercaseString isEqual:@"spdf-ai"] || ![URL.host isEqual:@"document"] ||
        URL.user || URL.password || URL.port || URL.fragment || URL.path.length) return nil;
    NSMutableDictionary* args=[NSMutableDictionary dictionary];
    for (NSURLQueryItem* item in [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO].queryItems) {
        if (!item.value.length || args[item.name] || ![@[@"path",@"page",@"revision",@"layoutIdentity",@"query"] containsObject:item.name]) return nil;
        args[item.name]=item.value;
    }
    if (![args[@"path"] hasPrefix:@"doc:"] || ![args[@"revision"] length]) return nil;
    NSString* raw=args[@"page"]; if (!raw) return nil;
    NSScanner* scanner=[NSScanner scannerWithString:raw]; scanner.charactersToBeSkipped=nil;
    NSInteger page=0; if (![scanner scanInteger:&page] || !scanner.isAtEnd || page<1 || page>1000000) return nil;
    if ([args[@"query"] length]>512) return nil;
    args[@"page"]=@(page); return args;
}
static BOOL Contains(id value, NSDictionary* arguments, NSUInteger depth) {
    if (depth>20) return NO;
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) {
            id item=value[key];
            if ([key isEqual:@"citation"] && [item isKindOfClass:NSString.class] &&
                [SPDFMacAICitationArguments([NSURL URLWithString:item]) isEqual:arguments]) return YES;
            if (Contains(item,arguments,depth+1)) return YES;
        }
    } else if ([value isKindOfClass:NSArray.class]) for (id item in value) if (Contains(item,arguments,depth+1)) return YES;
    return NO;
}
BOOL SPDFMacAIChatContainsCitation(NSDictionary* chat, NSDictionary* arguments) {
    if (!arguments) return NO;
    for (NSDictionary* message in chat[@"messages"]) {
        if ([message[@"role"] isEqual:@"preview"] && [message[@"local"] boolValue] &&
            [message[@"preview"][@"citation"] isEqual:arguments]) return YES;
        if (![message[@"role"] isEqual:@"tool"] || ![message[@"content"] isKindOfClass:NSString.class]) continue;
        NSData* data=[message[@"content"] dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length>512*1024) continue; // Above the largest tool result a chat keeps.
        id result=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (Contains(result,arguments,0)) return YES;
    }
    return NO;
}
NSDictionary* SPDFMacAIResolveCitation(NSDictionary* chat, NSDictionary* arguments) {
    if (SPDFMacAIChatContainsCitation(chat,arguments)) return arguments;
    if (!arguments[@"query"]) return nil;
    // A model may append a made-up search query to a genuine page link. Never
    // navigate to that passage; recover only the independently retrieved page.
    NSMutableDictionary* page=[arguments mutableCopy]; [page removeObjectForKey:@"query"];
    return SPDFMacAIChatContainsCitation(chat,page) ? page : nil;
}
NSString* SPDFMacAIRepairCitationLinks(NSString* text, NSDictionary* chat) {
    if (![text containsString:@"spdf-ai://"]) return text;
    NSRegularExpression* links=[NSRegularExpression regularExpressionWithPattern:@"spdf-ai://document\\?[^\\s<>)]+"
        options:0 error:nil];
    NSMutableString* repaired=[text mutableCopy];
    NSArray* matches=[links matchesInString:text options:0 range:NSMakeRange(0,text.length)];
    for (NSTextCheckingResult* match in matches.reverseObjectEnumerator) {
        NSURLComponents* link=[NSURLComponents componentsWithString:[text substringWithRange:match.range]];
        NSDictionary* original=SPDFMacAICitationArguments(link.URL);
        NSDictionary* verified=SPDFMacAIResolveCitation(chat,original);
        if (!verified || [original isEqual:verified]) continue;
        NSMutableArray* items=[NSMutableArray array];
        for (NSURLQueryItem* item in link.queryItems) if (![item.name isEqual:@"query"]) [items addObject:item];
        link.queryItems=items;
        [repaired replaceCharactersInRange:match.range withString:link.string];
    }
    return repaired;
}
NSDictionary* SPDFMacAIDocumentLinkArguments(NSURL* URL) {
    if (![URL.scheme.lowercaseString isEqual:@"spdf-ai"] || ![URL.host isEqual:@"document"] ||
        URL.user || URL.password || URL.port) return nil;
    NSMutableDictionary* link=[NSMutableDictionary dictionary];
    for (NSURLQueryItem* item in [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO].queryItems) {
        NSString* value=item.value;
        if (!value.length || value.length>1024) continue;
        if (([item.name isEqual:@"path"] || [item.name isEqual:@"documentID"]) &&
            ([value hasPrefix:@"doc:"] || [value hasPrefix:@"collection:"])) link[@"path"]=value;
        else if ([item.name isEqual:@"name"] && value.lastPathComponent.length) link[@"name"]=value.lastPathComponent;
        else if ([item.name isEqual:@"site"]) {
            NSURL* site=[NSURL URLWithString:value];
            if ([site.scheme isEqual:@"https"] && site.host.length && !site.user && !site.password) link[@"site"]=site;
        }
        else if ([item.name isEqual:@"web"]) {
            NSURL* web=[NSURL URLWithString:value];
            if ([web.scheme isEqual:@"https"] && web.host.length && !web.user && !web.password) link[@"web"]=web;
        }
        else if ([item.name isEqual:@"page"]) {
            NSScanner* scanner=[NSScanner scannerWithString:value]; scanner.charactersToBeSkipped=nil;
            NSInteger page=0;
            if ([scanner scanInteger:&page] && scanner.isAtEnd && page>=1 && page<=1000000) link[@"page"]=@(page);
        }
    }
    return link[@"path"] || link[@"name"] ? link : nil;
}
// Extensions the reader opens. Code files (.py, .pl, .sh, .rs...) share their
// extension with a country domain; written as a bare name they are still files.
static BOOL LinkableDocumentExtension(NSString* extension) {
    NSString* lower=extension.lowercaseString;
    return [SPDFNativeDocumentExtensions() containsObject:lower] || SPDFSourceDocumentLanguageMap()[lower]!=nil;
}
// Country domains and the generic domains people write without https:// ("example.com", "allegro.pl").
static BOOL KnownTopLevelDomain(NSString* label) {
    static NSSet<NSString*>* domains;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString* country=@"ac ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bm bn bo br "
            "bs bt bw by bz ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg er es "
            "et eu fi fj fk fm fo fr ga gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il "
            "im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc "
            "md me mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe "
            "pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sk sl sm sn so sr ss st su "
            "sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws "
            "ye yt za zm zw";
        NSString* generic=@"com org net edu gov mil int info biz name pro aero coop museum mobi asia tel travel jobs "
            "cat post app dev page blog shop store online site website tech xyz top club news live cloud art design "
            "wiki zip mov link email space fun icu vip ltd group studio agency media digital network systems "
            "solutions company world today life global center social games video music photo photos";
        NSString* all=[NSString stringWithFormat:@"%@ %@",country,generic];
        domains=[NSSet setWithArray:[all componentsSeparatedByString:@" "]];
    });
    return [domains containsObject:label.lowercaseString];
}
// A name the reader cannot open ("budget.numbers") is still a document name, so following
// it says the document cannot be found instead of opening a made-up web address.
static BOOL DocumentNameExtension(NSString* extension) {
    if (LinkableDocumentExtension(extension)) return YES;
    NSCharacterSet* alphanumeric=NSCharacterSet.alphanumericCharacterSet.invertedSet;
    return extension.length && extension.length<=12 && !KnownTopLevelDomain(extension) &&
        [extension rangeOfCharacterFromSet:alphanumeric].location==NSNotFound;
}
NSURL* SPDFMacAIDocumentNameLink(NSString* destination) {
    NSString* written=[destination stringByRemovingPercentEncoding] ?: destination;
    // A file name or a relative path to one; anything with a scheme, query, fragment,
    // parent folder or a leading host ("example.com/a.pdf") is not a document reference.
    NSCharacterSet* notInNames=[NSCharacterSet characterSetWithCharactersInString:@":#?\\"];
    if (!written.length || written.length>1024 || [written hasPrefix:@"/"] ||
        [written rangeOfCharacterFromSet:notInNames].location!=NSNotFound) return nil;
    NSArray<NSString*>* parts=[written componentsSeparatedByString:@"/"];
    for (NSString* part in parts) if ([part isEqual:@".."]) return nil;
    NSString* name=parts.lastObject;
    if (parts.count>1 && [parts.firstObject containsString:@"."] && ![parts.firstObject isEqual:@"."]) return nil;
    if (!name.length || name.length>255 || [name hasPrefix:@"."] || !DocumentNameExtension(name.pathExtension))
        return nil;
    NSURLComponents* link=[NSURLComponents new]; link.scheme=@"spdf-ai"; link.host=@"document";
    NSMutableArray* items=[NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"name" value:name]];
    // "allegro.pl" or "foo.sh" is a file first; when no such file is found the reader may open the site.
    NSURL* web=parts.count==1 && KnownTopLevelDomain(name.pathExtension)
        ? [NSURL URLWithString:[@"https://" stringByAppendingString:name]] : nil;
    if (web.host.length) [items addObject:[NSURLQueryItem queryItemWithName:@"web" value:web.absoluteString]];
    link.queryItems=items;
    return link.URL;
}
NSURL* SPDFMacAIDocumentOrSiteLink(NSString* destination, NSURL* site) {
    NSString* name=[destination stringByRemovingPercentEncoding] ?: destination;
    BOOL single=name.length && name.length<=255 && ![name containsString:@"/"] &&
        ![name.lowercaseString hasPrefix:@"www."];
    if (![site.scheme isEqual:@"https"] || !single) return site;
    NSURLComponents* link=[NSURLComponents new]; link.scheme=@"spdf-ai"; link.host=@"document";
    link.queryItems=@[[NSURLQueryItem queryItemWithName:@"name" value:name],
        [NSURLQueryItem queryItemWithName:@"site" value:site.absoluteString]];
    return link.URL;
}
static BOOL SameName(NSString* name, NSString* candidate, BOOL stemOnly) {
    if (!name.length || !candidate.length) return NO;
    NSString* a=stemOnly ? name.stringByDeletingPathExtension : name;
    NSString* b=stemOnly ? candidate.stringByDeletingPathExtension : candidate;
    return [a compare:b options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch]==NSOrderedSame;
}
NSDictionary* SPDFMacAIResolveDocumentLink(NSDictionary* link, NSArray<NSString*>* openPaths,
    NSArray<NSString*>* recentPaths, NSArray<NSDictionary*>* collection, NSString* (^identify)(NSString* path)) {
    NSString* identifier=link[@"path"], *name=link[@"name"];
    if ([identifier hasPrefix:@"collection:"]) {
        NSString* raw=[identifier substringFromIndex:11];
        for (NSDictionary* row in collection) if ([row[@"id"] isEqual:raw]) return @{@"collection":row};
        return nil;
    }
    if (identifier.length && identify) {
        for (NSString* path in openPaths) if ([identify(path) isEqual:identifier]) return @{@"path":path};
        for (NSDictionary* row in collection)
            if ([row[@"path"] isKindOfClass:NSString.class] && [identify(row[@"path"]) isEqual:identifier])
                return @{@"collection":row};
        for (NSString* path in recentPaths) if ([identify(path) isEqual:identifier]) return @{@"path":path};
        return nil;
    }
    // A written file name: the exact name first, then the same name without its extension.
    // A name that may be a site ("example.com") matches only a document of exactly that name.
    for (NSNumber* stem in link[@"site"] ? @[@NO] : @[@NO, @YES]) {
        BOOL loose=stem.boolValue;
        for (NSString* path in openPaths) if (SameName(name,path.lastPathComponent,loose)) return @{@"path":path};
        for (NSDictionary* row in collection) {
            NSString* file=[row[@"path"] isKindOfClass:NSString.class] ? [row[@"path"] lastPathComponent] : nil;
            NSString* title=[row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : nil;
            if (SameName(name,file,loose) || SameName(name,title,loose)) return @{@"collection":row};
        }
        for (NSString* path in recentPaths) if (SameName(name,path.lastPathComponent,loose)) return @{@"path":path};
    }
    return nil;
}
