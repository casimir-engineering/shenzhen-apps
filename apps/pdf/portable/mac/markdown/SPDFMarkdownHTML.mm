#import "SPDFMarkdownHTMLInternal.h"

// Inline half of the HTML whitelist: per-tag inline events (md4c reports each
// inline raw-HTML construct as its own MD_TEXT_HTML segment), the sanitizer
// classification tables, and the Gumbo tag/attribute helpers shared with the
// block-island translator (SPDFMarkdownHTMLBlocks.mm). Nothing here evaluates
// content: HTML only ever toggles styling state or appends plain model runs.

NSString* SPDFMarkdownDecodeEntity(NSString* entity) {
    NSDictionary* common = @{@"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"", @"&apos;": @"'", @"&nbsp;": @" "};
    NSString* known = common[entity];
    if (known) return known;
    if (![entity hasPrefix:@"&#"] || ![entity hasSuffix:@";"]) return entity;
    BOOL hex = entity.length > 3 && ([entity characterAtIndex:2] == 'x' || [entity characterAtIndex:2] == 'X');
    NSString* digits = [entity substringWithRange:NSMakeRange(hex ? 3 : 2, entity.length - (hex ? 4 : 3))];
    unsigned long long parsed = 0;
    NSScanner* scanner = [NSScanner scannerWithString:digits];
    BOOL valid = hex ? [scanner scanHexLongLong:&parsed] : [scanner scanUnsignedLongLong:&parsed];
    if (!valid || !scanner.isAtEnd || parsed > 0x10ffff || (parsed >= 0xd800 && parsed <= 0xdfff)) return @"�";
    if (parsed <= 0xffff) {
        unichar character = (unichar)parsed;
        return [NSString stringWithCharacters:&character length:1];
    }
    parsed -= 0x10000;
    unichar pair[] = {(unichar)(0xd800 + (parsed >> 10)), (unichar)(0xdc00 + (parsed & 0x3ff))};
    return [NSString stringWithCharacters:pair length:2];
}

SPDFMarkdownHTMLTagClass SPDFMarkdownHTMLClassifyTag(NSString* name) {
    // Active/embedded/form content is dropped outright, content included:
    // nothing inside these elements may reach the canonical text.
    static NSSet* dropWithContent;
    static NSSet* dropVoid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      dropWithContent = [NSSet setWithArray:@[
          @"script", @"style", @"iframe", @"object", @"embed", @"form", @"video", @"audio",
          @"svg", @"math", @"canvas", @"select", @"textarea", @"button", @"noscript",
          @"template", @"applet", @"frame", @"frameset", @"noframes", @"head", @"title",
      ]];
      dropVoid = [NSSet setWithArray:@[
          @"input", @"link", @"meta", @"base", @"source", @"track", @"param", @"area", @"wbr",
      ]];
    });
    if ([dropWithContent containsObject:name]) return SPDFMarkdownHTMLTagClassDropWithContent;
    if ([dropVoid containsObject:name]) return SPDFMarkdownHTMLTagClassDropVoid;
    if (SPDFMarkdownHTMLTraitForTag(name) != SPDFMarkdownInlineTraitNone)
        return SPDFMarkdownHTMLTagClassInlineTrait;
    if ([name isEqualToString:@"a"]) return SPDFMarkdownHTMLTagClassAnchor;
    if ([name isEqualToString:@"img"]) return SPDFMarkdownHTMLTagClassImage;
    if ([name isEqualToString:@"br"]) return SPDFMarkdownHTMLTagClassLineBreak;
    return SPDFMarkdownHTMLTagClassPassThrough;
}

