// Mention text tests (PROTOCOL.md § Mentions, ADR 0007): the exact form a sending helper writes, what a receiving
// helper keeps, and what it turns into plain text, the malformed and the hostile cases included.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsMentions.h"

// Stands in for the helper's word list: the words the fixtures use.
static BOOL (^const KnownID)(NSString *) = ^BOOL(NSString *friendsID) {
  NSSet *words = [NSSet setWithArray:@[ @"jasmine", @"street", @"bonfire", @"otter", @"cedar", @"lantern" ]];
  for (NSString *word in [friendsID componentsSeparatedByString:@"-"])
      if (![words containsObject:word]) return NO;
  return YES;
};

static NSString *Mei(void) {
    return SZFriendsMentionLink(@"Mei Lin", @"jasmine-street", SZPKey(SZPKeyMei));
}

// The wire form is fixed: other helpers parse exactly this, so a change here is a protocol change.
static void TestWrittenForm(void) {
    NSString *expected = [NSString stringWithFormat:@"[@Mei Lin](szfriends:mention?id=jasmine-street&key=%@)",
                                                    SZPKeyMei];
    SZPExpect([Mei() isEqualToString:expected], @"the link a helper writes: %@", Mei());
    // Punctuation that would start Markdown is escaped, and read back to the same name.
    NSString *odd = SZFriendsMentionLink(@"O'Brien *Ops* [HK]", @"bonfire-otter", SZPKey(SZPKeyLeo));
    SZPExpect([odd hasPrefix:@"[@O'Brien \\*Ops\\* \\[HK\\]](szfriends:mention?id=bonfire-otter&key="],
              @"escaped name: %@", odd);
    NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks([NSString stringWithFormat:@"Ask %@ today", odd]);
    SZPExpect(links.count == 1 && links[0].isMention && [links[0].name isEqualToString:@"O'Brien *Ops* [HK]"] &&
                  [links[0].identityKey isEqualToData:SZPKey(SZPKeyLeo)] && links[0].range.location == 4,
              @"read back: %@", links.firstObject.name);
    // Nothing can be written that a reader would refuse.
    SZPExpect(SZFriendsMentionLink(@"", @"jasmine-street", SZPKey(SZPKeyMei)) == nil, @"empty name");
    SZPExpect(SZFriendsMentionLink(@"Mei", @"jasmine", SZPKey(SZPKeyMei)) == nil, @"one word");
    SZPExpect(SZFriendsMentionLink(@"Mei", @"jasmine-street", [NSData dataWithBytes:"short" length:5]) == nil,
              @"short key");
    SZPExpect(SZFriendsMentionLink(@"Mei\nLin", @"jasmine-street", SZPKey(SZPKeyMei)) == nil, @"two lines");
}

// The name a mention carries: the friend's name, else their ID as Friends shows it, never over 64 characters.
static void TestMentionName(void) {
    SZPExpect([SZFriendsMentionName(@"  Mei Lin ", @"jasmine-street") isEqualToString:@"Mei Lin"], @"trimmed name");
    SZPExpect([SZFriendsMentionName(nil, @"jasmine-street") isEqualToString:@"jasmine‑street"], @"ID");
    NSString *longName = [@"" stringByPaddingToLength:70 withString:@"Ab" startingAtIndex:0];
    NSString *cut = SZFriendsMentionName(longName, nil);
    SZPExpect(cut.length == 64 && SZFriendsMentionLink(cut, @"jasmine-street", SZPKey(SZPKeyMei)) != nil,
              @"cut to 64: %lu", (unsigned long)cut.length);
    // Characters, not UTF-16 units: 64 emoji are 128 units and still fit.
    NSString *emoji = [@"" stringByPaddingToLength:140 withString:@"😀" startingAtIndex:0];
    SZPExpect([SZFriendsMentionName(emoji, nil) length] == 128, @"64 emoji: %lu",
              (unsigned long)[SZFriendsMentionName(emoji, nil) length]);
}

static void ExpectChecked(NSString *text, NSString *expected, NSString *label) {
    NSString *checked = SZFriendsMentionsChecked(text, KnownID);
    SZPExpect([checked isEqualToString:expected], @"%@:\n  got      %@\n  expected %@", label, checked, expected);
}

