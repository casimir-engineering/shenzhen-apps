// Local search over messages and file names (ADR 0003 § Search): an FTS5 trigram index over a folded copy of each
// body, a substring filter for one- and two-character terms, and a scan-only path when trigram is missing.
//
// Semantics match the reader's Cmd+K palette: case-, diacritic- and width-insensitive; every whitespace-separated
// term must occur, in any order; hits containing the whole query as typed rank first, then newest.
//
// A message is searched as a reader sees it: each mention as its "@Name" label, never the Friends ID and key its link
// carries (ADR 0007; ADR 0003, Corrections). Search then never finds a message by an ID or key nobody sees, and every
// hit has a match a view can show, so a page of results is never cut short by hits the views would drop.

#import "service/store/SZFriendsStoreInternal.h"

#import "service/presentation/SZFriendsMentions.h"

NS_ASSUME_NONNULL_BEGIN

static const NSStringCompareOptions SZFriendsFoldOptions =
    NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;

NSString *SZFriendsSearchFold(NSString *text) {
    return [text.precomposedStringWithCanonicalMapping stringByFoldingWithOptions:SZFriendsFoldOptions locale:nil];
}

// One stretch of a message as a reader sees it, and where its characters are in the stored text. A link's stored
// stretch is the part a view lights up for it: a mention's label inside its brackets, or a whole other link.
typedef struct {
    NSRange shown, stored;
    BOOL link;
} SZFriendsSearchPiece;

// The text a reader sees: every Friends link replaced by the words it shows. The words are the link's own, not
// SZFriendsMentionsNeutralized's Markdown-escaped form, so a name such as "Mei_Lin" is found as it is shown. A
// stored message has already been checked (only well-formed mentions are still links), so one pass is enough.
static NSString *SZFriendsSearchVisible(NSString *text, NSMutableData *_Nullable pieces) {
    NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks(text);
    if (links.count == 0) {
        SZFriendsSearchPiece whole = {NSMakeRange(0, text.length), NSMakeRange(0, text.length), NO};
        [pieces appendBytes:&whole length:sizeof whole];
        return text;
    }
    NSMutableString *visible = [NSMutableString stringWithCapacity:text.length];
    NSUInteger cursor = 0;
    for (SZFriendsTextLink *link in links) {
        NSRange gap = NSMakeRange(cursor, link.range.location - cursor);
        SZFriendsSearchPiece plain = {NSMakeRange(visible.length, gap.length), gap, NO};
        [pieces appendBytes:&plain length:sizeof plain];
        [visible appendString:[text substringWithRange:gap]];
        // The presentation lights up a mention from its first character to the end of its escaped label
        // (SZFriendsSnapshotBuilder+Mentions.m), and any other link as a whole.
        NSRange stored = link.range;
        if (link.isMention && link.range.length > 1) {
            NSUInteger label = SZFriendsMarkdownLiteral(link.shownText).length;
            stored = NSMakeRange(link.range.location + 1, MIN(label, link.range.length - 1));
        }
        SZFriendsSearchPiece shown = {NSMakeRange(visible.length, link.shownText.length), stored, YES};
        [pieces appendBytes:&shown length:sizeof shown];
        [visible appendString:link.shownText];
        cursor = NSMaxRange(link.range);
    }
    NSRange tail = NSMakeRange(cursor, text.length - cursor);
    SZFriendsSearchPiece last = {NSMakeRange(visible.length, tail.length), tail, NO};
    [pieces appendBytes:&last length:sizeof last];
    [visible appendString:[text substringWithRange:tail]];
    return visible;
}

NSString *SZFriendsSearchFoldItem(NSString *body, SZFriendsItemKind kind) {
    // A file's name is shown as it is, Friends link or not; only a message's links show other words.
    return SZFriendsSearchFold(kind == SZFriendsItemKindMessage ? SZFriendsSearchVisible(body, nil) : body);
}

// Rows written before mentions were folded to their labels still hold each mention's ID and key in `folded`. They are
// refolded once per store; `search_fold` says it was done for this fold.
static NSString *const SZFriendsSearchFoldVersion = @"labels";