SPDFMarkdownInlineTraits SPDFMarkdownHTMLTraitForTag(NSString* name) {
    static NSDictionary<NSString*, NSNumber*>* traits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      traits = @{
          @"b": @(SPDFMarkdownInlineTraitStrong), @"strong": @(SPDFMarkdownInlineTraitStrong),
          @"i": @(SPDFMarkdownInlineTraitEmphasis), @"em": @(SPDFMarkdownInlineTraitEmphasis),
          @"code": @(SPDFMarkdownInlineTraitCode), @"tt": @(SPDFMarkdownInlineTraitCode),
          @"samp": @(SPDFMarkdownInlineTraitCode),
          @"s": @(SPDFMarkdownInlineTraitStrikethrough), @"strike": @(SPDFMarkdownInlineTraitStrikethrough),
          @"del": @(SPDFMarkdownInlineTraitStrikethrough),
          @"sub": @(SPDFMarkdownInlineTraitSubscript), @"sup": @(SPDFMarkdownInlineTraitSuperscript),
          @"kbd": @(SPDFMarkdownInlineTraitKeyboard),
          @"u": @(SPDFMarkdownInlineTraitUnderline), @"ins": @(SPDFMarkdownInlineTraitUnderline),
          @"mark": @(SPDFMarkdownInlineTraitHighlight),
      };
    });
    return traits[name].unsignedIntegerValue;
}

NSString* SPDFMarkdownHTMLElementName(const GumboElement* element) {
    if (element->tag != GUMBO_TAG_UNKNOWN) return @(gumbo_normalized_tagname(element->tag));
    GumboStringPiece piece = element->original_tag;
    gumbo_tag_from_original_text(&piece);
    NSString* name = [[NSString alloc] initWithBytes:piece.data length:piece.length encoding:NSUTF8StringEncoding];
    return name.lowercaseString ?: @"";
}

NSString* SPDFMarkdownHTMLAttribute(const GumboElement* element, const char* name) {
    GumboAttribute* attribute = gumbo_get_attribute(&element->attributes, name);
    return attribute ? @(attribute->value) : nil;
}

SPDFMarkdownTableAlignment SPDFMarkdownHTMLElementAlignment(const GumboElement* element,
                                                            NSString* name,
                                                            SPDFMarkdownTableAlignment inherited) {
    if ([name isEqualToString:@"center"]) return SPDFMarkdownTableAlignmentCenter;
    NSString* align = SPDFMarkdownHTMLAttribute(element, "align").lowercaseString;
    if ([align isEqualToString:@"center"]) return SPDFMarkdownTableAlignmentCenter;
    if ([align isEqualToString:@"right"]) return SPDFMarkdownTableAlignmentRight;
    if ([align isEqualToString:@"left"]) return SPDFMarkdownTableAlignmentLeft;
    return inherited;
}

NSString* SPDFMarkdownHTMLSanitizedLinkDestination(NSString* href) {
    if (!href.length) return nil;
    if ([href hasPrefix:@"#"]) return href;
    NSString* scheme = [NSURL URLWithString:href].scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
        [scheme isEqualToString:@"mailto"])
        return href;
    return nil;
}

CGFloat SPDFMarkdownHTMLDimension(NSString* value) {
    NSString* trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([trimmed hasSuffix:@"px"]) trimmed = [trimmed substringToIndex:trimmed.length - 2];
    if (!trimmed.length) return 0;
    NSScanner* scanner = [NSScanner scannerWithString:trimmed];
    double parsed = 0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || parsed <= 0 || parsed > 100000) return 0;
    return (CGFloat)parsed;
}

void SPDFMarkdownHTMLAppendImageRun(SPDFMarkdownBlockBuilder* block, const GumboElement* element,
                                    SPDFMarkdownInlineTraits traits) {
    NSString* source = SPDFMarkdownHTMLAttribute(element, "src");
    if (!source.length) return;
    NSString* title = SPDFMarkdownHTMLAttribute(element, "title");
    [block.runs addObject:[[SPDFMarkdownInlineRun alloc]
                     initWithText:SPDFMarkdownHTMLAttribute(element, "alt") ?: @""
                           traits:traits | SPDFMarkdownInlineTraitImage
                      destination:source
                            title:title.length ? title : nil
              preferredImageWidth:SPDFMarkdownHTMLDimension(SPDFMarkdownHTMLAttribute(element, "width"))
             preferredImageHeight:SPDFMarkdownHTMLDimension(SPDFMarkdownHTMLAttribute(element, "height"))]];
}