// An arriving message keeps well-formed mentions and turns everything else that links to szfriends: into the plain
// text it showed, so nothing unchecked ever reaches a view as a link.
static void TestArrivingChecks(void) {
    NSString *key = SZPKeyLeo;
    ExpectChecked([NSString stringWithFormat:@"Hi %@!", Mei()], [NSString stringWithFormat:@"Hi %@!", Mei()],
                  @"a good mention stays");
    ExpectChecked(@"Plain, with szfriends: in words.", @"Plain, with szfriends: in words.", @"no link, no change");
    NSDictionary<NSString *, NSString *> *malformed = @{
        [NSString stringWithFormat:@"[@Leo](szfriends:mention?id=bonfire-otter&key=%@x)", key] : @"key too long",
        [NSString stringWithFormat:@"[@Leo](szfriends:mention?id=bonfire-otter&key=%@)",
                                   [key substringToIndex:42]] : @"key too short",
        @"[@Leo](szfriends:mention?id=bonfire-otter&key=tN1JdICMMlIsgspydMWcnrWDAec9jXbspfRfygj7Q6p)" :
            @"key not in its canonical spelling",
        [NSString stringWithFormat:@"[@Leo](szfriends:mention?id=bonfire-dragon&key=%@)", key] :
            @"word not in the list",
        [NSString stringWithFormat:@"[@Leo](szfriends:mention?id=Bonfire-Otter&key=%@)", key] : @"ID in capitals",
        [NSString stringWithFormat:@"[@Leo](szfriends:mention?key=%@&id=bonfire-otter)", key] : @"fields reordered",
        [NSString stringWithFormat:@"[@Leo](SZFRIENDS:mention?id=bonfire-otter&key=%@)", key] : @"scheme in capitals",
        [NSString stringWithFormat:@"[Leo](szfriends:mention?id=bonfire-otter&key=%@)", key] : @"no @",
        [NSString stringWithFormat:@"[@ Leo](szfriends:mention?id=bonfire-otter&key=%@)", key] : @"space first",
        [NSString stringWithFormat:@"[@Leo_](szfriends:mention?id=bonfire-otter&key=%@)", key] : @"unescaped _",
    };
    for (NSString *text in malformed) {
        NSString *checked = SZFriendsMentionsChecked(text, KnownID);
        // The words it showed, and nothing of where it pointed.
        BOOL plain = [checked rangeOfString:@"szfriends" options:NSCaseInsensitiveSearch].location == NSNotFound;
        SZPExpect(plain && [checked containsString:@"Leo"], @"%@ becomes plain text: %@", malformed[text], checked);
    }
    ExpectChecked([NSString stringWithFormat:@"[@Leo_](szfriends:mention?id=bonfire-otter&key=%@)", key], @"@Leo\\_",
                  @"a refused name keeps its words, escaped to show as written");
    // A long name is refused whole, not cut: the sender's helper cuts names before writing.
    NSString *seventy = [@"" stringByPaddingToLength:70 withString:@"x" startingAtIndex:0];
    ExpectChecked([NSString stringWithFormat:@"[@%@](szfriends:mention?id=bonfire-otter&key=%@)", seventy, key],
                  [@"@" stringByAppendingString:seventy], @"a 70-character name");
    // Other Friends links, whatever their form, show what they said and link nowhere.
    ExpectChecked(@"Tap [here](szfriends:add?id=bonfire-otter&key=x) now", @"Tap here now", @"another Friends link");
    ExpectChecked(@"See <szfriends:add?id=bonfire-otter>.", @"See szfriends:add?id\\=bonfire-otter.", @"an autolink");
    ExpectChecked(@"[x][1]\n[1]: szfriends:add?id=bonfire-otter\n",
                  @"[x][1]\n\\[1\\]: szfriends:add?id\\=bonfire-otter\n", @"a reference definition");
    ExpectChecked(@"[@Leo](<szfriends:mention?id=bonfire-otter>)", @"@Leo", @"an angle-bracketed destination");
    // A link around another is refused whole, showing its words as written, so no link comes back together.
    NSString *nested =
        [NSString stringWithFormat:@"[[a](szfriends:x)](szfriends:mention?id=bonfire-otter&key=%@)", key];
    NSString *checked = nil;
    ExpectChecked(nested, @"\\[a\\](szfriends:x)", @"nested links");
    // A good mention inside another Friends link is not kept: the outer link would come back when it shows as text.
    NSString *wrapped = [NSString stringWithFormat:@"[%@](szfriends:x)", Mei()];
    checked = SZFriendsMentionsChecked(wrapped, KnownID);
    SZPExpect(SZFriendsTextLinks(checked).count == 0, @"a mention wrapped in a link: %@", checked);
    // Links elsewhere in the message are not Friends' business.
    ExpectChecked(@"[docs](https://example.com) and **bold**", @"[docs](https://example.com) and **bold**",
                  @"web links stay");
}

