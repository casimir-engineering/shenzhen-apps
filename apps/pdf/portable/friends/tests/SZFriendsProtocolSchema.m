// Schema parser and validator for PROTOCOL.md's ```schema blocks; see SZFriendsProtocolSchema.h.

#import "SZFriendsProtocolSchema.h"

int SZFFailures;
BOOL SZFQuiet;
NSMutableSet<NSString *> *SZFTypesMatched;

void SZFFail(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!SZFQuiet) fprintf(stderr, "FAIL %s\n", message.UTF8String);
    SZFFailures++;
}

@implementation SZFRule
@end

static BOOL IsBool(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL ValidTypeToken(NSString *token) {
    static NSSet<NSString *> *primitives;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        primitives = [NSSet setWithArray:@[ @"string", @"integer", @"number", @"bool", @"object", @"array",
                                            @"null", @"any" ]];
    });
    if ([primitives containsObject:token]) return YES;
    if ([token hasPrefix:@"enum("] && [token hasSuffix:@")"] && token.length > 6) return YES;
    return [token hasPrefix:@"@"] && token.length > 1;
}

// Errors are reported with the line number, so a typo in the document fails loudly instead of turning into a rule
// that checks nothing.
SZFSchemas *SZFParseSchemas(NSString *markdown, NSString *label) {
    NSMutableDictionary<NSString *, NSMutableArray<SZFRule *> *> *schemas = [NSMutableDictionary dictionary];
    NSRegularExpression *ruleRegex = [NSRegularExpression
        regularExpressionWithPattern:@"^([A-Za-z0-9_.\\[\\]]+)(\\?)?:\\s*(\\S+)(?:\\s+when\\s+([A-Za-z0-9_.]+)="
                                     @"([A-Za-z0-9_,]+))?$"
                             options:0
                               error:NULL];
    NSString *current = nil;
    NSUInteger lineNumber = 0;
    for (NSString *rawLine in [markdown componentsSeparatedByString:@"\n"]) {
        lineNumber++;
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!current) {
            if (![line hasPrefix:@"```schema "]) continue;
            current = [[line substringFromIndex:10]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (schemas[current]) SZFFail(@"%@:%lu: duplicate schema %@", label, (unsigned long)lineNumber, current);
            schemas[current] = [NSMutableArray array];
            continue;
        }
        if ([line isEqualToString:@"```"]) {
            if (schemas[current].count == 0) SZFFail(@"%@: schema %@ has no rules", label, current);
            current = nil;
            continue;
        }
        NSRange hash = [line rangeOfString:@"#"];
        if (hash.location != NSNotFound) line = [line substringToIndex:hash.location];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0) continue;
        NSTextCheckingResult *match = [ruleRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!match) {
            SZFFail(@"%@:%lu: unparsable rule '%@' in %@", label, (unsigned long)lineNumber, line, current);
            continue;
        }
        SZFRule *rule = [SZFRule new];
        rule.segments = [[line substringWithRange:[match rangeAtIndex:1]] componentsSeparatedByString:@"."];
        rule.optional = [match rangeAtIndex:2].location != NSNotFound;
        rule.types = [[line substringWithRange:[match rangeAtIndex:3]] componentsSeparatedByString:@"|"];
        if ([match rangeAtIndex:4].location != NSNotFound) {
            rule.whenPath = [line substringWithRange:[match rangeAtIndex:4]];
            rule.whenValues = [NSSet setWithArray:[[line substringWithRange:[match rangeAtIndex:5]]
                                                      componentsSeparatedByString:@","]];
        }
        rule.source = [NSString stringWithFormat:@"%@ line %lu", current, (unsigned long)lineNumber];
        for (NSString *type in rule.types) {
            if (!ValidTypeToken(type)) SZFFail(@"%@:%lu: unknown type '%@'", label, (unsigned long)lineNumber, type);
        }
        [schemas[current] addObject:rule];
    }
    if (current) SZFFail(@"%@: schema %@ is not closed", label, current);
    for (NSString *schemaID in schemas) {
        for (SZFRule *rule in schemas[schemaID]) {
            for (NSString *type in rule.types) {
                if ([type hasPrefix:@"@"] && !schemas[[@"type." stringByAppendingString:[type substringFromIndex:1]]])
                    SZFFail(@"%@: %@ references undefined type %@", label, rule.source, type);
            }
        }
    }
    return schemas;
}

static NSString *Describe(id value) {
    if (!value) return @"(absent)";
    if (value == NSNull.null) return @"null";
    if (IsBool(value)) return [value boolValue] ? @"true" : @"false";
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    if ([value isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"\"%@\"", value];
    if ([value isKindOfClass:NSArray.class]) return @"array";
    return @"object";
}

static id ResolveSimplePath(NSDictionary *base, NSString *path) {
    id node = base;
    for (NSString *key in [path componentsSeparatedByString:@"."]) {
        if (![node isKindOfClass:NSDictionary.class]) return nil;
        node = node[key];
    }
    return node;
}

// "a.b[].c" -> "a.b.c": a rule's key path without fan-out markers, for its first `count` segments.
static NSString *KeyPath(NSArray<NSString *> *segments, NSUInteger count) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *segment = segments[i];
        [keys addObject:[segment hasSuffix:@"[]"] ? [segment substringToIndex:segment.length - 2] : segment];
    }
    return [keys componentsJoinedByString:@"."];
}