static BOOL SZFriendsRefoldSearch(SZFriendsStoreDB *db, NSError **error) {
    id done = [db scalar:@"SELECT value FROM meta WHERE key = 'search_fold'" binds:nil error:NULL];
    if ([done isEqual:SZFriendsSearchFoldVersion]) return YES;
    NSMutableArray<NSArray *> *rows = [NSMutableArray array];
    // LIKE ignores ASCII case, as the search for links does.
    NSString *select = @"SELECT seq, body FROM messages WHERE kind = ? AND body LIKE '%szfriends:%'";
    BOOL ok = [db run:select binds:@[ @(SZFriendsItemKindMessage) ] row:^(sqlite3_stmt *s) {
        [rows addObject:@[ @(SZFriendsColumnInt(s, 0)), SZFriendsColumnText(s, 1) ?: @"" ]];
    } error:error];
    if (!ok) return NO;
    for (NSArray *row in rows) {
        NSArray *binds = @[ SZFriendsSearchFoldItem(row[1], SZFriendsItemKindMessage), row[0] ];
        if (![db run:@"UPDATE messages SET folded = ? WHERE seq = ?" binds:binds row:nil error:error]) return NO;
    }
    return [db run:@"INSERT INTO meta(key, value) VALUES ('search_fold', ?) ON CONFLICT(key) DO UPDATE SET value = ?"
             binds:@[ SZFriendsSearchFoldVersion, SZFriendsSearchFoldVersion ]
               row:nil
             error:error];
}

