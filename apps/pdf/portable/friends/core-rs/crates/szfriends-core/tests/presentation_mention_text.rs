//! Mention text (`SZFriendsPresentationMentionTextTests.m`, PROTOCOL.md § Mentions, ADR 0007): the exact form a
//! sending helper writes, what a receiving helper keeps, and what it turns into plain text, the malformed and the
//! hostile cases included: every spelling of the scheme the security reviews found, case for case.

mod presentation;

use std::time::Instant;

use presentation::world::{key, KEY_LEO, KEY_MEI};
use szfriends_core::presentation::mentions::{
    mention_link, mention_name, mentions_checked, mentions_neutralized, text_links,
};

/// Stands in for the helper's word list: the words the fixtures use.
fn known_id(friends_id: &str) -> bool {
    friends_id.split('-').all(|w| ["jasmine", "street", "bonfire", "otter", "cedar", "lantern"].contains(&w))
}

fn mei() -> String {
    mention_link("Mei Lin", "jasmine-street", &key(KEY_MEI)).unwrap()
}

/// The helper's bound for 32 KB of hostile text, built optimised; an unoptimised test build, run under emulation in the
/// VMs, gets ten times as long. Either catches work that grows with the square of the text, which takes minutes.
fn quick_enough() -> f64 {
    if cfg!(debug_assertions) {
        20.0
    } else {
        2.0
    }
}

fn checked(text: &str) -> String {
    mentions_checked(text, known_id)
}

#[test]
fn the_written_form() {
    // The wire form is fixed: other helpers parse exactly this, so a change here is a protocol change.
    assert_eq!(mei(), format!("[@Mei Lin](szfriends:mention?id=jasmine-street&key={KEY_MEI})"));
    let odd = mention_link("O'Brien *Ops* [HK]", "bonfire-otter", &key(KEY_LEO)).unwrap();
    assert!(odd.starts_with("[@O'Brien \\*Ops\\* \\[HK\\]](szfriends:mention?id=bonfire-otter&key="), "{odd}");
    let links = text_links(&format!("Ask {odd} today"));
    assert_eq!(links.len(), 1);
    assert!(links[0].is_mention && links[0].name.as_deref() == Some("O'Brien *Ops* [HK]"));
    assert_eq!((links[0].identity_key, links[0].range.0), (Some(key(KEY_LEO)), 4));
    // Nothing can be written that a reader would refuse.
    assert!(mention_link("", "jasmine-street", &key(KEY_MEI)).is_none());
    assert!(mention_link("Mei", "jasmine", &key(KEY_MEI)).is_none());
    assert!(mention_link("Mei", "jasmine-street", b"short").is_none());
    assert!(mention_link("Mei\nLin", "jasmine-street", &key(KEY_MEI)).is_none());
}

#[test]
fn the_name_a_mention_carries() {
    assert_eq!(mention_name(Some("  Mei Lin "), Some("jasmine-street")), "Mei Lin");
    assert_eq!(mention_name(None, Some("jasmine-street")), "jasmine\u{2011}street");
    let long: String = "Ab".repeat(35);
    let cut = mention_name(Some(&long), None);
    assert_eq!(cut.encode_utf16().count(), 64);
    assert!(mention_link(&cut, "jasmine-street", &key(KEY_MEI)).is_some());
    // Characters, not UTF-16 units: 64 emoji are 128 units and still fit.
    assert_eq!(mention_name(Some(&"😀".repeat(70)), None).encode_utf16().count(), 128);
}