#pragma mark - Undeclared fields

// For a set of schemas: every declared key path with its prefixes, and the paths whose contents another check
// owns, where the walk stops: typed objects (checked against their own block) and free-form objects no rule looks
// inside (`details: object`). Cached because typed objects repeat throughout every fixture.
static void DeclaredPaths(NSArray<NSString *> *schemaIDs, SZFSchemas *schemas, NSSet **declaredOut, NSSet **stopsOut) {
    static NSMutableDictionary<NSString *, NSArray<NSSet *> *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *cacheKey = [NSString stringWithFormat:@"%p %@", (__bridge void *)schemas,
                                                    [schemaIDs componentsJoinedByString:@" "]];
    if (!cache[cacheKey]) {
        NSMutableSet<NSString *> *declared = [NSMutableSet set], *stops = [NSMutableSet set];
        NSMutableSet<NSString *> *freeForm = [NSMutableSet set];
        for (NSString *schemaID in schemaIDs) {
            for (SZFRule *rule in schemas[schemaID]) {
                for (NSUInteger n = 1; n <= rule.segments.count; n++) [declared addObject:KeyPath(rule.segments, n)];
                NSString *full = KeyPath(rule.segments, rule.segments.count);
                BOOL typed = NO, containerOnly = YES;
                for (NSString *type in rule.types) {
                    if ([type hasPrefix:@"@"]) typed = YES;
                    else if (![@[ @"object", @"any", @"null" ] containsObject:type]) containerOnly = NO;
                }
                if (typed) [stops addObject:full];
                else if (containerOnly) [freeForm addObject:full];
            }
        }
        for (NSString *path in freeForm) {
            NSString *prefix = [path stringByAppendingString:@"."];
            BOOL extended = NO;
            for (NSString *other in declared) extended = extended || [other hasPrefix:prefix];
            if (!extended) [stops addObject:path];
        }
        cache[cacheKey] = @[ declared, stops ];
    }
    *declaredOut = cache[cacheKey][0];
    *stopsOut = cache[cacheKey][1];
}

