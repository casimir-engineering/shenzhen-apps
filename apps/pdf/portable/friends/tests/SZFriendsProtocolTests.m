// Golden-fixture check for the Friends client protocol.
//
// Usage: SZFriendsProtocolTests <PROTOCOL.md> <fixtures dir>
//
// The field reference lives in PROTOCOL.md's ```schema blocks, and this test reads it from there rather than from
// a second copy, so the document, the fixtures and (through the fixtures) the fake helper and the views cannot
// drift apart without this failing. It checks that every fixture parses, fits the 8 MiB frame cap, matches the
// schemas for its frame type and view, declares no field the document lacks, and that every frame, view, intent
// and result schema has a fixture. It also checks that the C client header, the document and the welcome
// fixture agree on the protocol version and limits, since a version bumped in one place only would negotiate
// the wrong contract, and that the prose tables agree with the machine-readable parts: § Static strings with the
// welcome fixture's strings, § Replies and errors with the error schema's codes, and every "Field of `<schema>`" table
// (§ Devices, § Joining) with its block's fields; no schema-pending block may remain. Before trusting any of that,
// it proves on synthetic input that the validator and the table reader catch each kind of mistake: a check that
// silently accepts everything would otherwise pass forever.

#import <Foundation/Foundation.h>

#import "SZFriendsProtocolSchema.h"
#import "client/szfriends_client.h"

#pragma mark - Self-test: the validator must bite

static void ExpectErrors(SZFSchemas *schemas, NSString *json, NSUInteger expected, NSString *label) {
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                           options:0
                                                             error:NULL];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    SZFValidate(object, @[ @"frame.probe" ], schemas, label, errors);
    if (errors.count != expected) {
        SZFFail(@"self-test %@: expected %lu errors, got %lu: %@", label, (unsigned long)expected,
                (unsigned long)errors.count, [errors componentsJoinedByString:@"; "]);
    }
}

static void RunSelfTest(void) {
    NSString *doc = @"```schema frame.probe\n"
                    @"a: string\nb?: integer\nc: @t|null\nd: array\nd[]: enum(p,q)\ne: string when a=on\n"
                    @"f: bool\ng.h: number   # nested\no?: object\no.p: string\nl?: array\nl[]: integer\n"
                    @"x?: object\n"
                    @"```\n"
                    @"```schema type.t\nk: bool\nm: string when k=true\n```\n";
    int before = SZFFailures;
    SZFSchemas *schemas = SZFParseSchemas(doc, @"self-test");
    if (SZFFailures != before || schemas.count != 2) SZFFail(@"self-test: probe schemas did not parse");
    NSString *good = @"{\"a\":\"off\",\"c\":{\"k\":false},\"d\":[\"p\",\"q\"],\"f\":true,\"g\":{\"h\":1.5},"
                     @"\"x\":{\"free\":1}}";
    ExpectErrors(schemas, good, 0, @"valid object, free-form x");
    ExpectErrors(schemas, @"{\"c\":null,\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1, @"missing required key");
    ExpectErrors(schemas, @"{\"a\":null,\"c\":null,\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1, @"null not allowed");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"b\":1.5,\"c\":null,\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1,
                 @"float for integer");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"b\":true,\"c\":null,\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1,
                 @"bool for integer");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":null,\"d\":[],\"f\":1,\"g\":{\"h\":2}}", 1, @"number for bool");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":{},\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1, @"nested type field");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":{\"k\":true},\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1,
                 @"nested when clause");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":null,\"d\":[\"p\",\"z\"],\"f\":false,\"g\":{\"h\":2}}", 1,
                 @"enum value in array");
    ExpectErrors(schemas, @"{\"a\":\"on\",\"c\":null,\"d\":[],\"f\":false,\"g\":{\"h\":2}}", 1, @"when clause on");
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":null,\"d\":{},\"f\":false,\"g\":{}}", 3, @"wrong containers");
    // Below an optional key: skipped when it is absent, enforced when it is present.
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":null,\"d\":[],\"f\":false,\"g\":{\"h\":2},\"o\":{},\"l\":[\"z\"]}", 2,
                 @"present optional parents");
    // Undeclared fields, at the top, inside a nested path and inside a typed object.
    ExpectErrors(schemas, @"{\"a\":\"x\",\"c\":{\"k\":false,\"zz\":1},\"d\":[],\"f\":false,\"g\":{\"h\":2,\"i\":3},"
                          @"\"yy\":true}",
                 3, @"undeclared fields");
    before = SZFFailures;
    SZFQuiet = YES;
    SZFParseSchemas(@"```schema frame.x\nq: strng\n```\n```schema frame.y\nr: @nope\n```\n", @"bad-doc");
    SZFQuiet = NO;
    int provoked = SZFFailures - before;
    SZFFailures = before;
    if (provoked != 2) SZFFail(@"self-test: a bad type and an undefined reference must each fail (got %d)", provoked);
}

