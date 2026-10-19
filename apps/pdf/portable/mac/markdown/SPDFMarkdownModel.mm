#import "SPDFMarkdownModel.h"

#import "SPDFMarkdownResources.h"

@implementation SPDFMarkdownInlineRun

- (instancetype)initWithText:(NSString*)text
                      traits:(SPDFMarkdownInlineTraits)traits
                 destination:(NSString*)destination
                       title:(NSString*)title
         preferredImageWidth:(CGFloat)preferredImageWidth
        preferredImageHeight:(CGFloat)preferredImageHeight {
    self = [super init];
    if (self) {
        _text = [text copy];
        _traits = traits;
        _destination = [destination copy];
        _title = [title copy];
        _preferredImageWidth = MAX(0, preferredImageWidth);
        _preferredImageHeight = MAX(0, preferredImageHeight);
    }
    return self;
}

- (instancetype)initWithText:(NSString*)text
                      traits:(SPDFMarkdownInlineTraits)traits
                 destination:(NSString*)destination
                       title:(NSString*)title {
    return [self initWithText:text traits:traits destination:destination title:title
          preferredImageWidth:0 preferredImageHeight:0];
}

- (instancetype)initWithText:(NSString*)text
                      traits:(SPDFMarkdownInlineTraits)traits
                 destination:(NSString*)destination {
    return [self initWithText:text traits:traits destination:destination title:nil];
}

@end

@implementation SPDFMarkdownBlock

- (instancetype)initWithKind:(SPDFMarkdownBlockKind)kind
                   blockIndex:(NSUInteger)blockIndex
                        level:(NSUInteger)level
                 orderedStart:(NSInteger)orderedStart
                    taskState:(NSInteger)taskState
               tableAlignment:(SPDFMarkdownTableAlignment)tableAlignment
             tableColumnCount:(NSUInteger)tableColumnCount
                         runs:(NSArray<SPDFMarkdownInlineRun*>*)runs
                     children:(NSArray<SPDFMarkdownBlock*>*)children
                 codeLanguage:(NSString*)codeLanguage
                     codeInfo:(NSString*)codeInfo
                  calloutKind:(NSString*)calloutKind
                 calloutTitle:(NSString*)calloutTitle {
    return [self initWithKind:kind blockIndex:blockIndex level:level orderedStart:orderedStart
                    taskState:taskState tableAlignment:tableAlignment
               blockAlignment:SPDFMarkdownTableAlignmentDefault tableColumnCount:tableColumnCount
                         runs:runs children:children codeLanguage:codeLanguage codeInfo:codeInfo
                  calloutKind:calloutKind calloutTitle:calloutTitle];
}

- (instancetype)initWithKind:(SPDFMarkdownBlockKind)kind
                   blockIndex:(NSUInteger)blockIndex
                        level:(NSUInteger)level
                 orderedStart:(NSInteger)orderedStart
                    taskState:(NSInteger)taskState
               tableAlignment:(SPDFMarkdownTableAlignment)tableAlignment
               blockAlignment:(SPDFMarkdownTableAlignment)blockAlignment
             tableColumnCount:(NSUInteger)tableColumnCount
                         runs:(NSArray<SPDFMarkdownInlineRun*>*)runs
                     children:(NSArray<SPDFMarkdownBlock*>*)children
                 codeLanguage:(NSString*)codeLanguage
                     codeInfo:(NSString*)codeInfo
                  calloutKind:(NSString*)calloutKind
                 calloutTitle:(NSString*)calloutTitle {
    self = [super init];
    if (self) {
        _kind = kind;
        _blockAlignment = blockAlignment;
        _blockIndex = blockIndex;
        _level = level;
        _orderedStart = orderedStart;
        _taskState = taskState;
        _tableAlignment = tableAlignment;
        _tableColumnCount = tableColumnCount;
        _runs = [runs copy];
        _children = [children copy];
        _codeLanguage = [codeLanguage copy];
        _codeInfo = [codeInfo copy];
        _calloutKind = [calloutKind copy];
        _calloutTitle = [calloutTitle copy];
        NSMutableString* text = [NSMutableString string];
        for (SPDFMarkdownInlineRun* run in _runs) [text appendString:run.text];
        _plainText = [text copy];
    }
    return self;
}

