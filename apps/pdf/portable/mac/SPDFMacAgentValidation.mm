#import "SPDFMacAgentCommand.h"
#import "SPDFMacSupport.h"

static void fail(NSError** error, NSString* message) {
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.Agent" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary* validateGroups(NSDictionary* command, NSError** error) {
    NSDictionary* fields=@{@"list-groups":@[],@"create-group":@[@"paths",@"name",@"color",@"beforeGroupID"],
        @"update-group":@[@"groupID",@"name",@"color",@"collapsed",@"hidden"],
        @"move-tab":@[@"path",@"groupID",@"beforePath"],@"move-group":@[@"groupID",@"beforeGroupID"],
        @"ungroup":@[@"groupID"],@"jump-group":@[@"groupID"]};
    NSString* action=command[@"action"]; NSArray* allowed=fields[action];
    if (!allowed) { fail(error,@"Unknown action."); return nil; }
    for (NSString* key in command) if (![@[@"action",@"windowSessionID"] containsObject:key] && ![allowed containsObject:key]) {
        fail(error,@"Unknown field for this group action."); return nil;
    }
    for (NSString* key in @[@"path",@"beforePath",@"groupID",@"beforeGroupID",@"windowSessionID",@"name",@"color"]) {
        id value=command[key]; if (!value) continue;
        if (![value isKindOfClass:NSString.class] || [value length]>4096 || [value rangeOfString:@"\0"].location!=NSNotFound ||
            (![key isEqual:@"name"] && ![value length])) { fail(error,@"Invalid group command string."); return nil; }
    }
    NSMutableDictionary* normalized=[command mutableCopy];
    for (NSString* key in @[@"path",@"beforePath"]) if (command[key]) {
        if (![command[key] isAbsolutePath] || [[command[key] pathExtension] isEqual:@"spdf-command"]) {
            fail(error,@"Document paths must be absolute."); return nil;
        }
        normalized[key]=[command[key] stringByStandardizingPath];
    }
    if ([action isEqual:@"create-group"]) {
        id paths=command[@"paths"];
        if (![paths isKindOfClass:NSArray.class] || ![paths count] || [paths count]>256) {
            fail(error,@"Create requires 1–256 distinct open-document paths."); return nil;
        }
        NSMutableArray* clean=[NSMutableArray array];
        for (id path in paths) {
            if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath] || [path length]>4096 ||
                [path rangeOfString:@"\0"].location!=NSNotFound || [[path pathExtension] isEqual:@"spdf-command"]) {
                fail(error,@"Invalid document path."); return nil;
            }
            NSString* value=[path stringByStandardizingPath];
            if ([clean containsObject:value]) { fail(error,@"Document paths must be distinct."); return nil; }
            [clean addObject:value];
        }
        normalized[@"paths"]=clean;
    } else if (![action isEqual:@"list-groups"] && ![command[@"groupID"] length]) {
        fail(error,@"groupID is required. Obtain it from list-groups."); return nil;
    }
    if ([action isEqual:@"move-tab"] && !command[@"path"]) { fail(error,@"path is required."); return nil; }
    if ([action isEqual:@"update-group"] && !command[@"name"] && !command[@"color"] && !command[@"collapsed"] && !command[@"hidden"]) {
        fail(error,@"Update requires name, color, collapsed, or hidden."); return nil;
    }
    for (NSString* key in @[@"collapsed",@"hidden"]) {
        id flag=command[key];
        if (flag && CFGetTypeID((__bridge CFTypeRef)flag)!=CFBooleanGetTypeID()) {
            fail(error,[key stringByAppendingString:@" must be a Boolean."]); return nil;
        }
    }
    return normalized;
}

