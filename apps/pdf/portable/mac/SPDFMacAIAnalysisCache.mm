#import "SPDFMacAIDocumentContext.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
static BOOL HashValid(NSString* hash) {
    return hash.length==64 && [hash rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static id Invalid(NSError** error, NSString* detail) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.Analysis" code:1
        userInfo:@{NSLocalizedDescriptionKey:detail}];
    return nil;
}
NSDictionary* SPDFAIValidateAnalysis(id value, NSUInteger pageCount, BOOL authoredOutline, NSError** error) {
    if (![value isKindOfClass:NSDictionary.class]) return Invalid(error,@"Analysis must be an object.");
    NSString* summary=value[@"summary"]; NSArray* keywords=value[@"keywords"]; NSArray* chapters=value[@"chapters"] ?: @[];
    if (![summary isKindOfClass:NSString.class] || !summary.length || summary.length>10000 ||
        ![keywords isKindOfClass:NSArray.class] || keywords.count>32 ||
        ![chapters isKindOfClass:NSArray.class] || chapters.count>100)
        return Invalid(error,@"Analysis exceeds its summary, keyword or chapter budget.");
    for (id word in keywords) if (![word isKindOfClass:NSString.class] || ![word length] || [word length]>100)
        return Invalid(error,@"Invalid keyword.");
    NSArray* tags=value[@"tags"] ?: @[];
    if(![tags isKindOfClass:NSArray.class] || tags.count>6) return Invalid(error,@"Analysis accepts at most six tags.");
    NSMutableArray* cleanTags=[NSMutableArray array]; NSMutableSet* seenTags=[NSMutableSet set];
    for(id tag in tags) {
        if(![tag isKindOfClass:NSString.class]) return Invalid(error,@"Invalid tag.");
        NSString* clean=[tag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!clean.length || clean.length>64 || [clean rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
            return Invalid(error,@"Tags must be short, single-line text.");
        NSString* identity=[clean stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        if(![seenTags containsObject:identity]) { [cleanTags addObject:clean]; [seenTags addObject:identity]; }
    }
    NSMutableArray* valid=[NSMutableArray array]; NSUInteger previous=0;
    if (!authoredOutline) for (id chapter in chapters) {
        if (![chapter isKindOfClass:NSDictionary.class]) return Invalid(error,@"Invalid chapter.");
        id title=chapter[@"title"], page=chapter[@"page"], level=chapter[@"level"] ?: @1;
        if (![title isKindOfClass:NSString.class] || ![title length] || [title length]>256 ||
            ![page isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)page)==CFBooleanGetTypeID() ||
            [page doubleValue]!=[page integerValue] || [page integerValue]<1 || [page unsignedIntegerValue]>pageCount ||
            [page unsignedIntegerValue]<previous || ![level isKindOfClass:NSNumber.class] ||
            [level doubleValue]!=[level integerValue] || [level integerValue]<1 || [level integerValue]>3)
            return Invalid(error,@"Generated chapter has an invalid title, level or page.");
        previous=[page unsignedIntegerValue];
        [valid addObject:@{@"title":title,@"page":page,@"level":level,@"generated":@YES}];
    }
    NSMutableDictionary* result=[@{@"schema":@1,@"summary":summary,@"keywords":keywords,@"tags":cleanTags,@"chapters":valid,
        @"pageCount":@(pageCount),@"generated":@YES} mutableCopy];
    if([value[@"userRequestedOverride"] isEqual:@YES])result[@"userRequestedOverride"]=@YES;
    id analyzed=value[@"analyzedPages"];
    if (analyzed) {
        if (![analyzed isKindOfClass:NSArray.class] || [analyzed count]>10000)
            return Invalid(error,@"Invalid page coverage.");
        NSMutableSet* seen=[NSMutableSet set];
        for (id page in analyzed) {
            if (![page isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)page)==CFBooleanGetTypeID() ||
                [page doubleValue]!=[page integerValue] || [page integerValue]<1 || [page unsignedIntegerValue]>pageCount ||
                [seen containsObject:page]) return Invalid(error,@"Invalid analyzed page number.");
            [seen addObject:page];
        }
        for (NSDictionary* chapter in valid) if (![seen containsObject:chapter[@"page"]])
            return Invalid(error,@"Generated chapter was not grounded in an analyzed page.");
        result[@"analyzedPages"]=analyzed;
    }
    if (value[@"partial"]) {
        if (CFGetTypeID((__bridge CFTypeRef)value[@"partial"])!=CFBooleanGetTypeID())
            return Invalid(error,@"Partial coverage must be a Boolean.");
        result[@"partial"]=value[@"partial"];
    }
    for (NSString* key in @[@"model",@"language",@"completedAt",@"layoutIdentity",@"promptVersion",@"contentHash",@"cacheKey"]) if (value[key]) {
        if (![value[key] isKindOfClass:NSString.class] || [value[key] length]>512)
            return Invalid(error,@"Invalid analysis metadata.");
        result[key]=value[key];
    }
    if ([value[@"revisionDiff"] isKindOfClass:NSDictionary.class]) {
        NSDictionary* diff=value[@"revisionDiff"];
        if ([diff[@"addedCharacters"] isKindOfClass:NSNumber.class] &&
            [diff[@"removedCharacters"] isKindOfClass:NSNumber.class] &&
            [diff[@"partial"] isKindOfClass:NSNumber.class])
            result[@"revisionDiff"]=@{@"addedCharacters":diff[@"addedCharacters"],@"removedCharacters":diff[@"removedCharacters"],
                @"partial":diff[@"partial"],@"unit":@"UTF-16 code units",@"algorithm":@"one exact replacement per changed page"};
    }
    return result;
}
@interface SPDFMacAIAnalysisCache ()
@property(nonatomic,strong) NSURL* root;
@end
@implementation SPDFMacAIAnalysisCache
- (instancetype)initWithRootURL:(NSURL*)rootURL {
    if ((self=[super init])) _root=rootURL;
    return self;
}
- (NSURL*)rootURL { return self.root; }
- (int)lockHash:(NSString*)hash progress:(NSProgress*)progress error:(NSError**)error {
    if (!HashValid(hash)) { Invalid(error,@"Invalid analysis identity."); return -1; }
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return -1;
    NSString* path=[[self.root URLByAppendingPathComponent:[hash stringByAppendingString:@".lock"]] path];
    int descriptor=open(path.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
    if (descriptor<0) { Invalid(error,@"Could not lock analysis cache."); return -1; }
    // flock is released on crash and works across independent window processes.
    // Never unlink the lock file: a waiter could otherwise hold a different inode.
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:180];
    while (!progress.cancelled && deadline.timeIntervalSinceNow>0) {
        if (flock(descriptor,LOCK_EX|LOCK_NB)==0) return descriptor;
        if (errno!=EWOULDBLOCK && errno!=EINTR) break;
        usleep(20000);
    }
    close(descriptor); Invalid(error,progress.cancelled ? @"Cancelled." : @"Analysis is busy in another window. Retry later.");
    return -1;
}
- (NSDictionary*)analysisForHash:(NSString*)hash {
    if (!HashValid(hash)) return nil;
    NSData* data=[NSData dataWithContentsOfURL:[self.root URLByAppendingPathComponent:[hash stringByAppendingString:@".json"]]];
    if (!data || data.length>65536) return nil;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || [value[@"schema"] integerValue]!=1) return nil;
    if (![value[@"pageCount"] isKindOfClass:NSNumber.class]) return nil;
    return SPDFAIValidateAnalysis(value,[value[@"pageCount"] unsignedIntegerValue],NO,nil);
}
- (BOOL)storeAnalysis:(NSDictionary*)analysis forHash:(NSString*)hash error:(NSError**)error {
    if (!HashValid(hash)) { Invalid(error,@"Invalid content hash."); return NO; }
    if (![analysis isKindOfClass:NSDictionary.class] || ![analysis[@"pageCount"] isKindOfClass:NSNumber.class]) {
        Invalid(error,@"Missing analysis page count."); return NO;
    }
    NSDictionary* validated=SPDFAIValidateAnalysis(analysis,[analysis[@"pageCount"] unsignedIntegerValue],NO,error);
    if (!validated) return NO;
    NSData* data=[NSJSONSerialization dataWithJSONObject:validated options:0 error:error];
    if (!data) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    NSURL* file=[self.root URLByAppendingPathComponent:[hash stringByAppendingString:@".json"]];
    if (![data writeToURL:file options:NSDataWritingAtomic error:error]) return NO;
    chmod(file.fileSystemRepresentation,0600); return YES;
}
@end
