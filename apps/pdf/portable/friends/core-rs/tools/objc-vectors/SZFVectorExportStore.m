// Vector export: the store (ADR 0003). The schema a fresh store and the committed v1 fixture migrate to, as SQLite
// itself prints it; search folding; the transfer and outbox state machines over every state and event; and file
// names as the receiving side sanitises them. The Rust store must create byte-identical DDL and agree on each case.
//
// Stores are made in a temporary directory removed afterwards; nothing reaches the person's state directory.

#import "SZFVectorExport.h"

#import <sqlite3.h>

#import "service/store/SZFriendsStoreInternal.h"

static NSArray *SZFSchemaRows(SZFriendsStore *store) {
    NSMutableArray *rows = [NSMutableArray array];
    [store performOnWriter:^(SZFriendsStoreDB *db) {
        [db run:@"SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
                @"ORDER BY type, name"
            binds:nil
              row:^(sqlite3_stmt *s) {
                  [rows addObject:@[ SZFriendsColumnText(s, 0) ?: @"", SZFriendsColumnText(s, 1) ?: @"",
                                     SZFriendsColumnText(s, 2) ?: @"", SZFriendsColumnText(s, 3) ?: [NSNull null] ]];
              }
            error:NULL];
    }];
    return rows;
}

static id SZFScalar(SZFriendsStore *store, NSString *sql) {
    __block id value = nil;
    [store performOnWriter:^(SZFriendsStoreDB *db) { value = [db scalar:sql binds:nil error:NULL]; }];
    return value ?: [NSNull null];
}

static NSString *SZFTemporaryDirectory(NSString *label) {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szf-store-export.XXXXXX"];
    char *path = strdup(template.fileSystemRepresentation);
    NSString *made = mkdtemp(path) ? [NSString stringWithUTF8String:path] : nil;
    free(path);
    return [made stringByAppendingPathComponent:label];
}

static NSDictionary *SZFStoreFacts(NSString *directory) {
    NSError *error = nil;
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:directory error:&error];
    if (store == nil) {
        fprintf(stderr, "SZFVectorExport: store: %s\n", error.localizedDescription.UTF8String);
        exit(1);
    }
    NSDictionary *facts = @{
        @"schema" : SZFSchemaRows(store),
        @"user_version" : SZFScalar(store, @"PRAGMA user_version"),
        @"min_reader_version" : SZFScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'"),
        @"search_uses_index" : @(store.searchUsesIndex),
        @"people" : @(store.peopleByLatestInteraction.count),
        @"integrity" : SZFScalar(store, @"PRAGMA integrity_check"),
    };
    [store close];
    [NSFileManager.defaultManager removeItemAtPath:directory.stringByDeletingLastPathComponent error:NULL];
    return facts;
}

static NSDictionary *SZFMigratedFixture(NSString *fixturePath) {
    NSString *directory = SZFTemporaryDirectory(@"v1");
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSString *sql = [NSString stringWithContentsOfFile:fixturePath encoding:NSUTF8StringEncoding error:NULL];
    sqlite3 *db = NULL;
    NSString *path = [directory stringByAppendingPathComponent:@"friends.sqlite"];
    if (sql == nil || sqlite3_open(path.fileSystemRepresentation, &db) != SQLITE_OK ||
        sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL) != SQLITE_OK) {
        fprintf(stderr, "SZFVectorExport: cannot load %s\n", fixturePath.UTF8String);
        exit(1);
    }
    sqlite3_close(db);
    return SZFStoreFacts(directory);
}

// Halfwidth katakana sound marks (U+FF9E, U+FF9F) are left out: Foundation folds them one way after a letter and
// another alone, and the Rust store keeps them as they are.
static NSArray *SZFFolds(void) {
    NSArray<NSString *> *inputs = @[
        @"Report", @"RÉSUMÉ café", @"ＡＢＣ１２３", @"合同 report", @"Straße", @"ÅNGSTRÖM", @"naïve façade",
        @"ｶﾀｶﾅ", @"İstanbul", @"Ǆemal", @"Ω and ω", @"éclair", @"ﬁle", @"Ⅻ", @"①", @"",
        @"x\u0301y", @"मेरा नाम", @"ガギ", @"Ελληνικά ΟΔΟΣ", @"Tiếng Việt", @"한국어", @"مرحبًا", @"Œuvre æ",
        @"Ⓐ", @"ǅ", @"ﬀ", @"ŉ", @"ΐ", @"Ĳ", @"Ⅰ", @"ᾈ", @"　x", @"＠＃",
    ];
    NSMutableArray *cases = [NSMutableArray array];
    for (NSString *input in inputs) [cases addObject:@{@"input" : input, @"folded" : SZFriendsSearchFold(input)}];
    return cases;
}

static NSArray *SZFTransferStates(void) {
    NSMutableArray *cases = [NSMutableArray array];
    for (int outgoing = 0; outgoing <= 1; outgoing++) {
        for (NSInteger state = SZFriendsTransferStateQueued; state <= SZFriendsTransferStateFailed; state++) {
            for (NSInteger event = SZFriendsTransferEventOfferDelivered; event <= SZFriendsTransferEventRetry;
                 event++) {
                SZFriendsTransferState next = SZFriendsTransferNextState(outgoing, (SZFriendsTransferState)state,
                                                                         (SZFriendsTransferEvent)event);
                [cases addObject:@[ @(outgoing), @(state), @(event), @(next) ]];
            }
        }
    }
    return cases;
}

static NSArray *SZFOutboxStates(void) {
    NSMutableArray *cases = [NSMutableArray array];
    for (NSInteger state = SZFriendsOutboxStateQueued; state <= SZFriendsOutboxStateFailed; state++) {
        for (NSInteger event = SZFriendsOutboxEventRouteAvailable; event <= SZFriendsOutboxEventExpired; event++) {
            SZFriendsOutboxState next = SZFriendsOutboxNextState((SZFriendsOutboxState)state,
                                                                 (SZFriendsOutboxEvent)event);
            [cases addObject:@[ @(state), @(event), @(next) ]];
        }
    }
    return cases;
}

static NSArray *SZFSanitizedNames(void) {
    NSString *longName = [[@"" stringByPaddingToLength:300 withString:@"長" startingAtIndex:0]
        stringByAppendingString:@".pdf"];
    NSArray<NSString *> *inputs = @[
        @"Plan.pdf", @"../../etc/passwd", @"..hidden", @"  spaced  ", @"a/b:c\\d.txt", @"invoice‮fdp.exe",
        @"tab\there", @"​zero﻿", @"", @"...", @"été.txt", longName, @"name.verylongextension1",
    ];
    NSMutableArray *cases = [NSMutableArray array];
    for (NSString *input in inputs) {
        [cases addObject:@{@"input" : input, @"sanitized" : SZFriendsSanitizedFileName(input)}];
    }
    return cases;
}

NSDictionary *SZFExportStore(NSString *fixturePath) {
    return @{
        @"schema_version" : @(SZFriendsStoreSchemaVersion),
        @"fresh" : SZFStoreFacts(SZFTemporaryDirectory(@"fresh")),
        @"migrated_v1" : SZFMigratedFixture(fixturePath),
        @"fold" : SZFFolds(),
        @"transfer_next_state" : SZFTransferStates(),
        @"outbox_next_state" : SZFOutboxStates(),
        @"sanitized_file_names" : SZFSanitizedNames(),
    };
}