// More than the 2048 characters around a destination that its tag is looked for in at once.
static NSString *Long(void) {
    return [@"" stringByPaddingToLength:5000 withString:@"word " startingAtIndex:0];
}

// Security review, wave 6a: the host's engine (md4c, GitHub dialect with wikilinks and inline HTML) reads each of
// these as a link to szfriends:mention?ref=0, the very URL the presentation gives a reader's first mention, yet the
// search for the literal "szfriends:" missed them. Each is found and arrives as plain text.
static void TestOtherSpellingsOfTheScheme(void) {
    NSDictionary<NSString *, NSString *> *spellings = @{
        @"[@Mei](szfriends\\:mention?ref=0)" : @"a backslash before the colon",
        @"[@Mei](szfriends&#58;mention?ref=0)" : @"the colon as a decimal reference",
        @"[@Mei](szfriends&#0058;mention?ref=0)" : @"the colon with leading zeros",
        @"[@Mei](szfriends&#x3A;mention?ref=0)" : @"the colon as a hexadecimal reference",
        @"[@Mei](szfriends&#X3a;mention?ref=0)" : @"the colon as a hexadecimal reference, other case",
        @"[@Mei](szfriends&colon;mention?ref=0)" : @"the colon as a named reference",
        @"[@Mei](&#115;zfriends:mention?ref=0)" : @"a letter of the scheme as a reference",
        @"[@Mei](SZ&#70;RIENDS&#58;mention?ref=0)" : @"capitals and references together",
        @"[[szfriends:mention?ref=0|@Mei]]" : @"a wikilink with words",
        @"[[ szfriends\\:mention?ref=0|@Mei]]" : @"a wikilink with an escaped colon",
        @"[[szfriends&#58;mention?ref=0]]" : @"a wikilink showing its target",
        @"<a href=\"szfriends:mention?ref=0\">@Mei</a>" : @"an HTML anchor",
        @"<a href='&#115;zfriends&colon;mention?ref=0'>@Mei</a>" : @"an HTML anchor with references",
        // Security review, wave 6b: a quoted attribute value holding ">" or "<" hid the anchor around it.
        @"<a title=\">\" href=\"szfriends:mention?ref=0\">@Mei</a>" : @"an anchor with \">\" quoted before its href",
        @"<a title='>' href=\"szfriends:mention?ref=0\">@Mei</a>" : @"an anchor with '>' quoted before its href",
        @"<a data-x=\"<\" href=\"szfriends:mention?ref=0\">@Mei</a>" : @"an anchor with \"<\" quoted before its href",
        @"<a href=\"szfriends:mention?ref=0\" data-x=\"<\">@Mei</a>" : @"an anchor with \"<\" quoted after its href",
        @"<a data-x=\"<b\" href=\"szfriends:mention?ref=0\">@Mei</a>" : @"an anchor with a tag quoted in it",
        @"[@Mei][1]\n\n[1]: szfriends&#58;mention?ref=0\n" : @"a reference definition",
        // Security review, wave 6c: HTML blocks of CommonMark types 1-5 run past blank lines and pass a backslash
        // before "<" through, and HTML5 takes a quote inside an attribute name; each hid the anchor.
        @"<pre>\n<a title=\"\n\n\" href=\"szfriends:mention?ref=0\">@Mei</a>\n</pre>" : @"a blank line in a value",
        @"<pre>\n<a title=\"\"\n\nhref=\"szfriends:mention?ref=0\">@Mei</a>\n</pre>" : @"a blank line before href",
        @"<div>\n\\<a href=\"szfriends:mention?ref=0\">@Mei</a>\n</div>" : @"a backslash before the tag in a block",
        @"<a x\" href=\"szfriends:mention?ref=0\">@Mei</a>" : @"a double quote in an attribute name",
        @"<a x' href=\"szfriends:mention?ref=0\">@Mei</a>" : @"a single quote in an attribute name",
        // Wave 6e: HTML decodes a numeric reference without its semicolon or with many zeros, and the URL parser
        // drops ASCII tabs and line breaks, raw or as references, so each of these is szfriends: too.
        @"<a href=\"szfriends&#58mention?ref=0\">@Mei</a>" : @"the colon as a reference without a semicolon",
        @"<a href=\"szfriends&#x3amention?ref=0\">@Mei</a>" : @"a hexadecimal reference without a semicolon",
        @"<a href=\"&#115zfriends:mention?ref=0\">@Mei</a>" : @"a letter as a reference without a semicolon",
        @"<a href=\"szfriends&#000000058;mention?ref=0\">@Mei</a>" : @"the colon with nine digits",
        @"<a href=\"sz\tfriends:mention?ref=0\">@Mei</a>" : @"a tab inside the scheme",
        @"<a href=\"szfriends\n:mention?ref=0\">@Mei</a>" : @"a line break before the colon",
        @"<a href=\"sz&#9;friends:mention?ref=0\">@Mei</a>" : @"a tab inside the scheme as a reference",
        @"<a href=\"szfr&#10iends&#13;:mention?ref=0\">@Mei</a>" : @"line breaks inside the scheme as references",
        @"<a href=\"s\r\nz&#9friends&#58mention?ref=0\">@Mei</a>" : @"all of them together",
        // HTML5 also names a tab and a line feed, which the URL parser then drops (verify, wave 6e).
        @"<a href=\"sz&Tab;friends:mention?ref=0\">@Mei</a>" : @"a tab inside the scheme as a named reference",
        @"<a href=\"szfriends&NewLine;:mention?ref=0\">@Mei</a>" : @"a line feed before the colon by name",
        @"[@Mei](sz&Tab;friends:mention?ref=0)" : @"a named tab in a Markdown destination",
        @"[@Mei](szfriends&NewLine;&colon;mention?ref=0)" : @"a named line feed in a Markdown destination",
        // Wave 6e: an attribute longer than the reach around the destination hid the tag's "<" or its ">".
        [NSString stringWithFormat:@"<a title=\"%@\" href=\"szfriends:mention?ref=0\">@Mei</a>", Long()] :
            @"a long attribute before href",
        [NSString stringWithFormat:@"<a href=\"szfriends:mention?ref=0\" title=\"%@\">@Mei</a>", Long()] :
            @"a long attribute after href",
        [NSString stringWithFormat:@"<a title=\"%@\" href=\"szfriends:mention?ref=0\" x=\"%@\">@Mei</a>", Long(),
                                   Long()] : @"long attributes on both sides",
    };
    for (NSString *text in spellings) {
        NSArray<SZFriendsTextLink *> *found = SZFriendsTextLinks(text);
        SZPExpect(found.count == 1 && !found[0].isMention, @"%@ is found as a Friends link: %lu", spellings[text],
                  (unsigned long)found.count);
        NSString *checked = SZFriendsMentionsChecked(text, KnownID);
        SZPExpect(SZFriendsTextLinks(checked).count == 0 &&
                      (![text containsString:@"@Mei"] || [checked containsString:@"@Mei"]),
                  @"%@ arrives as its words, with no link left: %@", spellings[text], checked);
        SZPExpect([SZFriendsMentionsNeutralized(text) isEqualToString:checked], @"%@ typed: %@", spellings[text],
                  SZFriendsMentionsNeutralized(text));
    }
    ExpectChecked(@"[@Mei](szfriends\\:mention?ref=0) and [[szfriends:x|@Leo]]", @"@Mei and @Leo",
                  @"the words they showed stay");
    // What a renderer does not read as the scheme stays as written: a reference whose "&" is escaped, ordinary
    // references, the scheme's name in prose, and names HTML does not read (another case, no semicolon).
    for (NSString *text in @[ @"[x](szfriends\\&#58;y)", @"Tom &amp; Jerry &#38; co", @"szfriends&#58; in words",
                              @"sz\tfriends: in a table", @"a <b> c = d\nszfriends: <i>",
                              @"[x](sz&tab;friends:y) [x](sz&Tabfriends:y) [x](szfriends&NewLine:y)" ])
        ExpectChecked(text, text, @"not a Friends link");
    // A tag that closes within the reach is the tag, however long its text before: the words after it stay as written.
    NSString *closed = [NSString stringWithFormat:@"<b title=\"%@\">x</b> szfriends: is the scheme", Long()];
    ExpectChecked(closed, closed, @"a long tag closed before the scheme's name");
    // A good mention beside them keeps its link.
    NSString *both = [NSString stringWithFormat:@"%@ [[szfriends:x|y]]", Mei()];
    ExpectChecked(both, [NSString stringWithFormat:@"%@ y", Mei()], @"a mention beside a wikilink");
    // References cost one pass over the text, however many there are.
    NSMutableString *hostile = [NSMutableString string];
    while (hostile.length < 32000) [hostile appendString:@"[[&#115;zfriends&#58;|"];
    NSDate *start = [NSDate date];
    NSString *checked = SZFriendsMentionsChecked(hostile, KnownID);
    SZPExpect(-start.timeIntervalSinceNow < 2.0 && checked.length > 0, @"32 KB of references took %.2f s",
              -start.timeIntervalSinceNow);
}