static void WalkUndeclared(id node, NSString *path, NSSet *declared, NSSet *stops, NSString *where,
                           NSMutableArray<NSString *> *errors) {
    if ([node isKindOfClass:NSArray.class]) {
        for (id element in node) WalkUndeclared(element, path, declared, stops, where, errors);
        return;
    }
    if (![node isKindOfClass:NSDictionary.class] || (path.length && [stops containsObject:path])) return;
    for (NSString *key in [[node allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *child = path.length ? [NSString stringWithFormat:@"%@.%@", path, key] : key;
        if ([declared containsObject:child]) {
            WalkUndeclared(node[key], child, declared, stops, where, errors);
        } else {
            [errors addObject:[NSString stringWithFormat:@"%@: %@ is not declared in PROTOCOL.md", where, child]];
        }
    }
}

static void CheckUndeclared(NSDictionary *object, NSArray<NSString *> *schemaIDs, SZFSchemas *schemas,
                            NSString *where, NSMutableArray<NSString *> *errors) {
    NSSet *declared, *stops;
    DeclaredPaths(schemaIDs, schemas, &declared, &stops);
    WalkUndeclared(object, @"", declared, stops, where, errors);
}

#pragma mark - Rules

static void ValidateObject(NSDictionary *object, NSString *schemaID, SZFSchemas *schemas, NSString *where,
                           NSMutableArray<NSString *> *errors, int depth);

static BOOL MatchesType(id value, NSString *type, SZFSchemas *schemas, NSString *where,
                        NSMutableArray<NSString *> *errors, int depth) {
    if ([type isEqualToString:@"any"]) return YES;
    if ([type isEqualToString:@"null"]) return value == NSNull.null;
    if ([type isEqualToString:@"string"]) return [value isKindOfClass:NSString.class];
    if ([type isEqualToString:@"bool"]) return IsBool(value);
    if ([type isEqualToString:@"object"]) return [value isKindOfClass:NSDictionary.class];
    if ([type isEqualToString:@"array"]) return [value isKindOfClass:NSArray.class];
    if ([type isEqualToString:@"number"]) return [value isKindOfClass:NSNumber.class] && !IsBool(value);
    if ([type isEqualToString:@"integer"]) {
        return [value isKindOfClass:NSNumber.class] && !IsBool(value) &&
               !CFNumberIsFloatType((__bridge CFNumberRef)value);
    }
    if ([type hasPrefix:@"enum("]) {
        NSString *list = [type substringWithRange:NSMakeRange(5, type.length - 6)];
        return [value isKindOfClass:NSString.class] && [[list componentsSeparatedByString:@","] containsObject:value];
    }
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSString *typeID = [@"type." stringByAppendingString:[type substringFromIndex:1]];
    NSUInteger before = errors.count;
    ValidateObject(value, typeID, schemas, where, errors, depth + 1);
    CheckUndeclared(value, @[ typeID ], schemas, where, errors);
    if (errors.count != before) return NO;
    [SZFTypesMatched addObject:typeID];
    return YES;
}

// A union is satisfied when any alternative matches with no errors; when none does and one alternative is an
// object type, that type's own errors are reported, because "rows[1].avatar.set missing" helps far more than
// "not an @avatar".
static void CheckValue(id value, SZFRule *rule, NSString *path, SZFSchemas *schemas, NSString *where,
                       NSMutableArray<NSString *> *errors, int depth) {
    NSArray<NSString *> *bestErrors = nil;
    for (NSString *type in rule.types) {
        NSMutableArray<NSString *> *trial = [NSMutableArray array];
        if (MatchesType(value, type, schemas, [NSString stringWithFormat:@"%@ %@", where, path], trial, depth)) return;
        if (trial.count && (!bestErrors || trial.count < bestErrors.count)) bestErrors = trial;
    }
    if (bestErrors) {
        [errors addObjectsFromArray:bestErrors];
    } else {
        [errors addObject:[NSString stringWithFormat:@"%@: %@ is %@, expected %@ (%@)", where, path, Describe(value),
                                                     [rule.types componentsJoinedByString:@"|"], rule.source]];
    }
}

static void Walk(id node, SZFRule *rule, NSUInteger index, NSString *path, NSSet<NSString *> *optionalKeys,
                 SZFSchemas *schemas, NSString *where, NSMutableArray<NSString *> *errors, int depth) {
    if (index == rule.segments.count) {
        CheckValue(node, rule, path, schemas, where, errors, depth);
        return;
    }
    if (node == NSNull.null) return; // the parent's rule decided whether null is allowed
    NSString *segment = rule.segments[index];
    BOOL fanOut = [segment hasSuffix:@"[]"];
    NSString *key = fanOut ? [segment substringToIndex:segment.length - 2] : segment;
    NSString *childPath = path.length ? [NSString stringWithFormat:@"%@.%@", path, key] : key;
    if (![node isKindOfClass:NSDictionary.class]) {
        [errors addObject:[NSString stringWithFormat:@"%@: %@ is not an object (%@)", where, path, rule.source]];
        return;
    }
    id child = node[key];
    if (!child) {
        // Absent is fine for an optional rule, and for any rule below a key another rule declares optional:
        // "attachments?: array" makes "attachments[]: @file" apply only when attachments is present.
        BOOL optional = rule.optional || [optionalKeys containsObject:KeyPath(rule.segments, index + 1)];
        if (!optional)
            [errors addObject:[NSString stringWithFormat:@"%@: missing %@ (%@)", where, childPath, rule.source]];
        return;
    }
    if (!fanOut) {
        Walk(child, rule, index + 1, childPath, optionalKeys, schemas, where, errors, depth);
        return;
    }
    if (child == NSNull.null) return;
    if (![child isKindOfClass:NSArray.class]) {
        [errors addObject:[NSString stringWithFormat:@"%@: %@ is not an array (%@)", where, childPath, rule.source]];
        return;
    }
    [(NSArray *)child enumerateObjectsUsingBlock:^(id element, NSUInteger i, BOOL *stop) {
        (void)stop;
        Walk(element, rule, index + 1, [NSString stringWithFormat:@"%@[%lu]", childPath, (unsigned long)i],
             optionalKeys, schemas, where, errors, depth);
    }];
}

static void ValidateObject(NSDictionary *object, NSString *schemaID, SZFSchemas *schemas, NSString *where,
                           NSMutableArray<NSString *> *errors, int depth) {
    if (depth > 16) {
        [errors addObject:[NSString stringWithFormat:@"%@: types nest deeper than 16 at %@", where, schemaID]];
        return;
    }
    NSMutableSet<NSString *> *optionalKeys = [NSMutableSet set];
    for (SZFRule *rule in schemas[schemaID])
        if (rule.optional) [optionalKeys addObject:KeyPath(rule.segments, rule.segments.count)];
    for (SZFRule *rule in schemas[schemaID]) {
        if (rule.whenPath) {
            id condition = ResolveSimplePath(object, rule.whenPath);
            if (!condition || condition == NSNull.null) continue;
            NSString *text = [condition isKindOfClass:NSString.class] ? condition : Describe(condition);
            if (![rule.whenValues containsObject:text]) continue;
        }
        Walk(object, rule, 0, @"", optionalKeys, schemas, where, errors, depth);
    }
}

void SZFValidate(NSDictionary *object, NSArray<NSString *> *schemaIDs, SZFSchemas *schemas, NSString *where,
                 NSMutableArray<NSString *> *errors) {
    for (NSString *schemaID in schemaIDs) ValidateObject(object, schemaID, schemas, where, errors, 0);
    CheckUndeclared(object, schemaIDs, schemas, where, errors);
}