// One open inline tag currently in effect: its contribution to the overlay.
@interface SPDFMarkdownHTMLInlineFrame : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic) SPDFMarkdownInlineTraits traits;
@property(nonatomic, copy, nullable) NSString* destination;
@property(nonatomic, copy, nullable) NSString* title;
@end
@implementation SPDFMarkdownHTMLInlineFrame
@end

@implementation SPDFMarkdownHTMLState {
    NSMutableArray<SPDFMarkdownHTMLInlineFrame*>* _frames;
    NSMutableArray<NSString*>* _suppressed;
    NSMutableArray<NSNumber*>* _containers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frames = [NSMutableArray array];
        _suppressed = [NSMutableArray array];
        _containers = [NSMutableArray array];
    }
    return self;
}

- (SPDFMarkdownTableAlignment)currentAlignment {
    return _containers.lastObject ? (SPDFMarkdownTableAlignment)_containers.lastObject.integerValue
                                  : SPDFMarkdownTableAlignmentDefault;
}

- (BOOL)suppressing { return _suppressed.count > 0; }

- (SPDFMarkdownInlineTraits)overlayTraits {
    SPDFMarkdownInlineTraits traits = SPDFMarkdownInlineTraitNone;
    for (SPDFMarkdownHTMLInlineFrame* frame in _frames) traits |= frame.traits;
    return traits;
}

- (NSString*)overlayDestination {
    for (SPDFMarkdownHTMLInlineFrame* frame in _frames.reverseObjectEnumerator)
        if (frame.destination) return frame.destination;
    return nil;
}

- (NSString*)overlayTitle {
    for (SPDFMarkdownHTMLInlineFrame* frame in _frames.reverseObjectEnumerator)
        if (frame.title) return frame.title;
    return nil;
}

- (void)resetInlineState {
    [_frames removeAllObjects];
    [_suppressed removeAllObjects];
}

- (void)pushContainerWithAlignment:(SPDFMarkdownTableAlignment)alignment {
    if (_containers.count >= 128) return;  // Pathological nesting: keep the outermost context.
    [_containers addObject:@(alignment == SPDFMarkdownTableAlignmentDefault ? self.currentAlignment
                                                                            : alignment)];
}

- (void)popContainer {
    if (_containers.count) [_containers removeLastObject];
}

- (void)openTagNamed:(NSString*)name
             segment:(NSString*)segment
               block:(SPDFMarkdownBlockBuilder*)block
          baseTraits:(SPDFMarkdownInlineTraits)baseTraits {
    SPDFMarkdownHTMLTagClass tagClass = SPDFMarkdownHTMLClassifyTag(name);
    if (self.suppressing) {
        // Only nested dropped elements matter while suppressing, so their
        // close tags stay balanced. Everything else is swallowed.
        if (tagClass == SPDFMarkdownHTMLTagClassDropWithContent) [_suppressed addObject:name];
        return;
    }
    switch (tagClass) {
        case SPDFMarkdownHTMLTagClassDropWithContent:
            [_suppressed addObject:name];
            return;
        case SPDFMarkdownHTMLTagClassDropVoid:
            return;
        case SPDFMarkdownHTMLTagClassLineBreak:
            [block.runs addObject:[[SPDFMarkdownInlineRun alloc] initWithText:@"\n"
                                                                       traits:baseTraits | self.overlayTraits
                                                                  destination:nil]];
            return;
        case SPDFMarkdownHTMLTagClassImage:
        case SPDFMarkdownHTMLTagClassAnchor:
        case SPDFMarkdownHTMLTagClassInlineTrait:
        case SPDFMarkdownHTMLTagClassPassThrough:
            break;
    }
    SPDFMarkdownHTMLInlineFrame* frame = [SPDFMarkdownHTMLInlineFrame new];
    frame.name = name;
    frame.traits = SPDFMarkdownHTMLTraitForTag(name);
    if (tagClass == SPDFMarkdownHTMLTagClassImage || tagClass == SPDFMarkdownHTMLTagClassAnchor) {
        // Attribute values need real HTML parsing (quoting styles, entities):
        // let Gumbo parse the single-tag segment and read the element back.
        GumboOutput* output = gumbo_parse(segment.UTF8String);
        const GumboElement* element = SPDFMarkdownHTMLFindElement(output->document, name);
        if (element && tagClass == SPDFMarkdownHTMLTagClassImage) {
            SPDFMarkdownHTMLAppendImageRun(block, element, baseTraits | self.overlayTraits);
        } else if (element) {
            frame.destination =
                SPDFMarkdownHTMLSanitizedLinkDestination(SPDFMarkdownHTMLAttribute(element, "href"));
            if (frame.destination) {
                frame.traits = SPDFMarkdownInlineTraitLink;
                NSString* title = SPDFMarkdownHTMLAttribute(element, "title");
                frame.title = title.length ? title : nil;
            }
        }
        gumbo_destroy_output(&kGumboDefaultOptions, output);
        if (tagClass == SPDFMarkdownHTMLTagClassImage) return;  // <img> is void: no frame.
    }
    if (_frames.count < 128) [_frames addObject:frame];
}

