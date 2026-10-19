// Tests for the shared YAML state codec (core/spdf_yaml.c): value-type round
// trips, quoting/escaping edge cases, human-edit tolerance, corrupt-input
// behavior, realistic state-file fixtures, and the JSON -> YAML migration
// helper (including its multi-process idempotence guarantees).

#import <Foundation/Foundation.h>

#include "../../core/spdf_yaml.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int gFailureCount = 0;

static void fail(NSString* label, NSString* detail) {
    fprintf(stderr, "FAIL %s: %s\n", label.UTF8String, detail.UTF8String);
    ++gFailureCount;
}

static NSString* take_string(char* text) {
    if (!text) return nil;
    NSString* result = [NSString stringWithUTF8String:text];
    free(text);
    return result;
}

static id json_object_from_string(NSString* json) {
    if (!json) return nil;
    NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data
                                                  options:NSJSONReadingFragmentsAllowed
                                                    error:nil]
                : nil;
}

static NSString* pretty_json_for_object(id object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

// The load-bearing property: NSJSONSerialization output -> YAML -> JSON must
// reparse to an equal object graph.
static void expect_object_round_trip(NSString* label, id object) {
    NSString* json = pretty_json_for_object(object);
    if (!json) {
        fail(label, @"could not serialize fixture to JSON");
        return;
    }
    NSString* yaml = take_string(spdf_yaml_from_json(json.UTF8String, "test header"));
    if (!yaml) {
        fail(label, [NSString stringWithFormat:@"spdf_yaml_from_json failed for %@", json]);
        return;
    }
    NSString* backToJSON = take_string(spdf_json_from_yaml(yaml.UTF8String));
    if (!backToJSON) {
        fail(label, [NSString stringWithFormat:@"spdf_json_from_yaml failed for YAML:\n%@", yaml]);
        return;
    }
    id reparsed = json_object_from_string(backToJSON);
    if (![reparsed isEqual:object]) {
        fail(label, [NSString stringWithFormat:@"round trip mismatch.\nfixture: %@\nyaml:\n%@\nreparsed: %@", object,
                                               yaml, reparsed]);
    }
}

// Emitting the same object twice must produce identical bytes (diffability),
// and a parse->emit cycle of the YAML itself must be byte-stable.
static void expect_emit_stability(NSString* label, id object) {
    NSString* json = pretty_json_for_object(object);
    NSString* first = take_string(spdf_yaml_from_json(json.UTF8String, "stability"));
    NSString* second = take_string(spdf_yaml_from_json(json.UTF8String, "stability"));
    if (!first || ![first isEqualToString:second]) {
        fail(label, @"two emits of the same object differ");
        return;
    }
    // YAML -> JSON -> YAML must reproduce the same YAML bytes (numbers are
    // verbatim tokens, strings requote identically).
    NSString* intermediate = take_string(spdf_json_from_yaml(first.UTF8String));
    NSString* reEmitted = take_string(spdf_yaml_from_json(intermediate.UTF8String, "stability"));
    if (!reEmitted || ![reEmitted isEqualToString:first]) {
        fail(label, [NSString stringWithFormat:@"yaml->json->yaml not byte-stable.\nfirst:\n%@\nsecond:\n%@", first,
                                               reEmitted]);
    }
}

static void expect_yaml_parses_to(NSString* label, NSString* yaml, id expected) {
    NSString* json = take_string(spdf_json_from_yaml(yaml.UTF8String));
    if (!json) {
        fail(label, [NSString stringWithFormat:@"parser rejected YAML:\n%@", yaml]);
        return;
    }
    id parsed = json_object_from_string(json);
    if (![parsed isEqual:expected]) {
        fail(label, [NSString stringWithFormat:@"expected %@, got %@ (json %@)", expected, parsed, json]);
    }
}

static void expect_yaml_rejected(NSString* label, NSString* yaml) {
    char* json = spdf_json_from_yaml(yaml.UTF8String);
    if (json) {
        fail(label, [NSString stringWithFormat:@"expected parse failure, got %s", json]);
        free(json);
    }
}

static void expect_json_rejected(NSString* label, NSString* json) {
    char* yaml = spdf_yaml_from_json(json.UTF8String, NULL);
    if (yaml) {
        fail(label, [NSString stringWithFormat:@"expected JSON parse failure, got %s", yaml]);
        free(yaml);
    }
}

// ---------------------------------------------------------------- fixtures

// Mirrors savePersistentState's settings.json shape (ShenzhenPDFMac.mm).
static NSDictionary* settings_fixture(void) {
    return @{
        @"version" : @1,
        @"fitMode" : @2,
        @"viewMode" : @1,
        @"sidebarWidth" : @260.5,
        @"minimapWidth" : @96,
        @"defaultSidebarVisibleForNewDocuments" : @YES,
        @"defaultMinimapVisibleForNewDocuments" : @NO,
        @"collapseWhitespaceWhenCopyingText" : @YES,
        @"searchJumpsToNearestResult" : @YES,
        @"windowSize" : @{@"width" : @1120, @"height" : @800},
        @"commentAuthor" : @"Raph",
        @"translateSourceLanguage" : @"zh",
        @"translateTargetLanguage" : @"en",
        @"showShortcutHelpOnLaunch" : @NO,
        @"autoUpdateEnabled" : @YES,
        @"skippedUpdateVersion" : @"",
        @"preventSleepInPresentation" : @YES,
        @"defaultReaderPromptDismissed" : @NO,
        @"fullDiskAccessPromptDismissed" : @NO,
        @"permissionsWizardShown" : @YES,
        @"printScalingMode" : @0,
        @"printCustomScale" : @1.25,
        @"markdownFontScale" : @1.15,
        @"markdownTheme" : @"dark",
        @"recentlyOpened" : @[
            @"/Users/raph/Downloads/sample catalogue 样本目录.pdf",
            @"/Users/raph/Documents/deep: dive.pdf",
            @"/tmp/plain.pdf",
        ],
    };
}

// Mirrors currentWindowSessionDictionary's session.json shape.
static NSDictionary* session_fixture(void) {
    NSDictionary* tab = @{
        @"path" : @"/Users/raph/Documents/微信图片_20240101.pdf",
        @"title" : @"微信图片_20240101",
        @"page" : @41,
        @"zoom" : @1.5,
        @"customZoom" : @2.25,
        @"fitMode" : @4,
        @"viewMode" : @1,
        @"scrollX" : @0.0,
        @"scrollY" : @1523.75,
        @"hasScrollOrigin" : @YES,
        @"searchText" : @"多行\n查询: test",
        @"searchRegex" : @NO,
        @"searchRegexMultiline" : @NO,
        @"findMatchIndex" : @-1,
        @"markdownLandscape" : @YES,
        @"showSidebar" : @YES,
        @"showMinimap" : @NO,
        @"readOnly" : @NO,
        @"workingPath" : @"",
        @"roCopyFileSize" : @0,
        @"roCopyModifiedAt" : @0.0,
    };
    return @{
        @"version" : @1,
        @"windows" : @[
            @{
                @"id" : @"E4C7A0DE-1111-2222-3333-444455556666",
                @"frame" : @{@"x" : @120.0, @"y" : @64.0, @"width" : @1440.0, @"height" : @860.0},
                @"selectedTab" : @0,
                @"tabs" : @[ tab ],
            },
            @{
                @"id" : @"F0000000-AAAA-BBBB-CCCC-DDDDEEEEFFFF",
                @"frame" : @{@"x" : @0.0, @"y" : @0.0, @"width" : @1120.0, @"height" : @800.0},
                @"selectedTab" : @1,
                @"tabs" : @[],
            },
        ],
    };
}

// Mirrors saveDocumentStateForTab / pageGeometryDictionaryForTab shapes:
// documents.json is keyed by absolute file path.
static NSDictionary* documents_fixture(void) {
    NSMutableArray* geometry = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        [geometry addObject:@(612.0 + i)];
        [geometry addObject:@(792.5)];
    }
    return @{
        @"/Users/raph/Downloads/sample catalogue 样本目录.pdf" : @{
            @"path" : @"/Users/raph/Downloads/sample catalogue 样本目录.pdf",
            @"title" : @"sample catalogue 样本目录",
            @"showSidebar" : @YES,
            @"showMinimap" : @YES,
            @"geometryVersion" : @1,
            @"geometryFileSize" : @48273923,
            @"geometryModifiedAt" : @1719900000.5,
            @"geometryPageCount" : @8,
            @"pageGeometry" : geometry,
            @"updatedAt" : @1719912345,
        },
        @"/tmp/with \"quotes\" and #hash.pdf" : @{
            @"path" : @"/tmp/with \"quotes\" and #hash.pdf",
            @"title" : @"with \"quotes\" and #hash",
            @"showSidebar" : @NO,
            @"showMinimap" : @NO,
            @"updatedAt" : @1719912400,
        },
    };
}

