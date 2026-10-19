#import "SPDFMacAgentCommand.h"
#import "SPDFMacAgentSavedSession.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacAgentPDFInspection.h"
#import "SPDFMacMarkdownRouting.h"
#import "markdown/SPDFMarkdownAuthoring.h"
#import "markdown/SPDFMarkdownParser.h"
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
#import <unistd.h>

static NSError* agentError(NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.Agent" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSArray* renderPages(SPDFMarkdownPaginationPlan* plan, SPDFMarkdownRenderedDocument* rendered,
                            NSString* directory, NSNumber* requestedPage, NSError** error) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSUInteger first = requestedPage ? requestedPage.unsignedIntegerValue - 1 : 0;
    NSUInteger count = requestedPage ? 1 : plan.pages.count;
    if (first >= plan.pages.count || count > 100) { *error = agentError(@"Render at most 100 pages; use page to select a single page."); return nil; }
    CGSize size = plan.configuration.paperSize;
    size_t width = (size_t)ceil(size.width), height = (size_t)ceil(size.height);
    if (!width || !height || width > 4096 || height > 4096) { *error = agentError(@"Paper exceeds PNG dimension budget."); return nil; }
    // Exclusive new directory avoids replacing any user artifact.
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0) { *error = agentError(@"Render directory must be new and its parent must exist."); return nil; }
    NSMutableArray* paths = [NSMutableArray array];
    for (NSUInteger index = first; index < first + count; index++) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        if (!context) { [fm removeItemAtPath:directory error:nil]; *error = agentError(@"Could not allocate page image."); return nil; }
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        BOOL drawn = [plan drawPageAtIndex:index attributedString:rendered.attributedString inContext:context];
        CGImageRef image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"page-%04lu.png", (unsigned long)index + 1]];
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
        BOOL written = NO;
        if (destination && image && drawn) { CGImageDestinationAddImage(destination, image, NULL); written = CGImageDestinationFinalize(destination); }
        if (destination) CFRelease(destination);
        if (image) CGImageRelease(image);
        if (!written) { [fm removeItemAtPath:directory error:nil]; *error = agentError(@"Could not write page image."); return nil; }
        [paths addObject:path];
    }
    return paths;
}

static NSDictionary* inspect(NSDictionary* command, NSError** error) {
    NSString* path = command[@"path"];
    if ([path.pathExtension.lowercaseString isEqual:@"pdf"]) return SPDFMacAgentInspectPDF(command, error);
    if (!SPDFIsRenderedTextDocumentPath(path)) {
        *error = agentError(@"Inspection supports PDF, Markdown, text and supported source documents."); return nil;
    }
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] loadURL:[NSURL fileURLWithPath:path] error:error];
    if (!model) return nil;
    NSMutableDictionary* frontMatter = [model.frontMatter mutableCopy] ?: [NSMutableDictionary dictionary];
    [frontMatter addEntriesFromDictionary:command[@"paper"] ?: @{}];
    SPDFMarkdownPageConfiguration* config = SPDFMarkdownPageConfigurationForFrontMatter(frontMatter, [SPDFMarkdownPageConfiguration A4PortraitConfiguration], error);
    if (!config) return nil;
    config.includesCodeLanguageControlSpacing = YES;
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptions];
    options.pageContentSize = config.printableRect.size;
    SPDFMarkdownRenderedDocument* rendered = [[SPDFMarkdownRenderer new] renderModel:model options:options languageOverrides:nil];
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    SPDFMarkdownPaginationPlan* plan = [paginator paginateItems:[paginator measureRenderedDocument:rendered containerWidth:config.printableRect.size.width] configuration:config];
    if (command[@"page"] && [command[@"page"] unsignedIntegerValue] > plan.pages.count) {
        *error = agentError(@"Page is outside the document."); return nil;
    }
    NSMutableDictionary* result = [SPDFMarkdownLayoutReport(model, rendered, plan) mutableCopy];
    if (command[@"renderDirectory"]) {
        NSArray* images = renderPages(plan, rendered, command[@"renderDirectory"], command[@"page"], error);
        if (!images) return nil;
        result[@"images"] = images;
    }
    result[@"path"] = path;
    return result;
}

static NSDictionary* navigate(NSDictionary* command, NSError** error) {
    if (![command[@"action"] isEqual:@"open"] && !SPDFMacAgentReaderIsRunning())
        return SPDFMacAgentSavedSession(command,SPDFMacStateDirectoryPath(),error);
    NSString* directory = SPDFMacAgentRequestDirectory();
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSString* path = [directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"spdf-command"]];
    NSString* responsePath = [path stringByAppendingPathExtension:@"response"];
    NSData* data = [NSJSONSerialization dataWithJSONObject:command options:0 error:error];
    if (![data writeToFile:path options:NSDataWritingWithoutOverwriting error:error]) return nil;
    chmod(path.fileSystemRepresentation, 0600);
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-a", NSBundle.mainBundle.bundlePath, path];
    if (![task launchAndReturnError:error]) { [fm removeItemAtPath:path error:nil]; return nil; }
    [task waitUntilExit];
    NSDictionary* response = nil;
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (task.terminationStatus == 0 && deadline.timeIntervalSinceNow > 0) {
        NSData* bytes = [NSData dataWithContentsOfFile:responsePath];
        if (bytes) { response = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:error]; break; }
        [NSThread sleepForTimeInterval:0.05];
    }
    [fm removeItemAtPath:path error:nil];
    [fm removeItemAtPath:responsePath error:nil];
    if (!response) *error = agentError(@"Reader did not complete the command within 30 seconds.");
    return response;
}

int SPDFMacRunAgentCommand(const char* json) {
    @autoreleasepool {
        NSError* error = nil;
        NSData* data = json ? [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        NSDictionary* command = SPDFMacValidateAgentCommand(data, &error);
        NSDictionary* result = command ? ([command[@"action"] isEqual:@"inspect"] ? inspect(command, &error) : navigate(command, &error)) : nil;
        if (!result) result = @{@"error": error.localizedDescription ?: @"Agent command failed."};
        NSData* output = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
        if (!output || output.length > 32 * 1024 * 1024) { result = @{@"error":@"Output budget exceeded."}; output = [@"{\"error\":\"Report exceeds 32 MiB output budget.\"}" dataUsingEncoding:NSUTF8StringEncoding]; }
        fwrite(output.bytes, 1, output.length, stdout); fputc('\n', stdout);
        return result[@"error"] ? 1 : 0;
    }
}