- (void)closeTagNamed:(NSString*)name {
    if (_suppressed.count) {
        // Close the innermost matching dropped element; unrelated close tags
        // inside dropped content are themselves dropped content.
        NSUInteger index = [_suppressed indexOfObjectWithOptions:NSEnumerationReverse
                                                     passingTest:^BOOL(NSString* tag, NSUInteger i, BOOL* stop) {
                                                       (void)i; (void)stop;
                                                       return [tag isEqualToString:name];
                                                     }];
        if (index != NSNotFound)
            [_suppressed removeObjectsInRange:NSMakeRange(index, _suppressed.count - index)];
        return;
    }
    for (SPDFMarkdownHTMLInlineFrame* frame in _frames.reverseObjectEnumerator) {
        if (![frame.name isEqualToString:name]) continue;
        NSUInteger index = [_frames indexOfObjectIdenticalTo:frame];
        [_frames removeObjectsInRange:NSMakeRange(index, _frames.count - index)];
        return;
    }
}

@end

// First element named `name` in the parsed fragment (Gumbo may hoist metadata
// tags into <head>, so the search spans the whole document).
const GumboElement* SPDFMarkdownHTMLFindElement(const GumboNode* node, NSString* name) {
    if (!node) return NULL;
    const GumboVector* children = NULL;
    if (node->type == GUMBO_NODE_ELEMENT) {
        if ([SPDFMarkdownHTMLElementName(&node->v.element) isEqualToString:name])
            return &node->v.element;
        children = &node->v.element.children;
    } else if (node->type == GUMBO_NODE_DOCUMENT) {
        children = &node->v.document.children;
    }
    if (!children) return NULL;
    for (unsigned int i = 0; i < children->length; ++i) {
        const GumboElement* found = SPDFMarkdownHTMLFindElement((const GumboNode*)children->data[i], name);
        if (found) return found;
    }
    return NULL;
}

void SPDFMarkdownHTMLHandleInlineSegment(SPDFMarkdownHTMLState* state, NSString* segment,
                                         SPDFMarkdownBlockBuilder* block,
                                         SPDFMarkdownInlineTraits baseTraits) {
    NSString* trimmed =
        [segment stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed hasPrefix:@"<"] || trimmed.length < 3) return;
    if ([trimmed hasPrefix:@"<!"] || [trimmed hasPrefix:@"<?"]) return;  // Comments, doctype, PIs.
    BOOL close = [trimmed hasPrefix:@"</"];
    NSUInteger start = close ? 2 : 1;
    NSUInteger end = start;
    NSCharacterSet* letters = NSCharacterSet.alphanumericCharacterSet;
    while (end < trimmed.length && [letters characterIsMember:[trimmed characterAtIndex:end]]) ++end;
    if (end == start) return;
    NSString* name = [trimmed substringWithRange:NSMakeRange(start, end - start)].lowercaseString;
    if (close) {
        [state closeTagNamed:name];
    } else {
        [state openTagNamed:name segment:trimmed block:block baseTraits:baseTraits];
    }
}