#[test]
fn arriving_checks() {
    let good = format!("Hi {}!", mei());
    assert_eq!(checked(&good), good, "a good mention stays");
    assert_eq!(checked("Plain, with szfriends: in words."), "Plain, with szfriends: in words.");
    let k = KEY_LEO;
    let malformed = [
        (format!("[@Leo](szfriends:mention?id=bonfire-otter&key={k}x)"), "key too long"),
        (format!("[@Leo](szfriends:mention?id=bonfire-otter&key={})", &k[..42]), "key too short"),
        (
            "[@Leo](szfriends:mention?id=bonfire-otter&key=tN1JdICMMlIsgspydMWcnrWDAec9jXbspfRfygj7Q6p)".into(),
            "key not canonical",
        ),
        (format!("[@Leo](szfriends:mention?id=bonfire-dragon&key={k})"), "word not in the list"),
        (format!("[@Leo](szfriends:mention?id=Bonfire-Otter&key={k})"), "ID in capitals"),
        (format!("[@Leo](szfriends:mention?key={k}&id=bonfire-otter)"), "fields reordered"),
        (format!("[@Leo](SZFRIENDS:mention?id=bonfire-otter&key={k})"), "scheme in capitals"),
        (format!("[Leo](szfriends:mention?id=bonfire-otter&key={k})"), "no @"),
        (format!("[@ Leo](szfriends:mention?id=bonfire-otter&key={k})"), "space first"),
        (format!("[@Leo_](szfriends:mention?id=bonfire-otter&key={k})"), "unescaped _"),
    ];
    for (text, label) in &malformed {
        let result = checked(text);
        assert!(!result.to_lowercase().contains("szfriends") && result.contains("Leo"), "{label}: {result}");
    }
    assert_eq!(checked(&format!("[@Leo_](szfriends:mention?id=bonfire-otter&key={k})")), "@Leo\\_");
    // A long name is refused whole, not cut: the sender's helper cuts names before writing.
    let seventy = "x".repeat(70);
    assert_eq!(checked(&format!("[@{seventy}](szfriends:mention?id=bonfire-otter&key={k})")), format!("@{seventy}"));
    assert_eq!(checked("Tap [here](szfriends:add?id=bonfire-otter&key=x) now"), "Tap here now");
    assert_eq!(checked("See <szfriends:add?id=bonfire-otter>."), "See szfriends:add?id\\=bonfire-otter.");
    assert_eq!(
        checked("[x][1]\n[1]: szfriends:add?id=bonfire-otter\n"),
        "[x][1]\n\\[1\\]: szfriends:add?id\\=bonfire-otter\n"
    );
    assert_eq!(checked("[@Leo](<szfriends:mention?id=bonfire-otter>)"), "@Leo");
    // A link around another is refused whole, so no link comes back together.
    assert_eq!(
        checked(&format!("[[a](szfriends:x)](szfriends:mention?id=bonfire-otter&key={k})")),
        "\\[a\\](szfriends:x)"
    );
    assert!(text_links(&checked(&format!("[{}](szfriends:x)", mei()))).is_empty(), "a mention wrapped in a link");
    let web = "[docs](https://example.com) and **bold**";
    assert_eq!(checked(web), web, "web links stay");
}

/// More than the 2048 characters around a destination that its tag is looked for in at once.
fn long() -> String {
    "word ".repeat(1000)
}