// favorites.json is a top-level array on the Mac side.
static NSArray* favorites_fixture(void) {
    return @[
        @{
            @"path" : @"/Users/raph/Documents/deep: dive.pdf",
            @"title" : @"deep: dive — chapter 3",
            @"page" : @17,
            @"document" : @NO,
        },
        @{
            @"path" : @"/tmp/plain.pdf",
            @"title" : @"plain",
            @"page" : @1,
            @"document" : @YES,
        },
    ];
}

// bookmarks.json: path -> base64 security-scoped bookmark blob.
static NSDictionary* bookmarks_fixture(void) {
    NSString* blob = [[@"fake bookmark data, long enough to look like the real thing"
        dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    return @{
        @"/Users/raph/Documents/微信图片_20240101.pdf" : blob,
        @"/tmp/plain.pdf" : blob,
    };
}

// ------------------------------------------------------------------- tests

static void test_scalar_and_container_round_trips(void) {
    expect_object_round_trip(@"empty map", @{});
    expect_object_round_trip(@"empty array", @[]);
    expect_object_round_trip(@"map of empties", @{@"a" : @{}, @"b" : @[], @"c" : [NSNull null]});
    expect_object_round_trip(@"bools and null", @{@"t" : @YES, @"f" : @NO, @"n" : [NSNull null]});
    expect_object_round_trip(@"integers", @{@"zero" : @0, @"neg" : @-42, @"big" : @123456789012345});
    expect_object_round_trip(@"doubles", @{@"half" : @0.5, @"neg" : @-3.25, @"tiny" : @0.0001});
    expect_object_round_trip(@"empty string", @{@"s" : @""});
    expect_object_round_trip(@"nested arrays", @{@"a" : @[ @[ @1, @2 ], @[], @[ @{@"k" : @"v"} ] ]});
    NSDictionary* deep = @{@"a" : @{@"b" : @{@"c" : @{@"d" : @{@"e" : @[ @{@"f" : @"g"} ]}}}}};
    expect_object_round_trip(@"deeply nested", deep);
    expect_object_round_trip(@"array of scalars mixed", @[ @1, @"two", @3.5, @YES, [NSNull null] ]);
}

static void test_string_edge_cases(void) {
    NSArray* nasty = @[
        @"looks like a number: 42",
        @"42",
        @"3.14",
        @"-7e10",
        @"true",
        @"false",
        @"null",
        @"~",
        @"yes",
        @"no",
        @"on",
        @"off",
        @"key: value",
        @": leading colon",
        @"- leading dash",
        @"# leading hash",
        @"trailing space ",
        @" leading space",
        @"  ",
        @"line one\nline two\r\nline three",
        @"tab\there",
        @"quote \" and backslash \\",
        @"single ' quote",
        @"unicode path 中文 emoji 🎉 accents éàü",
        @"control \x01 char",
        @"{}",
        @"[]",
        @"{not: flow}",
        @"[not, flow]",
        @"*anchor-looking",
        @"&anchor-looking",
        @"!tag-looking",
        @"%directive-looking",
        @"@at-sign",
        @"| block-looking",
        @"> fold-looking",
        @"ends with colon:",
        @"a # not a comment inside",
    ];
    NSMutableDictionary* map = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < nasty.count; i++) map[[NSString stringWithFormat:@"k%02lu", (unsigned long)i]] = nasty[i];
    expect_object_round_trip(@"nasty string values", map);
    expect_object_round_trip(@"nasty strings as array", nasty);

    // The same strings as KEYS (documents.yaml keys are arbitrary paths).
    NSMutableDictionary* keyed = [NSMutableDictionary dictionary];
    for (NSString* key in nasty) keyed[key] = @1;
    expect_object_round_trip(@"nasty string keys", keyed);

    expect_object_round_trip(@"unicode keys", @{@"路径/文件 名.pdf" : @"值", @"ключ" : @"значение"});
}

static void test_expected_emit_shape(void) {
    NSString* json = @"{\"name\":\"Shenzhen: PDF\",\"count\":3,\"enabled\":true,\"ratio\":0.5,"
                     @"\"nothing\":null,\"list\":[1,\"two\"],\"empty\":{},\"nested\":{\"a\":1}}";
    NSString* yaml = take_string(spdf_yaml_from_json(json.UTF8String, "ShenzhenPDF settings — edit while the app is closed"));
    NSString* expected = @"# ShenzhenPDF settings — edit while the app is closed\n"
                         @"name: \"Shenzhen: PDF\"\n"
                         @"count: 3\n"
                         @"enabled: true\n"
                         @"ratio: 0.5\n"
                         @"nothing: null\n"
                         @"list:\n"
                         @"  - 1\n"
                         @"  - \"two\"\n"
                         @"empty: {}\n"
                         @"nested:\n"
                         @"  a: 1\n";
    if (![yaml isEqualToString:expected]) {
        fail(@"emit shape", [NSString stringWithFormat:@"expected:\n%@\ngot:\n%@", expected, yaml]);
    }

    NSString* seqOfMaps = take_string(spdf_yaml_from_json("{\"tabs\":[{\"path\":\"/a.pdf\",\"page\":3},{\"path\":\"/b.pdf\"}]}", NULL));
    NSString* expectedSeq = @"tabs:\n"
                            @"  - path: \"/a.pdf\"\n"
                            @"    page: 3\n"
                            @"  - path: \"/b.pdf\"\n";
    if (![seqOfMaps isEqualToString:expectedSeq]) {
        fail(@"seq-of-maps shape", [NSString stringWithFormat:@"expected:\n%@\ngot:\n%@", expectedSeq, seqOfMaps]);
    }
}

static void test_human_edit_tolerance(void) {
    expect_yaml_parses_to(@"comments and blank lines", @"# header\n"
                                                       @"\n"
                                                       @"fitMode: 2   # trailing comment\n"
                                                       @"\n"
                                                       @"   \n"
                                                       @"name: \"x\" # after quoted\n"
                                                       @"# middle comment\n"
                                                       @"enabled: true\n",
                          @{@"fitMode" : @2, @"name" : @"x", @"enabled" : @YES});
    expect_yaml_parses_to(@"document start marker", @"---\na: 1\n", @{@"a" : @1});
    expect_yaml_parses_to(@"4-space indent", @"outer:\n    inner: 1\n    other: 2\n",
                          @{@"outer" : @{@"inner" : @1, @"other" : @2}});
    expect_yaml_parses_to(@"seq at parent indent", @"list:\n- 1\n- 2\nafter: true\n",
                          @{@"list" : @[ @1, @2 ], @"after" : @YES});
    expect_yaml_parses_to(@"unquoted plain string", @"title: My Document\n", @{@"title" : @"My Document"});
    expect_yaml_parses_to(@"single quotes", @"title: 'it''s fine'\n", @{@"title" : @"it's fine"});
    expect_yaml_parses_to(@"plain value with colon no space", @"path: /c:/windows/style\n",
                          @{@"path" : @"/c:/windows/style"});
    expect_yaml_parses_to(@"tilde null", @"x: ~\n", @{@"x" : [NSNull null]});
    expect_yaml_parses_to(@"empty value is null", @"x:\ny: 2\n", @{@"x" : [NSNull null], @"y" : @2});
    expect_yaml_parses_to(@"crlf line endings", @"a: 1\r\nb: \"two\"\r\n", @{@"a" : @1, @"b" : @"two"});
    expect_yaml_parses_to(@"trailing whitespace", @"a: 1   \nb: 2\t\n", @{@"a" : @1, @"b" : @2});
    expect_yaml_parses_to(@"dash-only items", @"list:\n  -\n    a: 1\n  - 2\n",
                          @{@"list" : @[ @{@"a" : @1}, @2 ]});
    expect_yaml_parses_to(@"whole doc empty seq", @"[]\n", @[]);
    expect_yaml_parses_to(@"whole doc empty map", @"{}\n", @{});
    expect_yaml_parses_to(@"top-level sequence", @"- path: \"/a.pdf\"\n  page: 1\n- path: \"/b.pdf\"\n",
                          @[ @{@"path" : @"/a.pdf", @"page" : @1}, @{@"path" : @"/b.pdf"} ]);
    // Leading-zero and other lenient numerics stay strings (never corrupted).
    expect_yaml_parses_to(@"leading zero stays string", @"v: 007\n", @{@"v" : @"007"});
    expect_yaml_parses_to(@"plus sign stays string", @"v: +5\n", @{@"v" : @"+5"});
}

static void test_corrupt_inputs(void) {
    expect_yaml_rejected(@"empty file", @"");
    expect_yaml_rejected(@"only comments", @"# nothing here\n\n");
    expect_yaml_rejected(@"tab indentation", @"a:\n\tb: 1\n");
    expect_yaml_rejected(@"unterminated quote", @"a: \"unterminated\n");
    expect_yaml_rejected(@"garbage after quote", @"a: \"x\" garbage\n");
    expect_yaml_rejected(@"binary garbage", @"\x01\x02\x03: \x04\n a");
    expect_yaml_rejected(@"orphan deep indent", @"a: 1\n      b: 2\n");
    expect_yaml_rejected(@"seq item under scalar", @"a: 1\n  - 2\n");
    expect_yaml_rejected(@"json braces multiline", @"{\n  \"a\": 1\n}\n");
    expect_yaml_rejected(@"bad escape", @"a: \"\\q\"\n");
    expect_yaml_rejected(@"lone surrogate", @"a: \"\\ud800\"\n");

    expect_json_rejected(@"json trailing garbage", @"{\"a\":1} x");
    expect_json_rejected(@"json truncated", @"{\"a\":");
    expect_json_rejected(@"json bare word", @"hello");
    expect_json_rejected(@"json single quotes", @"{'a':1}");
}

static void test_state_fixtures(void) {
    expect_object_round_trip(@"settings fixture", settings_fixture());
    expect_object_round_trip(@"session fixture", session_fixture());
    expect_object_round_trip(@"documents fixture", documents_fixture());
    expect_object_round_trip(@"favorites fixture", favorites_fixture());
    expect_object_round_trip(@"bookmarks fixture", bookmarks_fixture());

    expect_emit_stability(@"settings stability", settings_fixture());
    expect_emit_stability(@"session stability", session_fixture());
    expect_emit_stability(@"documents stability", documents_fixture());
    expect_emit_stability(@"favorites stability", favorites_fixture());

    // The per-tab Markdown paper orientation must land as a bare YAML boolean
    // and come back as one: reparsed as the STRING "true" it would restore
    // every tab as rotated, since any non-empty string is truthy going back
    // into SPDFDocumentTab.
    NSString* sessionYAML =
        take_string(spdf_yaml_from_json(pretty_json_for_object(session_fixture()).UTF8String, "session"));
    if (!sessionYAML || [sessionYAML rangeOfString:@"markdownLandscape: true"].location == NSNotFound)
        fail(@"markdownLandscape emits as a bare boolean", sessionYAML ?: @"(emit failed)");
    expect_yaml_parses_to(@"hand-edited markdownLandscape", @"markdownLandscape: false\npage: 2\n",
                          (@{@"markdownLandscape" : @NO, @"page" : @2}));

    // The GTK frontend's hand-built JSON (fixed key order, %.4f zooms) must
    // convert losslessly too, preserving its key order for diffability.
    NSString* gtkSettings = @"{\n"
                            @"  \"fitMode\": 4,\n"
                            @"  \"zoom\": 1.2500,\n"
                            @"  \"continuous\": true,\n"
                            @"  \"showSidebar\": false,\n"
                            @"  \"commentAuthor\": \"Raph\",\n"
                            @"  \"recentlyOpened\": [\n    \"/home/raph/图书/книга.pdf\"\n  ]\n"
                            @"}\n";
    NSString* yaml = take_string(spdf_yaml_from_json(gtkSettings.UTF8String, NULL));
    if (!yaml) {
        fail(@"gtk settings convert", @"conversion failed");
    } else {
        if ([yaml rangeOfString:@"zoom: 1.2500"].location == NSNotFound)
            fail(@"gtk zoom token preserved", yaml);
        NSRange fitRange = [yaml rangeOfString:@"fitMode:"];
        NSRange zoomRange = [yaml rangeOfString:@"zoom:"];
        if (fitRange.location == NSNotFound || zoomRange.location == NSNotFound ||
            fitRange.location > zoomRange.location)
            fail(@"gtk key order preserved", yaml);
        NSString* backToJSON = take_string(spdf_json_from_yaml(yaml.UTF8String));
        id reparsed = json_object_from_string(backToJSON);
        id original = json_object_from_string(gtkSettings);
        if (![reparsed isEqual:original]) fail(@"gtk settings round trip", backToJSON);
    }
}

// ------------------------------------------------------------- migration

static NSString* make_temp_dir(void) {
    NSString* base = [NSTemporaryDirectory() stringByAppendingPathComponent:@"spdf-yaml-tests-XXXXXX"];
    char buffer[1024];
    strlcpy(buffer, base.fileSystemRepresentation, sizeof(buffer));
    if (!mkdtemp(buffer)) return nil;
    return [NSString stringWithUTF8String:buffer];
}

static void write_file(NSString* path, NSString* contents) {
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString* read_file(NSString* path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static void test_migration(void) {
    NSFileManager* fm = NSFileManager.defaultManager;

    // JSON present, YAML missing -> migrated + backup rename.
    {
        NSString* dir = make_temp_dir();
        NSString* json = pretty_json_for_object(settings_fixture());
        write_file([dir stringByAppendingPathComponent:@"settings.json"], json);
        const char* stems[] = {"settings", "session"};
        int migrated = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 2);
        if (migrated != 1) fail(@"migrate count", [NSString stringWithFormat:@"expected 1, got %d", migrated]);
        NSString* yaml = read_file([dir stringByAppendingPathComponent:@"settings.yaml"]);
        if (!yaml) fail(@"migrate creates yaml", dir);
        if (yaml && ![yaml hasPrefix:@"# ShenzhenPDF settings — edit while the app is closed\n"])
            fail(@"migrate header comment", yaml);
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"settings.json"]])
            fail(@"migrate renames json", @"settings.json still present");
        NSString* backup = read_file([dir stringByAppendingPathComponent:@"settings.json.migrated-backup"]);
        if (![backup isEqualToString:json]) fail(@"backup byte-identical", @"backup contents differ");
        // Round trip: the migrated YAML must reparse to the original object.
        id reparsed = json_object_from_string(take_string(spdf_json_from_yaml(yaml.UTF8String)));
        if (![reparsed isEqual:settings_fixture()]) fail(@"migrated yaml reparses", yaml);
        // Idempotence: second run does nothing and changes nothing.
        NSDictionary* attrsBefore = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:@"settings.yaml"]
                                                         error:nil];
        int again = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 2);
        if (again != 0) fail(@"migrate idempotent", [NSString stringWithFormat:@"second run migrated %d", again]);
        NSDictionary* attrsAfter = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:@"settings.yaml"]
                                                        error:nil];
        if (![attrsBefore[NSFileModificationDate] isEqual:attrsAfter[NSFileModificationDate]])
            fail(@"migrate idempotent mtime", @"yaml rewritten on second run");
        [fm removeItemAtPath:dir error:nil];
    }

    // YAML at least as new as the JSON -> JSON untouched, YAML wins
    // (hand-created file or completed prior migration).
    {
        NSString* dir = make_temp_dir();
        NSString* jsonPath = [dir stringByAppendingPathComponent:@"settings.json"];
        write_file(jsonPath, @"{\"fitMode\":1}");
        // Backdate the JSON so the YAML is unambiguously the newer file.
        [fm setAttributes:@{NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:-60]}
             ofItemAtPath:jsonPath
                    error:nil];
        write_file([dir stringByAppendingPathComponent:@"settings.yaml"], @"fitMode: 3\n");
        const char* stems[] = {"settings"};
        int migrated = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 1);
        if (migrated != 0) fail(@"yaml wins: no migration", @"migrated despite newer yaml present");
        if (![read_file([dir stringByAppendingPathComponent:@"settings.yaml"]) isEqualToString:@"fitMode: 3\n"])
            fail(@"yaml wins: yaml untouched", @"yaml changed");
        if (![read_file(jsonPath) isEqualToString:@"{\"fitMode\":1}"]) fail(@"yaml wins: json untouched", @"json changed");
        [fm removeItemAtPath:dir error:nil];
    }

    // JSON strictly newer than the YAML (a pre-YAML build ran after the YAML
    // was written: downgrade then upgrade) -> re-migrated, JSON state wins.
    {
        NSString* dir = make_temp_dir();
        NSString* yamlPath = [dir stringByAppendingPathComponent:@"settings.yaml"];
        write_file(yamlPath, @"fitMode: 3\n");
        [fm setAttributes:@{NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:-60]}
             ofItemAtPath:yamlPath
                    error:nil];
        write_file([dir stringByAppendingPathComponent:@"settings.json"], @"{\"fitMode\":1}");
        const char* stems[] = {"settings"};
        int migrated = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 1);
        if (migrated != 1) fail(@"newer json re-migrates", [NSString stringWithFormat:@"expected 1, got %d", migrated]);
        id reparsed = json_object_from_string(take_string(spdf_json_from_yaml(read_file(yamlPath).UTF8String)));
        if (![reparsed isEqual:@{@"fitMode" : @1}]) fail(@"newer json wins", read_file(yamlPath));
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"settings.json"]])
            fail(@"newer json renamed", @"settings.json still present");
        if (![read_file([dir stringByAppendingPathComponent:@"settings.json.migrated-backup"])
                isEqualToString:@"{\"fitMode\":1}"])
            fail(@"newer json backup", @"backup contents differ");
        [fm removeItemAtPath:dir error:nil];
    }

    // Malformed JSON -> nothing created, nothing renamed (same as today's
    // corrupt-JSON path: file ignored, defaults apply).
    {
        NSString* dir = make_temp_dir();
        write_file([dir stringByAppendingPathComponent:@"settings.json"], @"{\"fitMode\": oops");
        const char* stems[] = {"settings"};
        int migrated = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 1);
        if (migrated != 0) fail(@"malformed json not migrated", @"claimed migration");
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"settings.yaml"]])
            fail(@"malformed json: no yaml", @"yaml created from garbage");
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"settings.json"]])
            fail(@"malformed json: json kept", @"json disappeared");
        [fm removeItemAtPath:dir error:nil];
    }

    // Neither file present -> no-op, and the lock file appears.
    {
        NSString* dir = make_temp_dir();
        const char* stems[] = {"settings", "session", "documents", "favorites", "bookmarks"};
        int migrated = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 5);
        if (migrated != 0) fail(@"fresh dir no-op", @"migrated in empty dir");
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"migration.lock"]])
            fail(@"lock file created", dir);
        [fm removeItemAtPath:dir error:nil];
    }

    // Full realistic set: all five files migrate in one pass and each YAML
    // reparses to its original object.
    {
        NSString* dir = make_temp_dir();
        NSDictionary* files = @{
            @"settings" : settings_fixture(),
            @"session" : session_fixture(),
            @"documents" : documents_fixture(),
            @"favorites" : favorites_fixture(),
            @"bookmarks" : bookmarks_fixture(),
        };
        for (NSString* stem in files)
            write_file([dir stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]],
                       pretty_json_for_object(files[stem]));
        const char* stems[] = {"settings", "session", "documents", "favorites", "bookmarks"};
        int migrated = spdf_state_migrate_dir(dir.fileSystemRepresentation, stems, 5);
        if (migrated != 5) fail(@"full set migrated", [NSString stringWithFormat:@"expected 5, got %d", migrated]);
        for (NSString* stem in files) {
            NSString* yaml = read_file([dir stringByAppendingPathComponent:[stem stringByAppendingString:@".yaml"]]);
            id reparsed = yaml ? json_object_from_string(take_string(spdf_json_from_yaml(yaml.UTF8String))) : nil;
            if (![reparsed isEqual:files[stem]])
                fail([NSString stringWithFormat:@"full set %@ reparses", stem], yaml ?: @"(missing)");
            if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:
                                               [stem stringByAppendingString:@".json.migrated-backup"]]])
                fail([NSString stringWithFormat:@"full set %@ backup", stem], dir);
        }
        [fm removeItemAtPath:dir error:nil];
    }

    // Concurrent migration: several processes racing on the same directory
    // must produce exactly one clean migration (flock serializes them).
    {
        NSString* dir = make_temp_dir();
        NSString* json = pretty_json_for_object(session_fixture());
        write_file([dir stringByAppendingPathComponent:@"session.json"], json);
        NSMutableArray<NSTask*>* tasks = [NSMutableArray array];
        NSString* helper = NSProcessInfo.processInfo.arguments.firstObject;
        for (int i = 0; i < 4; i++) {
            NSTask* task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:helper];
            task.arguments = @[ @"--migrate-worker", dir ];
            [task launchAndReturnError:nil];
            [tasks addObject:task];
        }
        for (NSTask* task in tasks) [task waitUntilExit];
        int successes = 0;
        for (NSTask* task in tasks)
            if (task.terminationStatus == 0) successes++;
        if (successes != 4) fail(@"concurrent workers exit clean", [NSString stringWithFormat:@"%d/4", successes]);
        NSString* yaml = read_file([dir stringByAppendingPathComponent:@"session.yaml"]);
        id reparsed = yaml ? json_object_from_string(take_string(spdf_json_from_yaml(yaml.UTF8String))) : nil;
        if (![reparsed isEqual:session_fixture()]) fail(@"concurrent migration result", yaml ?: @"(missing)");
        if (![read_file([dir stringByAppendingPathComponent:@"session.json.migrated-backup"]) isEqualToString:json])
            fail(@"concurrent migration backup", @"backup missing or altered");
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"session.json"]])
            fail(@"concurrent migration json gone", @"session.json still present");
        // No stray temp files left behind.
        for (NSString* entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([entry containsString:@".tmp."]) fail(@"no temp litter", entry);
        }
        [fm removeItemAtPath:dir error:nil];
    }
}