static NSUInteger SZFriendsCodePoints(NSString *text) {
    return [text lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;
}

BOOL SZFriendsStorePrepareSearch(SZFriendsStoreDB *db, BOOL allowTrigram, BOOL *usesIndex, NSError **error) {
    *usesIndex = NO;
    // ADR 0003 § FTS probe: SQLite before 3.34 has no trigram tokenizer, and before 3.44 (macOS 15 and earlier) an
    // FTS5 table is not innocuous, so with trusted_schema=OFF the triggers below would fail every write to messages.
    // The probe fills a trigram table from a trigger, in temp so it leaves the file untouched either way.
    BOOL trigram = allowTrigram &&
        [db exec:@"CREATE VIRTUAL TABLE temp.szf_probe USING fts5(x, tokenize='trigram');"
                 @"CREATE TEMP TABLE szf_probe_rows(x);"
                 @"CREATE TEMP TRIGGER szf_probe_ai AFTER INSERT ON szf_probe_rows BEGIN "
                 @"INSERT INTO szf_probe(x) VALUES (new.x); END;"
                 @"INSERT INTO szf_probe_rows VALUES ('probe')"
            error:NULL];
    [db exec:@"DROP TABLE IF EXISTS temp.szf_probe_rows; DROP TABLE IF EXISTS temp.szf_probe" error:NULL];
    if (!trigram) {
        NSLog(@"Friends store: SQLite cannot keep an FTS5 trigram index here; search scans messages instead");
        // Writes made without the index mark it stale, so a helper that has trigram rebuilds it before trusting it.
        NSString *stale = @"INSERT INTO meta(key, value) VALUES ('search_stale', '1') "
                          @"ON CONFLICT(key) DO UPDATE SET value = '1'";
        NSString *triggers = [NSString stringWithFormat:
            @"CREATE TEMP TRIGGER IF NOT EXISTS szf_stale_ai AFTER INSERT ON main.messages BEGIN %@; END;"
            @"CREATE TEMP TRIGGER IF NOT EXISTS szf_stale_ad AFTER DELETE ON main.messages BEGIN %@; END;"
            @"CREATE TEMP TRIGGER IF NOT EXISTS szf_stale_au AFTER UPDATE OF folded ON main.messages BEGIN %@; END;",
            stale, stale, stale];
        if (![db exec:triggers error:error]) return NO;
        return [db transaction:^BOOL(NSError **inner) { return SZFriendsRefoldSearch(db, inner); } error:error];
    }
    NSNumber *exists = [db scalar:@"SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'search'"
                            binds:nil
                            error:error];
    if (!exists) return NO;
    id stale = [db scalar:@"SELECT value FROM meta WHERE key = 'search_stale'" binds:nil error:NULL];
    // The index is not a versioned migration: it exists only where the tokenizer does (ADR 0003: vendoring SQLite
    // later is a deps change with no schema change). Temporary triggers keep it in step on this connection only, so
    // a helper without trigram never fires a trigger that would fail on every insert.
    NSString *setup =
        @"CREATE VIRTUAL TABLE IF NOT EXISTS main.search USING fts5(folded, content='messages', "
        @"content_rowid='seq', tokenize='trigram');"
        @"CREATE TEMP TRIGGER IF NOT EXISTS szf_search_ai AFTER INSERT ON main.messages BEGIN "
        @"INSERT INTO search(rowid, folded) VALUES (new.seq, new.folded); END;"
        @"CREATE TEMP TRIGGER IF NOT EXISTS szf_search_ad AFTER DELETE ON main.messages BEGIN "
        @"INSERT INTO search(search, rowid, folded) VALUES ('delete', old.seq, old.folded); END;"
        @"CREATE TEMP TRIGGER IF NOT EXISTS szf_search_au AFTER UPDATE OF folded ON main.messages BEGIN "
        @"INSERT INTO search(search, rowid, folded) VALUES ('delete', old.seq, old.folded); "
        @"INSERT INTO search(rowid, folded) VALUES (new.seq, new.folded); END;";
    BOOL fresh = exists.integerValue > 0 && ![stale isEqual:@"1"];
    BOOL ok = [db transaction:^BOOL(NSError **inner) {
        // A fresh index follows the refold through the triggers. One about to be rebuilt is refolded before the
        // triggers exist, so they never ask it to delete entries it does not hold.
        if (!fresh && !SZFriendsRefoldSearch(db, inner)) return NO;
        if (![db exec:setup error:inner]) return NO;
        if (fresh) return SZFriendsRefoldSearch(db, inner);
        return SZFriendsStoreRebuildSearch(db, inner);
    } error:error];
    if (ok) *usesIndex = YES;
    return ok;
}

BOOL SZFriendsStoreRebuildSearch(SZFriendsStoreDB *db, NSError **error) {
    NSNumber *exists = [db scalar:@"SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'search'"
                            binds:nil
                            error:error];
    if (!exists) return NO;
    if (exists.integerValue > 0 && ![db exec:@"INSERT INTO search(search) VALUES ('rebuild')" error:error]) return NO;
    return [db exec:@"DELETE FROM meta WHERE key = 'search_stale'" error:error];
}

// FTS5 string syntax: a term in double quotes with inner quotes doubled is matched literally, whatever it holds.
static NSString *SZFriendsFTSPhrase(NSString *term) {
    return [NSString stringWithFormat:@"\"%@\"", [term stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

// Sorted, with overlapping ranges joined: overlapping terms ("合同" and "同意" in "合同意向") highlight as one run.
static NSArray<NSValue *> *SZFriendsMergedRanges(NSMutableArray<NSValue *> *found) {
    [found sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return [@(a.rangeValue.location) compare:@(b.rangeValue.location)];
    }];
    NSMutableArray<NSValue *> *merged = [NSMutableArray array];
    for (NSValue *value in found) {
        NSRange range = value.rangeValue;
        NSRange last = merged.lastObject.rangeValue;
        if (merged.count && range.location <= NSMaxRange(last)) {
            NSUInteger end = MAX(NSMaxRange(last), NSMaxRange(range));
            merged[merged.count - 1] = [NSValue valueWithRange:NSMakeRange(last.location, end - last.location)];
        } else {
            [merged addObject:value];
        }
    }
    return merged;
}

static NSArray<NSValue *> *SZFriendsMatchRanges(NSString *text, NSArray<NSString *> *terms) {
    NSMutableArray<NSValue *> *found = [NSMutableArray array];
    for (NSString *term in terms) {
        NSRange searchRange = NSMakeRange(0, text.length);
        while (searchRange.length > 0) {
            NSRange hit = [text rangeOfString:term options:SZFriendsFoldOptions range:searchRange];
            if (hit.location == NSNotFound || hit.length == 0) break;
            [found addObject:[NSValue valueWithRange:hit]];
            NSUInteger next = NSMaxRange(hit);
            searchRange = NSMakeRange(next, text.length - next);
        }
    }
    return SZFriendsMergedRanges(found);
}

// Matches found in what the reader sees, as ranges of the stored text: a match touching a mention's label covers the
// label, never its destination. A term that runs from a label into the words after it still gets both parts.
static NSArray<NSValue *> *SZFriendsHitRanges(NSString *text, SZFriendsItemKind kind, NSArray<NSString *> *terms) {
    NSMutableData *pieces = [NSMutableData data];
    NSString *visible = kind == SZFriendsItemKindMessage ? SZFriendsSearchVisible(text, pieces) : text;
    if (visible == text) return SZFriendsMatchRanges(text, terms);
    const SZFriendsSearchPiece *piece = pieces.bytes;
    NSUInteger count = pieces.length / sizeof *piece;
    NSMutableArray<NSValue *> *found = [NSMutableArray array];
    for (NSValue *value in SZFriendsMatchRanges(visible, terms)) {
        for (NSUInteger i = 0; i < count; i++) {
            NSRange part = NSIntersectionRange(value.rangeValue, piece[i].shown);
            if (part.length == 0) continue;
            NSRange stored = piece[i].link ? piece[i].stored
                                           : NSMakeRange(piece[i].stored.location + part.location -
                                                             piece[i].shown.location, part.length);
            if (stored.length) [found addObject:[NSValue valueWithRange:stored]];
        }
    }
    return SZFriendsMergedRanges(found);
}

NSArray<SZFriendsSearchHit *> *SZFriendsStoreSearch(SZFriendsStoreDB *db, NSString *query,
                                                    NSArray<NSString *> *_Nullable conversationIDs,
                                                    NSUInteger limit, BOOL useIndex) {
    if (limit == 0 || (conversationIDs && conversationIDs.count == 0)) return @[];
    NSString *folded = SZFriendsSearchFold(query);
    NSMutableOrderedSet<NSString *> *termSet = [NSMutableOrderedSet orderedSet];
    NSCharacterSet *separators = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *term in [folded componentsSeparatedByCharactersInSet:separators]) {
        if (term.length) [termSet addObject:term];
    }
    NSArray<NSString *> *terms = termSet.array;
    if (terms.count == 0) return @[];
    NSString *phrase = [terms componentsJoinedByString:@" "];
    NSMutableArray<NSString *> *long3 = [NSMutableArray array];
    NSMutableString *where = [NSMutableString stringWithString:@"m.folded IS NOT NULL"];
    NSMutableArray *binds = [NSMutableArray arrayWithObject:phrase];
    for (NSString *term in terms) {
        // Trigrams need three characters, so 合同 and 合 are a substring test on the folded copy instead.
        if (useIndex && SZFriendsCodePoints(term) >= 3) {
            [long3 addObject:SZFriendsFTSPhrase(term)];
        } else {
            [where appendString:@" AND instr(m.folded, ?) > 0"];
            [binds addObject:term];
        }
    }
    if (conversationIDs) {
        NSMutableArray *marks = [NSMutableArray array];
        for (NSString *conversationID in conversationIDs) {
            [marks addObject:@"?"];
            [binds addObject:conversationID];
        }
        [where appendFormat:@" AND m.conversation_id IN (%@)", [marks componentsJoinedByString:@","]];
    }
    NSString *from = @"messages m";
    if (long3.count) {
        from = @"search JOIN messages m ON m.seq = search.rowid";
        [where appendString:@" AND search MATCH ?"];
        [binds addObject:[long3 componentsJoinedByString:@" AND "]];
    }
    [binds addObject:@(limit)];
    NSString *sql = [NSString stringWithFormat:
        @"SELECT m.conversation_id, m.item_id, m.kind, m.sent_at, m.direction, m.body, instr(m.folded, ?1) > 0 "
        @"AS exact FROM %@ WHERE %@ ORDER BY exact DESC, m.sent_at DESC, m.item_id DESC LIMIT ?",
        from, where];
    NSMutableArray<SZFriendsSearchHit *> *hits = [NSMutableArray array];
    NSError *error = nil;
    BOOL ok = [db run:sql binds:binds row:^(sqlite3_stmt *s) {
        NSString *text = SZFriendsColumnText(s, 5) ?: @"";
        SZFriendsItemKind kind = (SZFriendsItemKind)SZFriendsColumnInt(s, 2);
        SZFriendsSearchHit *hit =
            [[SZFriendsSearchHit alloc] initWithConversationID:SZFriendsColumnText(s, 0) ?: @""
                                                        itemID:SZFriendsColumnText(s, 1) ?: @""
                                                          kind:kind
                                                        sentAt:SZFriendsColumnDate(s, 3) ?: [NSDate date]
                                                     direction:(SZFriendsDirection)SZFriendsColumnInt(s, 4)
                                                          text:text
                                                   matchRanges:SZFriendsHitRanges(text, kind, terms)];
        [hits addObject:hit];
    } error:&error];
    if (!ok) NSLog(@"Friends store: search failed: %@", error.localizedDescription);
    return hits;
}

NSString *SZFriendsSearchExcerpt(NSString *text, NSArray<NSValue *> *matchRanges, NSUInteger maxLength,
                                 NSArray<NSValue *> *_Nullable *_Nullable excerptRanges) {
    NSString *ellipsis = @"…";
    // One space per line-break unit (CRLF becomes two), so match ranges stay valid in the flattened text.
    NSMutableString *flat = [text mutableCopy];
    NSCharacterSet *breaks = NSCharacterSet.newlineCharacterSet;
    for (NSUInteger i = 0; i < flat.length; i++) {
        if ([breaks characterIsMember:[flat characterAtIndex:i]]) {
            [flat replaceCharactersInRange:NSMakeRange(i, 1) withString:@" "];
        }
    }
    NSRange window = NSMakeRange(0, flat.length);
    if (flat.length > maxLength) {
        NSUInteger budget = maxLength > 2 ? maxLength - 2 : 0; // room for an ellipsis at each cut
        NSRange first = matchRanges.count ? matchRanges.firstObject.rangeValue : NSMakeRange(0, 0);
        if (NSMaxRange(first) > flat.length) first = NSMakeRange(0, 0);
        NSUInteger start = first.location > budget / 3 ? first.location - budget / 3 : 0;
        if (start + budget > flat.length) start = flat.length - budget;
        window = NSMakeRange(start, budget);
        // Never cut a composed character (an emoji, a base letter and its accents) in half.
        if (window.location > 0) {
            NSRange head = [flat rangeOfComposedCharacterSequenceAtIndex:window.location];
            if (head.location < window.location) {
                NSUInteger shift = NSMaxRange(head) - window.location;
                window = NSMakeRange(NSMaxRange(head), window.length > shift ? window.length - shift : 0);
            }
        }
        if (NSMaxRange(window) < flat.length && window.length > 0) {
            NSRange tail = [flat rangeOfComposedCharacterSequenceAtIndex:NSMaxRange(window)];
            if (tail.location < NSMaxRange(window)) window.length = tail.location - window.location;
        }
    }
    BOOL cutStart = window.location > 0, cutEnd = NSMaxRange(window) < flat.length;
    NSMutableString *excerpt = [NSMutableString string];
    if (cutStart) [excerpt appendString:ellipsis];
    [excerpt appendString:[flat substringWithRange:window]];
    if (cutEnd) [excerpt appendString:ellipsis];
    if (excerptRanges) {
        NSMutableArray<NSValue *> *shifted = [NSMutableArray array];
        NSUInteger offset = cutStart ? ellipsis.length : 0;
        for (NSValue *value in matchRanges) {
            NSRange visible = NSIntersectionRange(value.rangeValue, window);
            if (visible.length == 0) continue;
            [shifted addObject:[NSValue valueWithRange:NSMakeRange(visible.location - window.location + offset,
                                                                   visible.length)]];
        }
        *excerptRanges = shifted;
    }
    return excerpt;
}

NS_ASSUME_NONNULL_END