#pragma mark - Tables in the prose

// The rows of the Markdown tables in the section under `heading` ("## Static strings"), up to the next "## ": the
// first column's `code` span mapped to the second column's text. Header and separator rows have no code span, so
// they are skipped. nil when the heading is missing.
static NSDictionary<NSString *, NSString *> *SectionTableRows(NSString *markdown, NSString *heading) {
    NSRange start = [markdown rangeOfString:[NSString stringWithFormat:@"\n%@\n", heading]];
    if (start.location == NSNotFound) return nil;
    NSMutableDictionary<NSString *, NSString *> *rows = [NSMutableDictionary dictionary];
    for (NSString *line in [[markdown substringFromIndex:NSMaxRange(start)] componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"## "]) break;
        if (![line hasPrefix:@"| `"]) continue;
        NSArray<NSString *> *cells = [line componentsSeparatedByString:@"|"];
        if (cells.count < 4) continue;
        NSCharacterSet *trim = NSCharacterSet.whitespaceCharacterSet;
        NSString *key = [[cells[1] stringByTrimmingCharactersInSet:trim]
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"`"]];
        rows[key] = [cells[2] stringByTrimmingCharactersInSet:trim];
    }
    return rows;
}

static void SelfTestTables(void) {
    NSString *doc = @"# T\n\n## A\n\nProse with a | bar.\n\n| Key | English |\n|---|---|\n| `x` | One |\n"
                    @"| `y` | Two, `z` inside |\n\n## B\n\n| `w` | Later |\n";
    NSDictionary *rows = SectionTableRows(doc, @"## A");
    if (![rows isEqual:(@{@"x" : @"One", @"y" : @"Two, `z` inside"})])
        SZFFail(@"self-test: table rows parsed as %@", rows);
    if (SectionTableRows(doc, @"## Missing") != nil) SZFFail(@"self-test: a missing section must give nil");
}

// The enum values a schema rule allows for `path` ("code" in type.error), in document order.
static NSArray<NSString *> *EnumValues(SZFSchemas *schemas, NSString *schemaID, NSString *path) {
    for (SZFRule *rule in schemas[schemaID]) {
        if (![[rule.segments componentsJoinedByString:@"."] isEqualToString:path]) continue;
        for (NSString *type in rule.types)
            if ([type hasPrefix:@"enum("])
                return [[type substringWithRange:NSMakeRange(5, type.length - 6)] componentsSeparatedByString:@","];
    }
    return @[];
}

