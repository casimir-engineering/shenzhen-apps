// Opt-in, read-only model benchmark. Never linked into the application.
// All prompt, session, tool definitions, retrieval, vision and card validation
// come from the production objects; only telemetry and paid title generation differ.
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAICredentials.h"
#import "SPDFMacAIReaderControls.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacSearchFileCache.h"
#include "input.h"
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#include <float.h>
#include <math.h>
#include <unistd.h>
// One session runs at a time. Each response retains its own case bucket,
// including cancellation callbacks arriving after a case deadline.
static NSMutableArray *Requests;
static double MeasuredCost = 0;
static BOOL MissingCost = NO;
static BOOL MissingSuccessfulCost = NO;
static double CostLimit = .75;
static id Clean(id value) {
    if ([value isKindOfClass:NSData.class])
        return @"[binary omitted]";
    if ([value isKindOfClass:NSString.class]) {
        if ([value hasPrefix:@"data:image/"])
            return @"[image omitted]";
        NSString *text =
            [value stringByReplacingOccurrencesOfString:@"data:image/[^;,]+;base64,[A-Za-z0-9+/=]+"
                                             withString:@"[image omitted]"
                                                options:NSRegularExpressionSearch
                                                  range:NSMakeRange(0, [value length])];
        return [text stringByReplacingOccurrencesOfString:@"sk-or-[A-Za-z0-9-]+"
                                               withString:@"[credential omitted]"
                                                  options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, [text length])];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id v in value)
            [out addObject:Clean(v) ?: NSNull.null];
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *k in value) {
            if ([@[ @"authorization", @"apikey", @"api_key", @"x-api-key" ]
                    containsObject:k.lowercaseString]) {
                out[k] = @"[credential omitted]";
                continue;
            }
            if ([@[ @"image_url", @"reasoning_details", @"reasoning", @"_localPreview" ] containsObject:k])
                continue;
            out[Clean(k)] = Clean(value[k]) ?: NSNull.null;
        }
        return out;
    }
    return value;
}
static NSString *Hash(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [out appendFormat:@"%02x", digest[i]];
    return out;
}
// Fixed USD per million input/output tokens, applied to every request and retry.
NSDictionary *SZBenchmarkProviderOptions(void) {
    return @{@"max_price" : @{@"prompt" : @0.18, @"completion" : @0.72}};
}
NSError *SZBenchmarkBudgetError(void) {
    if (MeasuredCost >= CostLimit)
        return SPDFMacAIError(990, @"Benchmark measured cost cap reached; no further request was sent.");
    if (MissingSuccessfulCost)
        return SPDFMacAIError(991, @"Successful response omitted usage cost; stopping further requests to "
                                   @"preserve the benchmark budget.");
    return nil;
}
NSMutableArray *SZBenchmarkRequestBucket(void) {
    return Requests;
}
void SZBenchmarkResponse(NSData *bytes, NSInteger status, NSError *error, NSTimeInterval seconds,
                         NSURLRequest *request, NSMutableArray *bucket) {
    id responseJSON = [NSJSONSerialization JSONObjectWithData:bytes ?: NSData.data
                                                      options:NSJSONReadingFragmentsAllowed
                                                        error:nil];
    NSDictionary *json = Dictionary(responseJSON);
    NSDictionary *body = Dictionary([NSJSONSerialization JSONObjectWithData:request.HTTPBody ?: NSData.data
                                                                    options:NSJSONReadingFragmentsAllowed
                                                                      error:nil]);
    NSArray *messages = Array(body[@"messages"]);
    NSUInteger images = 0, chars = 0;
    for (NSDictionary *m in messages) {
        id c = Dictionary(m)[@"content"];
        if ([c isKindOfClass:NSString.class])
            chars += [c lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        else if ([c isKindOfClass:NSArray.class])
            for (NSDictionary *p in c) {
                if ([Dictionary(p)[@"type"] isEqual:@"image_url"])
                    images++;
                else
                    chars += [String(Dictionary(p)[@"text"]) lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            }
    }
    NSMutableDictionary *row = [@{
        @"status" : @(status),
        @"elapsedSeconds" : @(seconds),
        @"requestModel" : Clean(String(body[@"model"])),
        @"responseObjectValid" : @([responseJSON isKindOfClass:NSDictionary.class]),
        @"messageCount" : @(messages.count),
        @"textBytes" : @(chars),
        @"imageCount" : @(images),
        @"requestBodyBytes" : @(request.HTTPBody.length),
        @"promptSHA256" : Hash(String(Dictionary(messages.firstObject)[@"content"])),
        @"toolDefinitionCount" : @(Array(body[@"tools"]).count),
        @"providerOptions" : Clean(Dictionary(body[@"provider"]))
    } mutableCopy];
    for (NSString *k in @[ @"id", @"provider", @"model", @"usage" ])
        if (json[k])
            row[k] = Clean(json[k]);
    if (error)
        row[@"networkError"] = @{@"domain" : error.domain, @"code" : @(error.code)};
    if (json[@"error"])
        row[@"providerError"] = Clean(json[@"error"]);
    id cost = Dictionary(json[@"usage"])[@"cost"];
    @synchronized(SPDFMacAICredentials.class) {
        if (ValidNumber(cost, 0, DBL_MAX))
            MeasuredCost += [cost doubleValue];
        else {
            MissingCost = YES;
            if (status >= 200 && status < 300)
                MissingSuccessfulCost = YES;
        }
        [bucket addObject:row];
    }
}
@interface BenchReader : ShenzhenMacDelegate
@property NSString *source;
@property NSArray *sources;
@property NSDictionary *metadata;
@property NSDictionary *metadataByPath;
@end
@implementation BenchReader
- (NSArray *)aiDocumentPaths {
    return self.sources;
}
- (NSArray *)aiDocumentCandidates {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in self.sources)
        [out addObject:@{
            @"path" : p,
            @"readPath" : p,
            @"title" : p.lastPathComponent,
            @"revision" : SPDFSearchFileStamp(p) ?: @"missing"
        }];
    return out;
}
- (NSDictionary *)aiCurrentDocumentContext {
    return @{@"path" : self.source, @"title" : self.source.lastPathComponent, @"page" : @1};
}
- (NSDictionary *)aiDocumentMetadataForPath:(NSString *)path {
    return self.metadataByPath[path] ?: ([path isEqual:self.source] ? self.metadata : nil) ?: @{@"path":path,@"title":path.lastPathComponent,@"analysisAvailable":@NO,@"analysis":@{}};
}
- (NSDictionary *)aiReaderControls {
    return @{@"path" : self.source, @"page" : @1, @"zoomPercent" : @100};
}
- (NSDictionary *)aiWorkspaceContextWithArguments:(NSDictionary *)args {
    NSMutableArray *tabs = [NSMutableArray array];
    NSUInteger i = 0;
    for (NSString *p in self.sources)
        [tabs addObject:@{
            @"path" : p,
            @"title" : p.lastPathComponent,
            @"index" : @(++i),
            @"groupID" : @"general",
            @"selected" : @([p isEqual:self.source]),
            @"readOnly" : @NO,
            @"missingFile" : @NO
        }];
    return @{
        @"tabs" : tabs,
        @"groups" : @[ @{
            @"id" : @"general",
            @"displayName" : @"General",
            @"color" : @"gray",
            @"general" : @YES,
            @"collapsed" : @NO,
            @"hidden" : @NO,
            @"documentCount" : @(tabs.count)
        } ],
        @"totalDocuments" : @(tabs.count),
        @"totalGroups" : @1,
        @"next" : NSNull.null,
        @"nextGroup" : NSNull.null,
        @"currentPage" : @1,
        @"currentDocument" : [self aiCurrentDocumentContext]
    };
}
@end
@interface BenchTools : NSObject <SPDFMacAIChatTools>
@property SPDFMacAITools *tools;
@property NSMutableArray *trace;
@end
@implementation BenchTools
- (NSDictionary *)conversationContext {
    return [self.tools conversationContext];
}
- (BOOL)canUndo {
    return NO;
}
- (BOOL)undoLastAction:(NSError **)error {
    return NO;
}
- (void)cancel {
    [self.tools cancel];
}
- (void)performTool:(NSString *)name
          arguments:(NSDictionary *)args
         completion:(void (^)(NSDictionary *))completion {
    NSDate *start = NSDate.date;
    NSMutableDictionary *entry = [@{@"name" : name, @"arguments" : Clean(args)} mutableCopy];
    [self.trace addObject:entry];
    void (^done)(NSDictionary *) = ^(NSDictionary *r) {
        entry[@"elapsedSeconds"] = @(-start.timeIntervalSinceNow);
        entry[@"result"] = Clean(r);
        completion(r);
    };
    if (![@[
            @"read_pages", @"render_page", @"search_documents", @"reader_state", @"document_metadata",
            @"list_workspace"
        ] containsObject:name]) {
        done(@{
            @"error" : [name isEqual:@"current_view"]
                ? @"No live viewport exists in the headless benchmark. Use render_page for document evidence."
                : @"This app tool is unavailable in the isolated benchmark workspace. Use list_workspace and "
                  @"document retrieval tools."
        });
        return;
    }
    [self.tools performTool:name arguments:args completion:done];
}
@end
@interface BenchSession : SPDFMacAIChatSession
@end
@implementation BenchSession
// Exclude auxiliary title generation uniformly from timing and cost.
- (void)suggestTitleWithKey:(NSString *)key {
    (void)key;
}
@end
static BOOL WriteJSON(id value, NSString *path) {
    NSData *data = [NSJSONSerialization
        dataWithJSONObject:Clean(value)
                   options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes
                     error:nil];
    return data && [data writeToFile:path atomically:YES];
}
#include "checks.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0)
            return BenchmarkSelfTest();
        if (argc == 2 && strcmp(argv[1], "--check-key") == 0) {
            BOOL available = [SPDFMacAICredentials APIKeyWithError:nil].length > 0;
            puts(available ? "true" : "false");
            return available ? 0 : 3;
        }
        if ((argc != 3 && argc != 4) || (argc == 4 && strcmp(argv[3], "--stdin-key") != 0)) {
            fprintf(stderr, "usage: %s cases.json output.json [--stdin-key]\n", argv[0]);
            return 2;
        }
        NSData *manifestData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        id input = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData
                                                                  options:NSJSONReadingFragmentsAllowed
                                                                    error:nil]
                                : nil;
        NSString *invalid = ValidateManifest(input);
        if (invalid) {
            fprintf(stderr, "Invalid manifest: %s\n", invalid.UTF8String);
            return 2;
        }
        NSDictionary *config = Dictionary(input);
        NSArray *cases = [input isKindOfClass:NSArray.class] ? input : config[@"cases"];
        double cap = config[@"costCapUSD"] ? [config[@"costCapUSD"] doubleValue] : 2.0;
        NSString *key = [SPDFMacAICredentials APIKeyWithError:nil];
        if (!key.length && argc == 4) {
            char *raw = getpass("OpenRouter key (hidden): ");
            if (raw && *raw) {
                key = [NSString stringWithUTF8String:raw];
                memset(raw, 0, strlen(raw));
            }
        }
        if (!key.length) {
            fprintf(stderr, "Noninteractive Keychain access unavailable. No API calls made.\n");
            return 3;
        }
        CostLimit = cap;
        [NSApplication sharedApplication];
        NSString *root = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[@"sz-model-benchmark-"
                                               stringByAppendingString:NSUUID.UUID.UUIDString]];
        setenv("SPDF_STATE_DIR", root.fileSystemRepresentation, 1);
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *test in cases) {
            if (MeasuredCost >= cap || MissingSuccessfulCost) {
                fprintf(stderr, "Measured cost cap reached; stopping new cases.\n");
                break;
            }
            NSString *source = [test[@"path"] stringByResolvingSymlinksInPath];
            if (!source.length || ![test[@"question"] length] || ![test[@"model"] length])
                return 2;
            BenchReader *reader = [BenchReader new];
            reader.source = source;
            NSMutableArray *paths = [NSMutableArray array];
            for (NSString *p in test[@"paths"] ?: @[ source ])
                [paths addObject:p.stringByResolvingSymlinksInPath];
            if (![paths containsObject:source])
                [paths insertObject:source atIndex:0];
            reader.sources = paths;
            reader.metadata = test[@"metadata"];
            NSMutableDictionary *metadataByPath = [NSMutableDictionary dictionary];
            for (NSString *path in test[@"metadataByPath"])
                metadataByPath[path.stringByResolvingSymlinksInPath] = test[@"metadataByPath"][path];
            reader.metadataByPath = metadataByPath;
            BenchTools *tools = [BenchTools new];
            tools.trace = [NSMutableArray array];
            tools.tools = [[SPDFMacAITools alloc] initWithReader:reader];
            Requests = [NSMutableArray array];
            SPDFMacAIChatStore *store =
                [[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:root]];
            BenchSession *session = [[BenchSession alloc]
                initWithTransport:[[SPDFMacAITransport alloc]
                                      initWithConfiguration:NSURLSessionConfiguration
                                                                .ephemeralSessionConfiguration]
                            tools:tools
                      definitions:SPDFMacAITools.toolDefinitions
                            store:store];
            NSDate *start = NSDate.date;
            fprintf(stderr, "CASE %s model=%s\n", [Clean(test[@"name"]) UTF8String],
                    [Clean(test[@"model"]) UTF8String]);
            [session send:test[@"question"] model:test[@"model"] apiKey:key];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180];
            while (session.running && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
            BOOL timedOut = session.running;
            if (timedOut) {
                [session cancel];
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
            }
            NSDictionary *result = @{
                @"name" : test[@"name"] ?: @"",
                @"model" : test[@"model"],
                @"repeat" : test[@"repeat"] ?: @1,
                @"runID" : [NSString
                    stringWithFormat:@"%@/%@/r%@", test[@"name"], test[@"model"], test[@"repeat"] ?: @1],
                @"question" : test[@"question"],
                @"paths" : paths,
                @"activePath" : source,
                @"elapsedSeconds" : @(-start.timeIntervalSinceNow),
                @"timedOut" : @(timedOut),
                @"state" : @(session.activityState),
                @"status" : session.status ?: @"",
                @"chat" : Clean(session.chat),
                @"toolTrace" : tools.trace,
                @"requests" : [Requests copy],
                @"cumulativeMeasuredCostUSD" : @(MeasuredCost)
            };
            [results addObject:result];
            BOOL saved = WriteJSON(
                @{
                    @"results" : results,
                    @"measuredCostUSD" : @(MeasuredCost),
                    @"missingCost" : @(MissingCost),
                    @"costCapUSD" : @(cap),
                    @"stateDirectory" : root,
                    @"titleGenerationDisabled" : @YES,
                    @"productionPromptUnmodified" : @YES,
                    @"mutatingToolsDisabled" : @YES,
                    @"toolDefinitions" : SPDFMacAITools.toolDefinitions
                },
                output);
            if (!saved) {
                fprintf(stderr, "Could not save benchmark output; stopping.\n");
                return 5;
            }
            fprintf(stderr, "DONE %.2fs state=%ld measuredCost=$%.6f\n", -start.timeIntervalSinceNow,
                    (long)session.activityState, MeasuredCost);
        }
        return 0;
    }
}