static void test_header_helper(void) {
    char buffer[128];
    spdf_state_header_for_file("settings.yaml", buffer, sizeof(buffer));
    if (strcmp(buffer, "ShenzhenPDF settings — edit while the app is closed") != 0)
        fail(@"header for settings.yaml", [NSString stringWithUTF8String:buffer]);
    spdf_state_header_for_file("/some/dir/favorites.json", buffer, sizeof(buffer));
    if (strcmp(buffer, "ShenzhenPDF favorites — edit while the app is closed") != 0)
        fail(@"header strips dir+ext", [NSString stringWithUTF8String:buffer]);
    spdf_state_header_for_file("session", buffer, sizeof(buffer));
    if (strcmp(buffer, "ShenzhenPDF session — edit while the app is closed") != 0)
        fail(@"header bare stem", [NSString stringWithUTF8String:buffer]);
}

int main(int argc, char** argv) {
    @autoreleasepool {
        // Worker mode for the concurrent-migration test: migrate the given
        // directory and exit 0 unless the codec reported an error.
        if (argc == 3 && strcmp(argv[1], "--migrate-worker") == 0) {
            const char* stems[] = {"settings", "session", "documents", "favorites", "bookmarks"};
            int migrated = spdf_state_migrate_dir(argv[2], stems, 5);
            return migrated >= 0 ? 0 : 1;
        }

        test_scalar_and_container_round_trips();
        test_string_edge_cases();
        test_expected_emit_shape();
        test_human_edit_tolerance();
        test_corrupt_inputs();
        test_state_fixtures();
        test_migration();
        test_header_helper();

        if (gFailureCount > 0) {
            fprintf(stderr, "SPDFStateYamlTests: %d failure(s)\n", gFailureCount);
            return 1;
        }
        printf("SPDFStateYamlTests: all tests passed\n");
    }
    return 0;
}