// What a person reads and what the code checks are written twice in PROTOCOL.md: once as a table for people, once
// as a schema or fixture for machines. A string or error code added to one only would reach the views undocumented
// or documented but never sent.
static void CheckProseTables(NSString *markdown, SZFSchemas *schemas, NSDictionary *welcome) {
    NSDictionary *strings = SectionTableRows(markdown, @"## Static strings");
    if (![strings isEqual:welcome[@"strings"]])
        SZFFail(@"PROTOCOL.md § Static strings %@ differs from frames/welcome.json strings %@", strings,
                welcome[@"strings"]);
    NSDictionary *errors = SectionTableRows(markdown, @"## Replies and errors");
    NSSet *documented = [NSSet setWithArray:errors.allKeys ?: @[]];
    NSSet *schema = [NSSet setWithArray:EnumValues(schemas, @"type.error", @"code")];
    if (documented.count == 0 || ![documented isEqualToSet:schema])
        SZFFail(@"PROTOCOL.md § Replies and errors lists %@, but type.error's code allows %@",
                [documented.allObjects sortedArrayUsingSelector:@selector(compare:)],
                [schema.allObjects sortedArrayUsingSelector:@selector(compare:)]);
}

// Field tables: a Markdown table whose header's first cell is "Field of `<schema id>`" documents that block's fields,
// one `code` span per row, up to the first line that is not part of the table. Maps each schema id to its keys.
static NSDictionary<NSString *, NSSet<NSString *> *> *FieldTables(NSString *markdown) {
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *tables = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *current = nil;
    for (NSString *line in [markdown componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"| Field of `"]) {
            NSString *rest = [line substringFromIndex:12];
            NSRange end = [rest rangeOfString:@"`"];
            if (end.location == NSNotFound) continue;
            NSString *schemaID = [rest substringToIndex:end.location];
            if (tables[schemaID]) SZFFail(@"PROTOCOL.md: two field tables for %@", schemaID);
            current = tables[schemaID] = [NSMutableSet set];
            continue;
        }
        if (!current) continue;
        if (![line hasPrefix:@"|"]) {
            current = nil;
            continue;
        }
        if (![line hasPrefix:@"| `"]) continue; // the separator row
        NSString *cell = [line componentsSeparatedByString:@"|"][1];
        cell = [[cell stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"`"]];
        [current addObject:cell];
    }
    return tables;
}

// The fields a field table must list: each rule's first key below `data` (snapshots) or the object (types), leaving
// out an array's elements, which the array's own row covers.
static NSSet<NSString *> *TopLevelFields(SZFSchemas *schemas, NSString *schemaID) {
    NSMutableSet<NSString *> *fields = [NSMutableSet set];
    for (SZFRule *rule in schemas[schemaID]) {
        NSArray<NSString *> *segments = rule.segments;
        if ([schemaID hasPrefix:@"snapshot."] && segments.count > 1 && [segments[0] isEqualToString:@"data"])
            segments = [segments subarrayWithRange:NSMakeRange(1, segments.count - 1)];
        if (![segments[0] hasSuffix:@"[]"]) [fields addObject:segments[0]];
    }
    return fields;
}

// What § Devices and § Joining tell people the views receive is the schema: a field added to one only would reach
// the views undocumented, or be documented and never sent. Pending blocks are never read by any check, so none may
// remain once their views exist.
static void CheckFieldTables(NSString *markdown, SZFSchemas *schemas) {
    if ([markdown containsString:@"```schema-pending"])
        SZFFail(@"PROTOCOL.md: a schema-pending block is a contract nothing checks; make it a schema block");
    NSDictionary<NSString *, NSSet<NSString *> *> *tables = FieldTables(markdown);
    for (NSString *schemaID in @[ @"type.device_row", @"snapshot.join", @"type.join_request" ])
        if (!tables[schemaID]) SZFFail(@"PROTOCOL.md: no field table for %@", schemaID);
    for (NSString *schemaID in tables) {
        if (!schemas[schemaID]) {
            SZFFail(@"PROTOCOL.md: a field table names %@, which has no schema block", schemaID);
            continue;
        }
        NSSet *expected = TopLevelFields(schemas, schemaID);
        if (![tables[schemaID] isEqualToSet:expected])
            SZFFail(@"PROTOCOL.md: the field table of %@ lists %@, but its schema declares %@", schemaID,
                    [tables[schemaID].allObjects sortedArrayUsingSelector:@selector(compare:)],
                    [expected.allObjects sortedArrayUsingSelector:@selector(compare:)]);
    }
}

