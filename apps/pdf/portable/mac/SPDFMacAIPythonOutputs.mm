#import "SPDFMacAIPythonOutputs.h"

const NSUInteger SPDFMacAIPythonMaxOutputs = 16;

static NSString* const kSPDFOutPrefix = @"out/";

NSArray<NSDictionary*>* SPDFMacAIPythonOutputFiles(NSDictionary* result, NSDictionary** rest) {
    NSMutableArray* outputs = [NSMutableArray array], *others = [NSMutableArray array];
    for (NSDictionary* file in [result[@"files"] isKindOfClass:NSArray.class] ? result[@"files"] : @[]) {
        BOOL output = [file isKindOfClass:NSDictionary.class] && [file[@"name"] isKindOfClass:NSString.class] &&
                      [file[@"name"] hasPrefix:kSPDFOutPrefix] && [file[@"name"] length] > kSPDFOutPrefix.length;
        [output ? outputs : others addObject:file];
    }
    if (rest) {
        NSMutableDictionary* kept = [result mutableCopy];
        kept[@"files"] = others;
        *rest = kept;
    }
    return outputs;
}

static BOOL SPDFIsPNG(NSData* data) {
    static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    return data.length > 8 && memcmp(data.bytes, signature, 8) == 0;
}

void SPDFMacAIPythonKeepOutputs(NSArray<NSDictionary*>* files, SPDFMacAIPythonOutputSaver saver,
                                SPDFMacAIPythonOutputPresenter presenter, id<SPDFMacAIActivityReporting> activity,
                                void (^completion)(NSArray<NSDictionary*>*)) {
    NSArray* list = [files copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray* report = [NSMutableArray array], *saved = [NSMutableArray array];
        for (NSDictionary* file in list) {
            NSString* name = file[@"name"];
            // Folders inside out/ are flattened to the file's own name; Downloads gets no folders from code.
            NSString* plain = name.lastPathComponent;
            NSData* data = [file[@"data"] isKindOfClass:NSString.class]
                ? [[NSData alloc] initWithBase64EncodedString:file[@"data"] options:0] : nil;
            if (report.count >= SPDFMacAIPythonMaxOutputs) {
                [report addObject:@{@"file" : name, @"error" : @"Not kept: at most 16 files are kept per run."}];
            } else if (!data) {
                [report addObject:@{@"file" : name, @"error" : [file[@"omitted"] isEqual:@"too_large"]
                    ? @"Not kept: the files of one run may total 10 MB." : @"Not kept: it is not a plain file."}];
            } else if (!plain.length || [plain hasPrefix:@"."]) {
                [report addObject:@{@"file" : name, @"error" : @"Not kept: give it a name that does not start with a dot."}];
            } else {
                NSError* error = nil;
                NSDictionary* receipt = saver(data, plain, &error);
                if (receipt[@"path"]) {
                    [report addObject:@{@"file" : name, @"saved_as" : [receipt[@"path"] lastPathComponent],
                                        @"folder" : @"Downloads"}];
                    [saved addObject:@{@"path" : receipt[@"path"], @"png" : @(SPDFIsPNG(data))}];
                } else {
                    [report addObject:@{@"file" : name, @"error" : error.localizedDescription ?: @"Not kept."}];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSDictionary* item in saved) {
                NSString* image = nil;
                if ([item[@"png"] boolValue])
                    image = [activity addImageAtPath:item[@"path"] caption:[item[@"path"] lastPathComponent]
                                             options:SPDFMacAIActivityOptionsNone];
                if (presenter && activity) presenter(activity, item[@"path"], image);
            }
            completion(report);
        });
    });
}