NSDictionary* SPDFMacValidateAgentCommand(NSData* data, NSError** error) {
    if (!data || data.length > 65536) { fail(error, @"Command must be JSON of at most 64 KiB."); return nil; }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:NSDictionary.class]) { fail(error, @"Command must be an object."); return nil; }
    NSDictionary* command = value;
    if (![command[@"action"] isKindOfClass:NSString.class]) { fail(error,@"Action must be a string."); return nil; }
    if (![@[@"inspect",@"open"] containsObject:command[@"action"]]) return validateGroups(command,error);
    NSSet* keys = [NSSet setWithArray:@[@"action", @"path", @"page", @"query", @"context", @"occurrence", @"paper", @"renderDirectory"]];
    for (id key in command) if (![keys containsObject:key]) { fail(error, @"Unknown command field."); return nil; }
    NSString* action = command[@"action"];
    if (![@[@"inspect", @"open"] containsObject:action]) { fail(error, @"Action must be inspect or open."); return nil; }
    for (NSString* key in @[@"path", @"query", @"context", @"renderDirectory"]) {
        id field = command[key];
        if (field && (![field isKindOfClass:NSString.class] || [field length] > 4096 || [field rangeOfString:@"\0"].location != NSNotFound)) {
            fail(error, [@"Invalid string: " stringByAppendingString:key]); return nil;
        }
    }
    NSString* path = command[@"path"];
    if (!path.isAbsolutePath || [path.pathExtension isEqualToString:@"spdf-command"]) { fail(error, @"An absolute document path is required."); return nil; }
    for (NSString* key in @[@"page", @"occurrence"]) {
        id number = command[key];
        if (number && (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID() ||
                       [number doubleValue] < 1 || [number doubleValue] > 1000000 || floor([number doubleValue]) != [number doubleValue])) {
            fail(error, [key stringByAppendingString:@" must be a positive integer."]); return nil;
        }
    }
    if ((command[@"context"] || command[@"occurrence"]) && ![command[@"query"] length]) { fail(error, @"Context and occurrence require a query."); return nil; }
    id paper = command[@"paper"];
    if (paper) {
        if (![paper isKindOfClass:NSDictionary.class]) { fail(error, @"Paper must be an object."); return nil; }
        NSSet* paperKeys = [NSSet setWithArray:@[@"paper-size", @"paper-orientation", @"paper-margin", @"paper-margin-top", @"paper-margin-right", @"paper-margin-bottom", @"paper-margin-left"]];
        for (id key in paper) if (![paperKeys containsObject:key] || ![paper[key] isKindOfClass:NSString.class]) { fail(error, @"Paper keys and values must use the documented authoring syntax."); return nil; }
    }
    if ([action isEqual:@"open"] && (paper || command[@"renderDirectory"])) { fail(error, @"Paper and renderDirectory apply only to inspect."); return nil; }
    if ([action isEqual:@"inspect"] && (command[@"query"] || command[@"context"] || command[@"occurrence"])) { fail(error, @"Search fields apply only to open."); return nil; }
    if (command[@"renderDirectory"] && ![command[@"renderDirectory"] isAbsolutePath]) { fail(error, @"Render directory must be absolute."); return nil; }
    NSMutableDictionary* normalized = [command mutableCopy];
    normalized[@"path"] = path.stringByStandardizingPath;
    return normalized;
}

NSString* SPDFMacAgentRequestDirectory(void) {
    // Deliberately no directory creation: ordinary startup never calls this.
    return [spdf_mac_support_directory() stringByAppendingPathComponent:@"AgentRequests"];
}

NSInteger SPDFMacAgentChooseMatch(NSArray<NSDictionary*>* matches, NSDictionary* command, NSError** error) {
    NSMutableArray<NSNumber*>* eligible = [NSMutableArray array];
    NSString* context = command[@"context"];
    for (NSUInteger index = 0; index < matches.count; index++) {
        NSDictionary* match = matches[index];
        if (command[@"page"] && [command[@"page"] integerValue] != [match[@"page"] integerValue]) continue;
        if (context.length && [match[@"context"] rangeOfString:context options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [eligible addObject:@(index)];
    }
    NSInteger occurrence = command[@"occurrence"] ? [command[@"occurrence"] integerValue] : 1;
    if (context.length && !command[@"occurrence"] && eligible.count > 1) {
        fail(error, @"Context is ambiguous. Supply a page or one-based occurrence."); return -1;
    }
    if (occurrence > (NSInteger)eligible.count) { fail(error, @"No matching passage. Refine the query, page, context, or occurrence."); return -1; }
    return eligible[(NSUInteger)occurrence - 1].integerValue;
}
