#import "SPDFMacAIChatStore.h"
#import <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
NSString* const SPDFMacAIChatTitleSearchOnlyKey=@"titleSearchOnly";
// Compaction keeps long conversations usable, so saved chats may hold many turns.
static const NSUInteger ChatFileLimit=32*1024*1024, ChatMessageLimit=4096;
static BOOL ValidID(NSString* value) { return [value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value]; }
static NSString* OrganizationRevision(NSDictionary* org) {
    NSData* data=org ? [NSJSONSerialization dataWithJSONObject:org options:NSJSONWritingSortedKeys error:nil] : nil;
    if(!data)return nil;unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString* hash=[NSMutableString string];for(unsigned char byte:bytes)[hash appendFormat:@"%02x",byte];return hash;
}
@implementation SPDFMacAIChatStore { NSURL* _directory; }
+ (NSURL*)defaultDirectory {
    NSString* root = NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ShenzhenPDF"];
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Chats"] isDirectory:YES];
}
- (instancetype)initWithDirectory:(NSURL*)directory { if ((self=[super init])) _directory=directory; return self; }
- (NSURL*)URLForID:(NSString*)identifier {
    return ValidID(identifier) ? [_directory URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]] : nil;
}
- (NSDictionary*)rawChatWithID:(NSString*)identifier {
    NSURL* URL=[self URLForID:identifier]; if (!URL) return nil;
    NSNumber* size=nil; [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue>ChatFileLimit) return nil;
    NSData* data=[NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:nil];
    id chat=data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![chat isKindOfClass:NSDictionary.class] || ![chat[@"id"] isEqual:identifier] ||
        ![chat[@"messages"] isKindOfClass:NSArray.class]) return nil;
    if ((chat[@"title"] && ![chat[@"title"] isKindOfClass:NSString.class]) ||
        (chat[@"updated"] && ![chat[@"updated"] isKindOfClass:NSNumber.class]) ||
        [chat[@"messages"] count]>ChatMessageLimit) return nil;
    NSMutableSet* pending=[NSMutableSet set]; NSMutableSet* seen=[NSMutableSet set];
    for (id message in chat[@"messages"]) {
        if (![message isKindOfClass:NSDictionary.class] || ![message[@"role"] isKindOfClass:NSString.class] ||
            (message[@"content"] && message[@"content"]!=NSNull.null && ![message[@"content"] isKindOfClass:NSString.class])) return nil;
        NSString* role=message[@"role"];
        if ([role isEqual:@"preview"]) {
            if (![message[@"local"] isEqual:@YES] || ![message[@"preview"] isKindOfClass:NSDictionary.class]) return nil;
            continue;
        }
        if ([role isEqual:@"compaction"]) {
            if (![message[@"local"] isEqual:@YES] || ![message[@"summary"] isKindOfClass:NSString.class] ||
                ![message[@"summary"] length] || [message[@"summary"] length]>262144 || pending.count) return nil;
            continue;
        }
        if (message[@"local"] || ![@[@"user",@"assistant",@"tool"] containsObject:role]) return nil;
        if ([role isEqual:@"tool"]) {
            NSString* call=message[@"tool_call_id"];
            if (![call isKindOfClass:NSString.class] || ![pending containsObject:call] || ![message[@"content"] isKindOfClass:NSString.class]) return nil;
            [pending removeObject:call]; continue;
        }
        if (pending.count) return nil;
        id calls=message[@"tool_calls"];
        if (calls && (![role isEqual:@"assistant"] || ![calls isKindOfClass:NSArray.class] || [calls count]>12)) return nil;
        for (id call in calls) {
            if (![call isKindOfClass:NSDictionary.class] || ![call[@"id"] isKindOfClass:NSString.class] || ![call[@"id"] length] ||
                [seen containsObject:call[@"id"]] || ![call[@"function"] isKindOfClass:NSDictionary.class]) return nil;
            id function=call[@"function"], raw=function[@"arguments"];
            if (![function[@"name"] isKindOfClass:NSString.class] || ![raw isKindOfClass:NSString.class] || [raw length]>65536) return nil;
            id args=[NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![args isKindOfClass:NSDictionary.class]) return nil;
            [pending addObject:call[@"id"]]; [seen addObject:call[@"id"]];
        }
    }
    // A terminated process may leave a persisted assistant action without its result.
    // Complete those pairs explicitly; never replay the action automatically.
    for (NSString* identifier in pending) [chat[@"messages"] addObject:@{@"role":@"tool",@"tool_call_id":identifier,
        @"content":@"{\"cancelled\":true,\"reason\":\"Previous session ended\"}"}];
    return chat;
}
- (NSDictionary*)chatWithID:(NSString*)identifier {
    NSMutableDictionary* chat=[[self rawChatWithID:identifier] mutableCopy];if(!chat)return nil;
    NSDictionary* metadata=[self organization][@"chats"][identifier];
    if ([metadata[@"title"] isKindOfClass:NSString.class]) chat[@"title"]=metadata[@"title"];
    chat[@"folder"]=metadata[@"folder"] ?: @"";
    return chat;
}
- (NSArray<NSDictionary*>*)chats { return [self chatsMatchingQuery:@""]; }
- (NSArray<NSDictionary*>*)chatsMatchingQuery:(NSString*)query {
    return [self chatsMatchingQuery:query forAssistant:NO];
}
- (NSArray<NSDictionary*>*)chatsMatchingQuery:(NSString*)query forAssistant:(BOOL)forAssistant {
    NSMutableArray* chats=[NSMutableArray array];
    NSDictionary* organization=[self organization];
    NSArray* URLs=[NSFileManager.defaultManager contentsOfDirectoryAtURL:_directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL* URL in URLs) {
        if (![URL.pathExtension isEqual:@"json"]) continue;
        NSMutableDictionary* chat=[[self rawChatWithID:URL.lastPathComponent.stringByDeletingPathExtension] mutableCopy];
        if (!chat) continue;
        NSDictionary* metadata=organization[@"chats"][chat[@"id"]];
        if(metadata[@"title"])chat[@"title"]=metadata[@"title"];
        chat[@"folder"]=metadata[@"folder"] ?: @"";
        NSString* snippet=@"";
        if(query.length && ![chat[@"title"] localizedCaseInsensitiveContainsString:query]) {
            // Not even whether it matched: a listed chat would tell the request what its answers say.
            if (forAssistant && [chat[SPDFMacAIChatTitleSearchOnlyKey] isEqual:@YES]) continue;
            for(NSDictionary* message in [chat[@"messages"] reverseObjectEnumerator]) {
                NSString* text=message[@"content"];
                if (![@[@"user",@"assistant"] containsObject:message[@"role"]] || ![text isKindOfClass:NSString.class]) continue;
                NSRange match=[text rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch];
                if(match.location==NSNotFound) continue;
                NSUInteger start=match.location>55 ? match.location-55 : 0;
                NSUInteger end=MIN(text.length,NSMaxRange(match)+100);
                NSRange range=[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(start,end-start)];
                NSString* context=[text substringWithRange:range];
                context=[[context componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@" "];
                snippet=[NSString stringWithFormat:@"%@%@%@",range.location ? @"…" : @"",context,NSMaxRange(range)<text.length ? @"…" : @""];
                break;
            }
            if (!snippet.length) continue;
        }
        [chats addObject:@{@"id":chat[@"id"],@"title":chat[@"title"] ?: @"New chat",@"updated":chat[@"updated"] ?: @0,
            @"folder":chat[@"folder"] ?: @"",@"snippet":snippet,@"query":query ?: @""}];
    }
    return [chats sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) { return [b[@"updated"] compare:a[@"updated"]]; }];
}
- (int)lockStore:(NSError**)error {
    if (![NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return -1;
    int fd=open([[_directory URLByAppendingPathComponent:@".lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if (fd<0 || flock(fd,LOCK_EX)!=0) { if (fd>=0) close(fd); return -1; } return fd;
}
- (NSURL*)tombstone:(NSString*)identifier {
    return [[_directory URLByAppendingPathComponent:@".deleted"] URLByAppendingPathComponent:identifier];
}
- (BOOL)saveChat:(NSDictionary*)chat error:(NSError**)error {
    return [self saveChat:chat replacingMessages:nil error:error];
}
- (BOOL)saveChat:(NSDictionary*)chat replacingMessages:(NSArray*)expected error:(NSError**)error {
    NSURL* URL=[self URLForID:chat[@"id"]];
    if (!URL || ![NSJSONSerialization isValidJSONObject:chat]) return NO;
    NSData* data=[NSJSONSerialization dataWithJSONObject:chat options:0 error:error];
    if (!data || data.length>ChatFileLimit) return NO;
    // Compare the exact serialized snapshot that will be committed, never mutable caller state.
    chat=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (expected) expected=[NSJSONSerialization isValidJSONObject:expected] ? [NSJSONSerialization JSONObjectWithData:
        [NSJSONSerialization dataWithJSONObject:expected options:0 error:nil] options:0 error:nil] : nil;
    int fd=[self lockStore:error]; if (fd<0) return NO;
    BOOL removed=[NSFileManager.defaultManager fileExistsAtPath:[self tombstone:chat[@"id"]].path];
    BOOL conflict=NO;
    if (!removed && [NSFileManager.defaultManager fileExistsAtPath:URL.path]) {
        NSData* existing=[NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:nil];
        id previous=existing.length<=ChatFileLimit ?
            [NSJSONSerialization JSONObjectWithData:existing options:0 error:nil] : nil;
        NSArray* old=[previous isKindOfClass:NSDictionary.class] ? previous[@"messages"] : nil;
        // An edit or compaction rewrites history the caller has seen; anything else may only append.
        NSArray* incoming=expected ?: chat[@"messages"];
        if (![old isKindOfClass:NSArray.class] || ![incoming isKindOfClass:NSArray.class] || old.count>incoming.count) conflict=YES;
        else for (NSUInteger i=0;i<old.count;i++) if (![old[i] isEqual:incoming[i]]) { conflict=YES; break; }
    }
    BOOL ok=!removed && !conflict && [data writeToURL:URL options:NSDataWritingAtomic error:error];
    if (conflict && error) *error=[NSError errorWithDomain:@"ShenzhenPDF.Chat" code:2 userInfo:@{NSLocalizedDescriptionKey:@"This chat changed in another window. Reopen it from Chats before continuing. Your unsaved conversation remains visible here."}];
    if (removed && error) *error=[NSError errorWithDomain:@"ShenzhenPDF.Chat" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This chat was deleted in another window. Start a new chat."}];
    if (ok) chmod(URL.fileSystemRepresentation,0600);
    flock(fd,LOCK_UN); close(fd); return ok;
}
// Explicit history operations only; constructing the store does no I/O.
- (NSMutableDictionary*)organization {
    NSURL* URL=[_directory URLByAppendingPathComponent:@".organization.json"];
    if(![NSFileManager.defaultManager fileExistsAtPath:URL.path])
        return [@{@"folders":[NSMutableArray array],@"chats":[NSMutableDictionary dictionary]} mutableCopy];
    NSNumber* size=nil;[URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if(!size || size.unsignedLongLongValue>1024*1024)return nil;
    NSData* data=[NSData dataWithContentsOfURL:URL];
    id value=data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![value isKindOfClass:NSMutableDictionary.class] || ![value[@"folders"] isKindOfClass:NSMutableArray.class] ||
        ![value[@"chats"] isKindOfClass:NSMutableDictionary.class])return nil;
    if(value[@"generalCollapsed"] && ![value[@"generalCollapsed"] isKindOfClass:NSNumber.class])return nil;
    NSMutableSet* identifiers=[NSMutableSet set];
    for(id folder in value[@"folders"]) {
        if(![folder isKindOfClass:NSDictionary.class] || !ValidID(folder[@"id"]) ||
            ![folder[@"name"] isKindOfClass:NSString.class] || ![folder[@"name"] length] ||
            (folder[@"collapsed"] && ![folder[@"collapsed"] isKindOfClass:NSNumber.class]) ||
            [identifiers containsObject:folder[@"id"]])return nil;
        [identifiers addObject:folder[@"id"]];
    }
    for(NSString* identifier in value[@"chats"]) {
        id metadata=value[@"chats"][identifier];
        if(!ValidID(identifier) || ![metadata isKindOfClass:NSDictionary.class])return nil;
        for(NSString* key in @[@"title",@"folder"])if(metadata[key] && ![metadata[key] isKindOfClass:NSString.class])return nil;
        for(NSString* key in @[@"customTitle",@"titleSuggested"])if(metadata[key] && ![metadata[key] isKindOfClass:NSNumber.class])return nil;
    }
    return value;
}
- (BOOL)writeOrganization:(NSDictionary*)organization error:(NSError**)error {
    if(!organization)return NO;
    NSData* data=[NSJSONSerialization dataWithJSONObject:organization options:0 error:error];
    if(!data || data.length>1024*1024){
        if(error && !*error)*error=[NSError errorWithDomain:@"ShenzhenPDF.Chat" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Chat organization is too large to save. Existing folders and titles are unchanged."}];
        return NO;
    }
    NSURL* URL=[_directory URLByAppendingPathComponent:@".organization.json"];
    BOOL ok=[data writeToURL:URL options:NSDataWritingAtomic error:error];
    if(ok)chmod(URL.fileSystemRepresentation,0600);return ok;
}
- (BOOL)organizationChatExists:(NSString*)identifier {
    return ValidID(identifier) && ![NSFileManager.defaultManager fileExistsAtPath:[self tombstone:identifier].path] &&
        [NSFileManager.defaultManager fileExistsAtPath:[self URLForID:identifier].path];
}
- (BOOL)editOrganization:(BOOL (^)(NSMutableDictionary*))edit error:(NSError**)error {
    int fd=[self lockStore:error]; if(fd<0)return NO;
    BOOL ok=NO;
    @try {
        NSMutableDictionary* organization=[self organization];
        if(!organization && error)*error=[NSError errorWithDomain:@"ShenzhenPDF.Chat" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Chat organization could not be read. Its saved file has been preserved; no folders or titles were changed."}];
        if(organization && edit(organization))ok=[self writeOrganization:organization error:error];
    } @finally {flock(fd,LOCK_UN);close(fd);}
    return ok;
}
- (NSString*)cleanName:(NSString*)name {
    if(![name isKindOfClass:NSString.class])return nil;
    name=[[name componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length && name.length<=160 ? name : nil;
}
- (NSArray<NSDictionary*>*)folders {
    NSDictionary* org=[self organization]; if(!org)return @[];
    NSMutableArray* folders=[NSMutableArray arrayWithObject:@{@"id":@"",@"name":@"General",@"system":@YES,
        @"collapsed":org[@"generalCollapsed"] ?: @NO}];
    [folders addObjectsFromArray:org[@"folders"]];return folders;
}
- (NSString*)createFolderNamed:(NSString*)name error:(NSError**)error {
    name=[self cleanName:name];if(!name || [name localizedCaseInsensitiveCompare:@"General"]==NSOrderedSame)return nil;NSString* identifier=NSUUID.UUID.UUIDString;
    BOOL ok=[self editOrganization:^BOOL(NSMutableDictionary* org){
        for(NSDictionary* folder in org[@"folders"])if([folder[@"name"] localizedCaseInsensitiveCompare:name]==NSOrderedSame)return NO;
        [org[@"folders"] addObject:[@{@"id":identifier,@"name":name,@"collapsed":@NO} mutableCopy]];return YES;
    } error:error];return ok ? identifier : nil;
}
- (BOOL)renameFolder:(NSString*)identifier name:(NSString*)name error:(NSError**)error {
    name=[self cleanName:name];if(!name || [name localizedCaseInsensitiveCompare:@"General"]==NSOrderedSame)return NO;
    return [self editOrganization:^BOOL(NSMutableDictionary* org){
        for(NSDictionary* folder in org[@"folders"])if(![folder[@"id"] isEqual:identifier] && [folder[@"name"] localizedCaseInsensitiveCompare:name]==NSOrderedSame)return NO;
        for(NSMutableDictionary* folder in org[@"folders"])if([folder[@"id"] isEqual:identifier]){folder[@"name"]=name;return YES;}return NO;
    } error:error];
}
- (BOOL)removeFolder:(NSString*)identifier error:(NSError**)error {
    return [self editOrganization:^BOOL(NSMutableDictionary* org){
        NSMutableArray* folders=org[@"folders"];
        NSUInteger index=[folders indexOfObjectPassingTest:^BOOL(NSDictionary* folder,NSUInteger i,BOOL* stop){(void)i;(void)stop;return [folder[@"id"] isEqual:identifier];}];
        if(index==NSNotFound)return NO;[folders removeObjectAtIndex:index];
        for(NSMutableDictionary* metadata in [org[@"chats"] allValues])if([metadata[@"folder"] isEqual:identifier])[metadata removeObjectForKey:@"folder"];
        return YES;
    } error:error];
}
- (BOOL)setFolder:(NSString*)folderID collapsed:(BOOL)collapsed error:(NSError**)error {
    return [self editOrganization:^BOOL(NSMutableDictionary* org){
        if(!folderID.length){org[@"generalCollapsed"]=@(collapsed);return YES;}
        for(NSMutableDictionary* folder in org[@"folders"])if([folder[@"id"] isEqual:folderID]){folder[@"collapsed"]=@(collapsed);return YES;}return NO;
    } error:error];
}
- (BOOL)moveChat:(NSString*)identifier toFolder:(NSString*)folderID error:(NSError**)error {
    if(![self chatWithID:identifier])return NO;
    return [self editOrganization:^BOOL(NSMutableDictionary* org){
        if(![self organizationChatExists:identifier])return NO;
        BOOL found=!folderID.length;for(NSDictionary* folder in org[@"folders"])if([folder[@"id"] isEqual:folderID])found=YES;
        if(!found)return NO;
        if(![self organizationChatExists:identifier])return NO;
        NSMutableDictionary* metadata=org[@"chats"][identifier] ?: [NSMutableDictionary dictionary];
        metadata[@"folder"]=folderID ?: @"";org[@"chats"][identifier]=metadata;return YES;
    } error:error];
}
- (BOOL)renameChat:(NSString*)identifier title:(NSString*)title error:(NSError**)error {
    title=[self cleanName:title];if(!title || ![self chatWithID:identifier])return NO;
    return [self editOrganization:^BOOL(NSMutableDictionary* org){
        if(![self organizationChatExists:identifier])return NO;
        NSMutableDictionary* metadata=org[@"chats"][identifier] ?: [NSMutableDictionary dictionary];
        metadata[@"title"]=title;metadata[@"customTitle"]=@YES;org[@"chats"][identifier]=metadata;return YES;
    } error:error];
}
- (BOOL)shouldSuggestTitleForChatID:(NSString*)identifier {
    if(!ValidID(identifier))return NO;NSDictionary* organization=[self organization];if(!organization)return NO;
    NSDictionary* metadata=organization[@"chats"][identifier];
    return ![metadata[@"customTitle"] boolValue] && ![metadata[@"titleSuggested"] boolValue];
}
- (BOOL)setSuggestedTitle:(NSString*)title forChatID:(NSString*)identifier error:(NSError**)error {
    title=[self cleanName:title];if(!title || ![self chatWithID:identifier])return NO;
    return [self editOrganization:^BOOL(NSMutableDictionary* org){
        if(![self organizationChatExists:identifier])return NO;
        NSMutableDictionary* metadata=org[@"chats"][identifier] ?: [NSMutableDictionary dictionary];
        if([metadata[@"customTitle"] boolValue] || [metadata[@"titleSuggested"] boolValue])return NO;
        metadata[@"title"]=title;metadata[@"titleSuggested"]=@YES;org[@"chats"][identifier]=metadata;return YES;
    } error:error];
}
- (NSDictionary*)savePreview:(NSDictionary*)preview chatID:(NSString*)identifier {
    if (!ValidID(identifier) || ![preview[@"path"] isKindOfClass:NSString.class]) return nil;
    NSURL* source=[NSURL fileURLWithPath:preview[@"path"]];
    NSDictionary* result=nil;
    @try {
        NSNumber* size=nil; [source getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!size || size.unsignedLongLongValue>8*1024*1024) return nil;
        NSData* data=[NSData dataWithContentsOfURL:source options:0 error:nil];
        static const unsigned char signature[]={137,80,78,71,13,10,26,10};
        if (data.length<8 || memcmp(data.bytes,signature,8)!=0) return nil;
        int fd=[self lockStore:nil]; if (fd<0) return nil;
        @try {
            if ([NSFileManager.defaultManager fileExistsAtPath:[self tombstone:identifier].path]) return nil;
            NSURL* assets=[_directory URLByAppendingPathComponent:[identifier stringByAppendingString:@"-assets"] isDirectory:YES];
            if (![NSFileManager.defaultManager createDirectoryAtURL:assets withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) return nil;
            NSURL* target=[assets URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
            if (![data writeToURL:target options:NSDataWritingAtomic error:nil]) return nil;
            chmod(target.fileSystemRepresentation,0600);
            NSMutableDictionary* saved=[preview mutableCopy]; saved[@"path"]=target.path; result=saved;
        } @finally { flock(fd,LOCK_UN); close(fd); }
    } @finally { [SPDFMacAIChatStore discardTemporaryPreview:preview]; }
    return result;
}
- (void)removeUnusedPreviewsForChatID:(NSString*)identifier {
    NSURL* URL=[self URLForID:identifier]; if (!URL) return;
    int fd=[self lockStore:nil]; if (fd<0) return;
    // Only the saved chat says which pictures are still shown; without it nothing is removed.
    NSData* data=[NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:nil];
    id chat=data.length && data.length<=ChatFileLimit ?
        [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray* messages=[chat isKindOfClass:NSDictionary.class] ? chat[@"messages"] : nil;
    NSMutableSet* shown=[NSMutableSet set];
    for (NSDictionary* message in [messages isKindOfClass:NSArray.class] ? messages : @[]) {
        NSDictionary* preview=[message isKindOfClass:NSDictionary.class] ? message[@"preview"] : nil;
        if ([preview isKindOfClass:NSDictionary.class] && [preview[@"path"] isKindOfClass:NSString.class])
            [shown addObject:[preview[@"path"] lastPathComponent]];
    }
    NSString* assets=[_directory URLByAppendingPathComponent:[identifier stringByAppendingString:@"-assets"]].path;
    NSArray* names=[messages isKindOfClass:NSArray.class] ?
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:assets error:nil] : nil;
    for (NSString* name in names) {
        // Only pictures this store saved: a UUID-named PNG that is a plain file, never a link.
        NSString* path=[assets stringByAppendingPathComponent:name]; struct stat info;
        if ([shown containsObject:name] || ![name.pathExtension isEqual:@"png"] ||
            !ValidID(name.stringByDeletingPathExtension) || lstat(path.fileSystemRepresentation,&info) ||
            !S_ISREG(info.st_mode)) continue;
        unlink(path.fileSystemRepresentation);
    }
    flock(fd,LOCK_UN); close(fd);
}
// This is the only model-facing saved-preview read. Saved JSON is not a trusted path.
- (NSData*)previewData:(NSDictionary*)preview chatID:(NSString*)identifier {
    if (![preview isKindOfClass:NSDictionary.class]) return nil;
    NSString* path=preview[@"path"];
    if (!ValidID(identifier) || ![path isKindOfClass:NSString.class]) return nil;
    NSString* root=_directory.path.stringByResolvingSymlinksInPath;
    NSString* assets=[root stringByAppendingPathComponent:[identifier stringByAppendingString:@"-assets"]];
    NSString* name=path.lastPathComponent;
    if (![name.pathExtension isEqual:@"png"] || !ValidID(name.stringByDeletingPathExtension) ||
        ![path.stringByResolvingSymlinksInPath.stringByDeletingLastPathComponent isEqual:assets]) return nil;
    int directory=open(assets.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if (directory<0) return nil;
    int file=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK); close(directory);
    if (file<0) return nil;
    struct stat info; NSData* result=nil;
    if (fstat(file,&info)==0 && S_ISREG(info.st_mode) && info.st_size>0 && info.st_size<=8*1024*1024) {
        NSMutableData* data=[NSMutableData dataWithLength:(NSUInteger)info.st_size]; NSUInteger offset=0;
        while (offset<data.length) {
            ssize_t count=read(file,(char*)data.mutableBytes+offset,data.length-offset);
            if (count<=0) break; offset+=(NSUInteger)count;
        }
        if (offset==data.length) result=data;
    }
    close(file); return result;
}
+ (void)discardTemporaryPreview:(NSDictionary*)preview {
    NSString* path=preview[@"path"];
    if (![path isKindOfClass:NSString.class]) return;
    NSString* parent=path.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
    NSString* temp=NSTemporaryDirectory().stringByResolvingSymlinksInPath;
    // render_page writes page.png and current_view viewport.png; a name outside these is not a preview folder.
    if ([@[@"page.png",@"viewport.png"] containsObject:path.lastPathComponent] &&
        [parent.stringByDeletingLastPathComponent isEqual:temp] &&
        [parent.lastPathComponent hasPrefix:@"ShenzhenPDF-AI-"] &&
        ValidID([parent.lastPathComponent substringFromIndex:[@"ShenzhenPDF-AI-" length]]))
        [NSFileManager.defaultManager removeItemAtPath:parent error:nil];
}
- (BOOL)deleteUnlocked:(NSString*)identifier error:(NSError**)error {
    NSURL* URL=[self URLForID:identifier]; if (!URL) return NO;
    NSURL* tombstone=[self tombstone:identifier];
    if (![NSFileManager.defaultManager createDirectoryAtURL:tombstone.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error] ||
        ![[NSData data] writeToURL:tombstone options:NSDataWritingAtomic error:error]) return NO;
    BOOL ok=![NSFileManager.defaultManager fileExistsAtPath:URL.path] || [NSFileManager.defaultManager removeItemAtURL:URL error:error];
    NSURL* assets=[_directory URLByAppendingPathComponent:[identifier stringByAppendingString:@"-assets"]];
    if ([NSFileManager.defaultManager fileExistsAtPath:assets.path]) ok=[NSFileManager.defaultManager removeItemAtURL:assets error:error] && ok;
    return ok;
}
- (BOOL)deleteChatWithID:(NSString*)identifier error:(NSError**)error {
    int fd=[self lockStore:error]; if (fd<0) return NO;
    BOOL ok=[self deleteUnlocked:identifier error:error];
    NSMutableDictionary* org=[self organization];
    if(ok && org){[org[@"chats"] removeObjectForKey:identifier];ok=[self writeOrganization:org error:error];}
    flock(fd,LOCK_UN); close(fd); return ok;
}
- (BOOL)deleteAll:(NSError**)error {
    int fd=[self lockStore:error]; if (fd<0) return NO;
    NSArray* URLs=[NSFileManager.defaultManager contentsOfDirectoryAtURL:_directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:error];
    NSMutableSet* identifiers=[NSMutableSet set];
    for (NSURL* URL in URLs) {
        NSString* name=URL.lastPathComponent;
        NSString* identifier=[name hasSuffix:@"-assets"] ? [name substringToIndex:name.length-7] : name.stringByDeletingPathExtension;
        if (ValidID(identifier) && ([name hasSuffix:@"-assets"] || [name.pathExtension isEqual:@"json"])) [identifiers addObject:identifier];
    }
    BOOL ok=URLs!=nil;
    for (NSString* identifier in identifiers) if (![self deleteUnlocked:identifier error:error]) ok=NO;
    NSMutableDictionary* org=[self organization];
    if(ok && org){[org[@"chats"] removeAllObjects];ok=[self writeOrganization:org error:error];}
    flock(fd,LOCK_UN); close(fd); return ok;
}

- (NSDictionary*)organizationSnapshot {
    NSDictionary* org=[self organization];return org ? @{@"state":org,@"revision":OrganizationRevision(org)} : nil;
}
- (NSDictionary*)organizeChats:(NSArray*)operations expectedRevision:(NSString*)revision progress:(NSProgress*)progress error:(NSError**)error {
    if(![operations isKindOfClass:NSArray.class] || !operations.count || operations.count>200 || ![revision isKindOfClass:NSString.class])return nil;
    __block NSDictionary* receipt=nil;
    BOOL ok=[self editOrganization:^BOOL(NSMutableDictionary* org){
        if(progress.cancelled || ![OrganizationRevision(org) isEqual:revision])return NO;
        NSDictionary* before=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:org options:0 error:nil] options:0 error:nil];
        for(id op in operations) {
            if(![op isKindOfClass:NSDictionary.class] || progress.cancelled)return NO;
            NSString* kind=op[@"operation"],*name=[self cleanName:op[@"name"]];
            NSString* identifier=op[@"chatID"],*folderID=op[@"folderID"];
            if([kind isEqual:@"create_folder"]) {
                if(!name || [name localizedCaseInsensitiveCompare:@"General"]==NSOrderedSame)return NO;
                for(NSDictionary* folder in org[@"folders"])if([folder[@"name"] localizedCaseInsensitiveCompare:name]==NSOrderedSame)return NO;
                [org[@"folders"] addObject:[@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"collapsed":@NO} mutableCopy]];
            } else if([kind isEqual:@"move_chat"] || [kind isEqual:@"rename_chat"]) {
                if(![self organizationChatExists:identifier])return NO;
                NSMutableDictionary* metadata=org[@"chats"][identifier] ?: [NSMutableDictionary dictionary];
                if([kind isEqual:@"rename_chat"]) {
                    if(!name)return NO;metadata[@"title"]=name;metadata[@"customTitle"]=@YES;
                } else {
                    if(op[@"folderName"]) {
                        NSString* wanted=[self cleanName:op[@"folderName"]];if(!wanted)return NO;folderID=nil;
                        if([wanted localizedCaseInsensitiveCompare:@"General"]==NSOrderedSame)folderID=@"";
                        for(NSDictionary* folder in org[@"folders"])if([folder[@"name"] localizedCaseInsensitiveCompare:wanted]==NSOrderedSame)folderID=folder[@"id"];
                    }
                    BOOL found=[folderID isKindOfClass:NSString.class] && !folderID.length;
                    for(NSDictionary* folder in org[@"folders"])if([folder[@"id"] isEqual:folderID])found=YES;
                    if(!found)return NO;metadata[@"folder"]=folderID;
                }
                org[@"chats"][identifier]=metadata;
            } else if([kind isEqual:@"rename_folder"]) {
                if(!name || !ValidID(folderID) || [name localizedCaseInsensitiveCompare:@"General"]==NSOrderedSame)return NO;
                BOOL found=NO;
                for(NSMutableDictionary* folder in org[@"folders"]) {
                    if(![folder[@"id"] isEqual:folderID] && [folder[@"name"] localizedCaseInsensitiveCompare:name]==NSOrderedSame)return NO;
                    if([folder[@"id"] isEqual:folderID]){folder[@"name"]=name;found=YES;}
                }
                if(!found)return NO;
            } else return NO;
        }
        if(progress.cancelled)return NO;
        receipt=@{@"before":before,@"after":OrganizationRevision(org)};return YES;
    } error:error];
    if(!ok && error && !*error)*error=[NSError errorWithDomain:@"ShenzhenPDF.Chat" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Chat folders changed or an operation is invalid. List chats again before retrying; nothing was changed."}];
    return ok ? receipt : nil;
}
- (NSDictionary*)swapOrganizationReceipt:(NSDictionary*)receipt progress:(NSProgress*)progress error:(NSError**)error {
    __block NSDictionary* reverse=nil;
    BOOL ok=[self editOrganization:^BOOL(NSMutableDictionary* org){
        if(progress.cancelled || ![OrganizationRevision(org) isEqual:receipt[@"after"]] || ![receipt[@"before"] isKindOfClass:NSDictionary.class])return NO;
        NSDictionary* current=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:org options:0 error:nil] options:0 error:nil];
        [org setDictionary:receipt[@"before"]];reverse=@{@"before":current,@"after":OrganizationRevision(org)};return !progress.cancelled;
    } error:error];return ok ? reverse : nil;
}
@end