static void SelfTestFieldTables(void) {
    NSString *doc = @"```schema snapshot.v\ndata.a: string\ndata.b: array\ndata.b[]: string\n```\n"
                    @"```schema type.w\nc: bool\nd.e: string\n```\n\n"
                    @"| Field of `snapshot.v` | Type |\n|---|---|\n| `a` | s |\n| `b` | t |\nAfter.\n"
                    @"| `zz` | not in a field table |\n\n| Field of `type.w` | Type |\n|---|---|\n| `c` | b |\n";
    SZFSchemas *schemas = SZFParseSchemas(doc, @"self-test tables");
    NSDictionary *tables = FieldTables(doc);
    if (![tables[@"snapshot.v"] isEqualToSet:TopLevelFields(schemas, @"snapshot.v")])
        SZFFail(@"self-test: field table of snapshot.v read as %@", tables[@"snapshot.v"]);
    if ([tables[@"type.w"] isEqualToSet:TopLevelFields(schemas, @"type.w")])
        SZFFail(@"self-test: a field table missing `d` must differ from its schema");
}

#pragma mark - Fixtures

static NSArray<NSString *> *SchemaIDsForFrame(NSDictionary *frame, NSString *relativePath, NSString *where) {
    NSString *type = [frame[@"type"] isKindOfClass:NSString.class] ? frame[@"type"] : nil;
    if (!type) {
        SZFFail(@"%@: no string \"type\"", where);
        return @[];
    }
    if ([relativePath hasPrefix:@"replies/"]) {
        if (![frame[@"ok"] isEqual:@YES]) SZFFail(@"%@: replies/ holds successful replies only", where);
        NSString *intent = relativePath.lastPathComponent.stringByDeletingPathExtension;
        return @[ @"frame.reply", [@"result." stringByAppendingString:intent] ];
    }
    if ([type isEqualToString:@"snapshot"]) {
        NSString *view = [frame[@"view"] isKindOfClass:NSString.class] ? frame[@"view"] : @"?";
        if ([frame[@"rev"] isKindOfClass:NSNumber.class] && [frame[@"rev"] integerValue] < 1)
            SZFFail(@"%@: rev starts at 1", where);
        return @[ @"frame.snapshot", [@"snapshot." stringByAppendingString:view] ];
    }
    if ([relativePath.pathExtension isEqualToString:@"jsonl"]) {
        return @[ @"frame.intent", [@"intent." stringByAppendingString:type] ];
    }
    return @[ [@"frame." stringByAppendingString:type] ];
}

static id CheckFrame(NSData *bytes, NSString *relativePath, NSString *where, SZFSchemas *schemas,
                     NSMutableSet<NSString *> *used) {
    if (bytes.length > SZFRIENDS_MAX_FRAME_BYTES)
        SZFFail(@"%@: %lu bytes exceeds the 8 MiB frame cap", where, (unsigned long)bytes.length);
    NSError *error = nil;
    id frame = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
    if (![frame isKindOfClass:NSDictionary.class]) {
        SZFFail(@"%@: not a JSON object (%@)", where, error.localizedDescription ?: @"other JSON value");
        return nil;
    }
    NSMutableArray<NSString *> *present = [NSMutableArray array];
    for (NSString *schemaID in SchemaIDsForFrame(frame, relativePath, where)) {
        if (schemas[schemaID]) {
            [present addObject:schemaID];
            [used addObject:schemaID];
        } else {
            SZFFail(@"%@: PROTOCOL.md has no schema %@", where, schemaID);
        }
    }
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    SZFValidate(frame, present, schemas, where, errors);
    for (NSString *message in errors) SZFFail(@"%@", message);
    return frame;
}

