#import "SPDFMacAISaveFileToolProvider.h"

#import "SPDFMacAIChatSessionGrants.h"

NSString* const SPDFMacAISaveFileToolName = @"save_file";
NSString* const SPDFMacAISaveFilePromptGuidance =
    @"You can save files to the person's Downloads folder, or a folder inside it, with save_file (text, bytes, or a "
    @"copy of a document you can see, read-only ones included) and with run_python's ./out. Do so whenever they ask "
    @"to save, export, download or keep something; never ask them to do it themselves. You can't list or read "
    @"Downloads, except the files saved in this chat, by the id each save returns.";

static const NSUInteger kSPDFMaxText = 8 * 1024 * 1024, kSPDFMaxBytes = 16 * 1024 * 1024;
static const unsigned long long kSPDFMaxCopy = 512ull * 1024 * 1024;

static NSDictionary* Refusal(NSString* text) { return @{@"error" : text}; }

@implementation SPDFMacAISaveFileToolProvider

- (NSString*)providerIdentifier { return @"save-file"; }
- (BOOL)providesTool:(NSString*)name { return [name isEqual:SPDFMacAISaveFileToolName]; }
- (BOOL)isReadOnlyTool:(NSString*)name { (void)name; return NO; }
- (void)cancel {}

- (BOOL)offeredInContext:(SPDFMacAIRequestContext*)context {
    return self.saver && !context.depth && !context.includesFriendsChats;
}

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    if (![self offeredInContext:context]) return @[];
    return @[ @{@"type" : @"function", @"function" : @{
        @"name" : SPDFMacAISaveFileToolName,
        @"description" :
            @"Save a file to the person's Downloads folder, or a folder inside it: text you write (content), bytes "
            @"(base64), or a copy of a document you can see (document: a doc:, collection: or attachment: id, "
            @"read-only documents included). Use it whenever the person asks to save, export, download or keep "
            @"something. Any file type. It never replaces a file: a name already taken becomes \"name 2.ext\". PDF "
            @"and Markdown also go to Collection. The chat shows a card with Open and Show in Finder. Downloads is not "
            @"readable; the result's id reads this file back in this chat (read_attachment, or run_python's "
            @"documents).",
        @"parameters" : @{@"type" : @"object", @"additionalProperties" : @NO, @"required" : @[ @"name" ],
            @"properties" : @{
                @"name" : @{@"type" : @"string", @"description" : @"File name with its extension, e.g. Notes.md. For "
                                                                  @"a document copy the extension may be left out."},
                @"folder" : @{@"type" : @"string", @"description" : @"A folder inside Downloads, e.g. "
                                                                    @"\"Datasheets/Fans\"; made if missing. Default: "
                                                                    @"Downloads itself."},
                @"content" : @{@"type" : @"string", @"description" : @"The file's text (UTF-8)."},
                @"base64" : @{@"type" : @"string", @"description" : @"The file's bytes, base64."},
                @"document" : @{@"type" : @"string", @"description" : @"doc:, collection: or attachment: id of a "
                                                                      @"document to save a copy of."}}}}} ];
}

- (nullable NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name;
    return context.depth ? @"Only the main conversation saves files. Return the content instead."
                         : @"Files are not saved in requests that include Friends chats.";
}

- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context {
    NSDictionary* system = messages.firstObject;
    if (![self offeredInContext:context] || ![system[@"role"] isEqual:@"system"] ||
        ![system[@"content"] isKindOfClass:NSString.class]) return messages;
    NSMutableArray* told = [messages mutableCopy];
    told[0] = @{@"role" : @"system",
                @"content" : [system[@"content"] stringByAppendingFormat:@" %@", SPDFMacAISaveFilePromptGuidance]};
    return told;
}