@end

@implementation SPDFMarkdownHeading

- (instancetype)initWithLevel:(NSUInteger)level
                   blockIndex:(NSUInteger)blockIndex
                        title:(NSString*)title {
    self = [super init];
    if (self) {
        _level = level;
        _blockIndex = blockIndex;
        _title = [title copy];
    }
    return self;
}

@end

@implementation SPDFMarkdownCodeFence

- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                  declaredLanguage:(NSString*)declaredLanguage
                        infoString:(NSString*)infoString
                               code:(NSString*)code {
    self = [super init];
    if (self) {
        _blockIndex = blockIndex;
        _declaredLanguage = [declaredLanguage copy];
        _infoString = [infoString copy];
        _code = [code copy];
    }
    return self;
}

@end

@implementation SPDFMarkdownSearchMatch

- (instancetype)initWithRange:(NSRange)range
                   blockIndex:(NSUInteger)blockIndex
                 headingIndex:(NSInteger)headingIndex
                      context:(NSString*)context {
    self = [super init];
    if (self) {
        _range = range;
        _blockIndex = blockIndex;
        _headingIndex = headingIndex;
        _context = [context copy];
    }
    return self;
}

@end

static void SPDFCollectBlocks(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableArray<SPDFMarkdownBlock*>* output) {
    for (SPDFMarkdownBlock* block in blocks) {
        [output addObject:block];
        SPDFCollectBlocks(block.children, output);
    }
}

@implementation SPDFMarkdownDocumentModel {
    NSDictionary<NSNumber*, SPDFMarkdownBlock*>* _blocksByIndex;
}

- (instancetype)initWithSourceURL:(NSURL*)sourceURL
                      frontMatter:(NSDictionary<NSString*, NSString*>*)frontMatter
                   rawFrontMatter:(NSString*)rawFrontMatter
                           blocks:(NSArray<SPDFMarkdownBlock*>*)blocks {
    self = [super init];
    if (!self) return nil;
    _sourceURL = [sourceURL copy];
    if (_sourceURL) _resourceStore = [[SPDFMarkdownResourceStore alloc] initWithDocumentURL:_sourceURL];
    _frontMatter = [frontMatter copy];
    _rawFrontMatter = [rawFrontMatter copy];
    _blocks = [blocks copy];

    NSMutableArray<SPDFMarkdownBlock*>* flattened = [NSMutableArray array];
    SPDFCollectBlocks(_blocks, flattened);
    NSMutableDictionary* byIndex = [NSMutableDictionary dictionary];
    NSMutableArray<SPDFMarkdownHeading*>* headings = [NSMutableArray array];
    NSMutableArray<SPDFMarkdownCodeFence*>* fences = [NSMutableArray array];

    for (SPDFMarkdownBlock* block in flattened) {
        byIndex[@(block.blockIndex)] = block;
        if (block.kind == SPDFMarkdownBlockKindHeading) {
            [headings addObject:[[SPDFMarkdownHeading alloc] initWithLevel:block.level
                                                               blockIndex:block.blockIndex
                                                                    title:block.plainText]];
        } else if (block.kind == SPDFMarkdownBlockKindCode) {
            [fences addObject:[[SPDFMarkdownCodeFence alloc] initWithBlockIndex:block.blockIndex
                                                              declaredLanguage:block.codeLanguage
                                                                    infoString:block.codeInfo
                                                                           code:block.plainText]];
        }
    }
    _headings = [headings copy];
    _codeFences = [fences copy];
    _blocksByIndex = [byIndex copy];
    return self;
}

- (SPDFMarkdownBlock*)blockWithIndex:(NSUInteger)blockIndex {
    return _blocksByIndex[@(blockIndex)];
}

@end