#[test]
fn other_spellings_of_the_scheme() {
    let l = long();
    let spellings = [
        "[@Mei](szfriends\\:mention?ref=0)".to_owned(),
        "[@Mei](szfriends&#58;mention?ref=0)".into(),
        "[@Mei](szfriends&#0058;mention?ref=0)".into(),
        "[@Mei](szfriends&#x3A;mention?ref=0)".into(),
        "[@Mei](szfriends&#X3a;mention?ref=0)".into(),
        "[@Mei](szfriends&colon;mention?ref=0)".into(),
        "[@Mei](&#115;zfriends:mention?ref=0)".into(),
        "[@Mei](SZ&#70;RIENDS&#58;mention?ref=0)".into(),
        "[[szfriends:mention?ref=0|@Mei]]".into(),
        "[[ szfriends\\:mention?ref=0|@Mei]]".into(),
        "[[szfriends&#58;mention?ref=0]]".into(),
        "<a href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "<a href='&#115;zfriends&colon;mention?ref=0'>@Mei</a>".into(),
        "<a title=\">\" href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "<a title='>' href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "<a data-x=\"<\" href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfriends:mention?ref=0\" data-x=\"<\">@Mei</a>".into(),
        "<a data-x=\"<b\" href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "[@Mei][1]\n\n[1]: szfriends&#58;mention?ref=0\n".into(),
        "<pre>\n<a title=\"\n\n\" href=\"szfriends:mention?ref=0\">@Mei</a>\n</pre>".into(),
        "<pre>\n<a title=\"\"\n\nhref=\"szfriends:mention?ref=0\">@Mei</a>\n</pre>".into(),
        "<div>\n\\<a href=\"szfriends:mention?ref=0\">@Mei</a>\n</div>".into(),
        "<a x\" href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "<a x' href=\"szfriends:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfriends&#58mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfriends&#x3amention?ref=0\">@Mei</a>".into(),
        "<a href=\"&#115zfriends:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfriends&#000000058;mention?ref=0\">@Mei</a>".into(),
        "<a href=\"sz\tfriends:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfriends\n:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"sz&#9;friends:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfr&#10iends&#13;:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"s\r\nz&#9friends&#58mention?ref=0\">@Mei</a>".into(),
        "<a href=\"sz&Tab;friends:mention?ref=0\">@Mei</a>".into(),
        "<a href=\"szfriends&NewLine;:mention?ref=0\">@Mei</a>".into(),
        "[@Mei](sz&Tab;friends:mention?ref=0)".into(),
        "[@Mei](szfriends&NewLine;&colon;mention?ref=0)".into(),
        format!("<a title=\"{l}\" href=\"szfriends:mention?ref=0\">@Mei</a>"),
        format!("<a href=\"szfriends:mention?ref=0\" title=\"{l}\">@Mei</a>"),
        format!("<a title=\"{l}\" href=\"szfriends:mention?ref=0\" x=\"{l}\">@Mei</a>"),
    ];
    for text in &spellings {
        let found = text_links(text);
        assert!(found.len() == 1 && !found[0].is_mention, "found as a Friends link: {text:?} ({})", found.len());
        let result = checked(text);
        assert!(
            text_links(&result).is_empty() && (!text.contains("@Mei") || result.contains("@Mei")),
            "{text:?}: {result}"
        );
        assert_eq!(mentions_neutralized(text), result, "typed: {text:?}");
    }
    assert_eq!(checked("[@Mei](szfriends\\:mention?ref=0) and [[szfriends:x|@Leo]]"), "@Mei and @Leo");
    // What a renderer does not read as the scheme stays as written.
    for text in [
        "[x](szfriends\\&#58;y)",
        "Tom &amp; Jerry &#38; co",
        "szfriends&#58; in words",
        "sz\tfriends: in a table",
        "a <b> c = d\nszfriends: <i>",
        "[x](sz&tab;friends:y) [x](sz&Tabfriends:y) [x](szfriends&NewLine:y)",
    ] {
        assert_eq!(checked(text), text, "not a Friends link");
    }
    let closed = format!("<b title=\"{l}\">x</b> szfriends: is the scheme");
    assert_eq!(checked(&closed), closed, "a long tag closed before the scheme's name");
    assert_eq!(checked(&format!("{} [[szfriends:x|y]]", mei())), format!("{} y", mei()));
    // References cost one pass over the text, however many there are.
    let mut hostile = String::new();
    while hostile.len() < 32_000 {
        hostile.push_str("[[&#115;zfriends&#58;|");
    }
    let start = Instant::now();
    assert!(!checked(&hostile).is_empty() && start.elapsed().as_secs_f64() < quick_enough(), "{:?}", start.elapsed());
}

#[test]
fn twenty_mentions() {
    let text: String = (0..22).map(|_| format!("{} ", mei())).collect();
    let result = checked(&text);
    assert_eq!(text_links(&result).len(), 20);
    assert!(result.ends_with("@Mei Lin @Mei Lin "), "{}", &result[result.len() - 40..]);
}

#[test]
fn typed_links_are_neutralized() {
    let typed = format!("Look: {} and [x](szfriends:add?id=a)", mei());
    assert_eq!(mentions_neutralized(&typed), "Look: @Mei Lin and x");
    assert_eq!(mentions_neutralized("no links"), "no links");
}

#[test]
fn hostile_text_stays_quick() {
    for unit in ["[[[[(szfriends:", "<a \"<b '<i szfriends:", "<a x=\" szfriends: ", "&#9sz\t&#58"] {
        let mut text = String::new();
        while text.encode_utf16().count() < 32_000 {
            text.push_str(unit);
        }
        let start = Instant::now();
        let result = checked(&text);
        assert!(
            !result.is_empty() && start.elapsed().as_secs_f64() < quick_enough(),
            "{unit:?} took {:?}",
            start.elapsed()
        );
    }
}