static NSString* NameProblem(id name) {
    if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 120 || [name hasPrefix:@"."] ||
        [name containsString:@"/"] || [name containsString:@":"] ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return @"name must be a plain file name of at most 120 characters: no folders (use folder), no leading dot.";
    return nil;
}

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    (void)name;
    if (![self offeredInContext:context]) { completion(Refusal([self unavailableMessageForTool:name context:context])); return; }
    for (NSString* key in arguments)
        if (![@[ @"name", @"folder", @"content", @"base64", @"document" ] containsObject:key]) {
            completion(Refusal([NSString stringWithFormat:@"Unknown argument %@.", key]));
            return;
        }
    NSString* fileName = arguments[@"name"], *problem = NameProblem(fileName);
    id folder = arguments[@"folder"] ?: @"";
    NSUInteger sources = (arguments[@"content"] != nil) + (arguments[@"base64"] != nil) + (arguments[@"document"] != nil);
    if (!problem && ![folder isKindOfClass:NSString.class]) problem = @"folder must be a path inside Downloads.";
    if (!problem && sources != 1) problem = @"Give exactly one of content, base64 or document.";
    NSData* data = nil;
    if (!problem && arguments[@"content"]) {
        data = [arguments[@"content"] isKindOfClass:NSString.class] ?
            [arguments[@"content"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        if (!data || data.length > kSPDFMaxText) problem = @"content must be text of at most 8 MB.";
    } else if (!problem && arguments[@"base64"]) {
        data = [arguments[@"base64"] isKindOfClass:NSString.class] ?
            [[NSData alloc] initWithBase64EncodedString:arguments[@"base64"]
                                                options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
        if (!data || data.length > kSPDFMaxBytes) problem = @"base64 must be valid base64 of at most 16 MB.";
    }
    if (problem) { completion(Refusal(problem)); return; }
    __weak SPDFMacAISaveFileToolProvider* weakSelf = self;
    void (^save)(NSData* (^)(NSError**), NSString*) = ^(NSData* (^read)(NSError**), NSString* finalName) {
        SPDFMacAISaveFileSaver saver = weakSelf.saver;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError* error = nil;
            NSData* bytes = read(&error);
            NSDictionary* receipt = bytes && saver ? saver(bytes, folder, finalName, &error) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString* path = receipt[@"path"];
                if (!path) {
                    completion(Refusal(error.localizedDescription ?: @"The file could not be saved."));
                    return;
                }
                SPDFMacAISaveFileToolProvider* owner = weakSelf;
                if (owner.presenter && context.activity) owner.presenter(context.activity, path);
                NSMutableDictionary* result = [@{@"saved_as" : path.lastPathComponent, @"folder" :
                    [@"Downloads" stringByAppendingPathComponent:folder]} mutableCopy];
                NSString* identifier = [context.session addSavedFileAtPath:path];
                if (identifier) result[@"id"] = identifier;
                completion(result);
            });
        });
    };
    if (data) { save(^NSData*(NSError** error) { (void)error; return data; }, fileName); return; }
    NSString* identifier = arguments[@"document"];
    if (!SPDFMacAIPythonDocumentIdentifierValid(identifier) || !self.documentResolver) {
        completion(Refusal(@"document must be a doc: id from list_workspace, a collection: id from list_collection, "
                           @"or an attachment: id of this chat."));
        return;
    }
    self.documentResolver(@[ @{@"id" : identifier} ], context, ^(NSArray<SPDFMacAIPythonDocument*>* documents,
                                                                 NSString* why) {
        NSString* path = documents.firstObject.path;
        if (!path) { completion(Refusal(why ?: @"The document was not found.")); return; }
        NSString* extension = path.pathExtension;
        NSString* finalName = fileName.pathExtension.length || !extension.length ? fileName :
            [fileName stringByAppendingPathExtension:extension];
        save(^NSData*(NSError** error) {
            NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
            if (attributes && attributes.fileSize > kSPDFMaxCopy) {
                if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.AI.Save" code:1 userInfo:@{
                    NSLocalizedDescriptionKey : @"The document is larger than 512 MB."}];
                return nil;
            }
            return attributes ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error] : nil;
        }, finalName);
    });
}

@end