// Parsed fixtures by relative path ("frames/welcome.json"), for the cross-checks below.
static NSUInteger CheckFixtures(NSString *directory, SZFSchemas *schemas, NSMutableSet<NSString *> *used,
                                NSMutableDictionary<NSString *, NSDictionary *> *parsed) {
    NSUInteger frames = 0;
    NSArray<NSString *> *paths = [[[NSFileManager defaultManager] enumeratorAtPath:directory].allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableSet<NSString *> *intentIDs = [NSMutableSet set];
    for (NSString *relativePath in paths) {
        NSString *fullPath = [directory stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDirectory];
        if (isDirectory || [relativePath.lastPathComponent isEqualToString:@"README.md"]) continue;
        // text/ holds test vectors for text rules several suites share (invisible-cases.json, owned by the views),
        // not frames: nothing there crosses the socket, so no schema here describes it.
        if ([relativePath hasPrefix:@"text/"]) continue;
        // vectors/ holds the helper's exported test vectors for the Rust core (objc-*.json), not frames either; their
        // own check is friends-vectors-check, which regenerates them and compares byte for byte.
        if ([relativePath hasPrefix:@"vectors/"]) continue;
        // scheduler/ holds the transfer scheduler's scenarios, which the Rust simulator and the helper's scheduler
        // tests both replay (ADR 0018 WP2): inputs to a planner, not frames.
        if ([relativePath hasPrefix:@"scheduler/"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        NSString *extension = relativePath.pathExtension;
        if ([extension isEqualToString:@"json"]) {
            id frame = CheckFrame(data, relativePath, relativePath, schemas, used);
            if (frame) parsed[relativePath] = frame;
            frames++;
        } else if ([extension isEqualToString:@"jsonl"]) {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            __block NSUInteger lineNumber = 0;
            __block NSUInteger lineFrames = 0;
            [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                (void)stop;
                lineNumber++;
                if ([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0) return;
                lineFrames++;
                NSString *where = [NSString stringWithFormat:@"%@:%lu", relativePath, (unsigned long)lineNumber];
                id frame = CheckFrame([line dataUsingEncoding:NSUTF8StringEncoding], relativePath, where, schemas,
                                      used);
                NSString *frameID = [frame isKindOfClass:NSDictionary.class] ? frame[@"id"] : nil;
                if ([frameID isKindOfClass:NSString.class] && ![intentIDs member:frameID]) {
                    [intentIDs addObject:frameID];
                } else {
                    SZFFail(@"%@: intent ids must be unique strings", where);
                }
            }];
            frames += lineFrames;
        } else {
            // A fixture in another format would never be validated; refuse it rather than skip it silently.
            SZFFail(@"%@: fixtures are .json or .jsonl", relativePath);
        }
    }
    return frames;
}

#pragma mark - One contract, three places

static void ExpectInteger(id value, long long expected, NSString *what) {
    if (![value isKindOfClass:NSNumber.class] || [value longLongValue] != expected)
        SZFFail(@"%@ is %@, but client/szfriends_client.h says %lld", what, value ?: @"absent", expected);
}

static void CheckConstants(NSString *markdown, NSDictionary<NSString *, NSDictionary *> *parsed) {
    NSString *version = [NSString stringWithFormat:@"version %d.%d", SZFRIENDS_PROTOCOL_MAJOR,
                                                   SZFRIENDS_PROTOCOL_MINOR];
    NSString *title = [markdown componentsSeparatedByString:@"\n"].firstObject;
    if (![title hasSuffix:version]) SZFFail(@"PROTOCOL.md title '%@' does not end in '%@'", title, version);
    if (![markdown containsString:@"8,388,608 bytes"]) SZFFail(@"PROTOCOL.md no longer states the frame cap");
    NSDictionary *hello = parsed[@"frames/hello.json"], *welcome = parsed[@"frames/welcome.json"];
    if (!hello || !welcome) {
        SZFFail(@"fixtures: frames/hello.json and frames/welcome.json are required");
        return;
    }
    ExpectInteger(hello[@"protocol"][@"major"], SZFRIENDS_PROTOCOL_MAJOR, @"hello.protocol.major");
    ExpectInteger(hello[@"protocol"][@"minor"], SZFRIENDS_PROTOCOL_MINOR, @"hello.protocol.minor");
    ExpectInteger(hello[@"protocol"][@"min_major"], SZFRIENDS_PROTOCOL_MIN_MAJOR, @"hello.protocol.min_major");
    ExpectInteger(welcome[@"protocol"][@"major"], SZFRIENDS_PROTOCOL_MAJOR, @"welcome.protocol.major");
    ExpectInteger(welcome[@"protocol"][@"minor"], SZFRIENDS_PROTOCOL_MINOR, @"welcome.protocol.minor");
    ExpectInteger(welcome[@"limits"][@"max_frame_bytes"], (long long)SZFRIENDS_MAX_FRAME_BYTES,
                  @"welcome.limits.max_frame_bytes");
    // The composer's cap is the helper's message cap; a view enforcing a larger one would let people type text
    // the helper then refuses.
    id messageCap = welcome[@"limits"][@"max_message_bytes"];
    for (NSString *path in parsed) {
        id composer = parsed[path][@"data"][@"composer"];
        if ([composer isKindOfClass:NSDictionary.class] && ![composer[@"max_text_bytes"] isEqual:messageCap])
            SZFFail(@"%@: composer.max_text_bytes differs from welcome.limits.max_message_bytes", path);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <PROTOCOL.md> <fixtures dir>\n", argv[0]);
            return 2;
        }
        RunSelfTest();
        SelfTestTables();
        SelfTestFieldTables();
        NSString *protocolPath = @(argv[1]);
        NSString *markdown = [NSString stringWithContentsOfFile:protocolPath encoding:NSUTF8StringEncoding error:NULL];
        if (!markdown) {
            SZFFail(@"cannot read %@", protocolPath);
            return 1;
        }
        SZFSchemas *schemas = SZFParseSchemas(markdown, protocolPath.lastPathComponent);
        if (schemas.count < 10) SZFFail(@"PROTOCOL.md: only %lu schema blocks found", (unsigned long)schemas.count);
        NSMutableSet<NSString *> *used = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSDictionary *> *parsed = [NSMutableDictionary dictionary];
        SZFTypesMatched = [NSMutableSet set];
        NSUInteger frames = CheckFixtures(@(argv[2]), schemas, used, parsed);
        NSSet<NSString *> *typesMatched = [SZFTypesMatched copy];
        SZFTypesMatched = nil;
        CheckConstants(markdown, parsed);
        CheckProseTables(markdown, schemas, parsed[@"frames/welcome.json"]);
        CheckFieldTables(markdown, schemas);

        // Coverage: a schema without a fixture is a contract nobody has exercised.
        NSMutableSet<NSString *> *referencedTypes = [NSMutableSet set];
        for (NSString *schemaID in schemas) {
            for (SZFRule *rule in schemas[schemaID])
                for (NSString *type in rule.types)
                    if ([type hasPrefix:@"@"]) [referencedTypes addObject:[type substringFromIndex:1]];
        }
        for (NSString *schemaID in [schemas.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ([schemaID hasPrefix:@"type."]) {
                if (![referencedTypes containsObject:[schemaID substringFromIndex:5]])
                    SZFFail(@"PROTOCOL.md: %@ is never referenced", schemaID);
                // An optional field's object (a profile's devices, a row's removal) may be absent from every
                // fixture while its schema is still referenced; then nothing ever checked an example of it.
                else if (![typesMatched containsObject:schemaID])
                    SZFFail(@"PROTOCOL.md: no fixture holds a %@", schemaID);
            } else if (![used containsObject:schemaID]) {
                SZFFail(@"PROTOCOL.md: %@ has no fixture", schemaID);
            }
        }
        if (SZFFailures) {
            fprintf(stderr, "SZFriendsProtocolTests: %d failures\n", SZFFailures);
            return 1;
        }
        printf("SZFriendsProtocolTests passed (%lu frames, %lu schemas)\n", (unsigned long)frames,
               (unsigned long)schemas.count);
        return 0;
    }
}