// At most 20 mentions: the 21st and after are plain text, the first 20 keep their links.
static void TestTwentyMentions(void) {
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < 22; i++) [text appendFormat:@"%@ ", Mei()];
    NSString *checked = SZFriendsMentionsChecked(text, KnownID);
    NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks(checked);
    SZPExpect(links.count == 20, @"20 kept, got %lu", (unsigned long)links.count);
    SZPExpect([checked hasSuffix:@"@Mei Lin @Mei Lin "], @"the rest as plain text: %@",
              [checked substringFromIndex:checked.length - 40]);
}

// What a person typed is never a mention, however well-formed: only the helper writes mentions, from `mentions`.
static void TestTypedLinksNeutralized(void) {
    NSString *typed = [NSString stringWithFormat:@"Look: %@ and [x](szfriends:add?id=a)", Mei()];
    NSString *neutral = SZFriendsMentionsNeutralized(typed);
    SZPExpect([neutral isEqualToString:@"Look: @Mei Lin and x"], @"neutralized: %@", neutral);
    SZPExpect([SZFriendsMentionsNeutralized(@"no links") isEqualToString:@"no links"], @"unchanged");
}

// A hostile message of brackets, tags, quotes and scheme names costs bounded work per occurrence, not a pass per
// bracket or per "<".
static void TestHostileTextStaysQuick(void) {
    for (NSString *unit in @[ @"[[[[(szfriends:", @"<a \"<b '<i szfriends:", @"<a x=\" szfriends: ", @"&#9sz\t&#58" ]) {
        NSMutableString *text = [NSMutableString string];
        while (text.length < 32000) [text appendString:unit];
        NSDate *start = [NSDate date];
        NSString *checked = SZFriendsMentionsChecked(text, KnownID);
        NSTimeInterval took = -start.timeIntervalSinceNow;
        SZPExpect(took < 2.0 && checked.length > 0, @"32 KB of %@ took %.2f s", unit, took);
    }
}

void SZPRunMentionTextTests(void) {
    TestWrittenForm();
    TestMentionName();
    TestArrivingChecks();
    TestOtherSpellingsOfTheScheme();
    TestTwentyMentions();
    TestTypedLinksNeutralized();
    TestHostileTextStaysQuick();
}
