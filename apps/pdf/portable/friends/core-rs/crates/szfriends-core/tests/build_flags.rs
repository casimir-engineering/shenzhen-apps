//! The bundled SQLite's flags (`phone.toml`, which apps pass for phone builds, and `.cargo/config.toml`, which the
//! helper and these suites build with): the two say the same, and a store built with them has FTS5 and none of what
//! they leave out. Apple systems use the system's SQLite.
#![cfg(not(target_os = "ios"))]

fn flags_in(file: &str) -> Option<String> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(file);
    let text = std::fs::read_to_string(path).ok()?;
    let start = text.find("LIBSQLITE3_FLAGS = \"\"\"")?;
    let rest = &text[start..];
    let end = rest[3..].find("\"\"\"")? + 6;
    Some(rest[..end].to_owned())
}

#[test]
fn phones_and_desktops_build_the_same_sqlite() {
    // On an Android device only the binaries and fixtures were copied over; the Mac's run checks the files.
    let (phone, desktop) = (flags_in("phone.toml"), flags_in(".cargo/config.toml"));
    if cfg!(target_os = "android") && phone.is_none() && desktop.is_none() {
        return;
    }
    assert!(phone.is_some(), "phone.toml names LIBSQLITE3_FLAGS");
    assert_eq!(phone, desktop);
}

#[test]
fn the_store_s_sqlite_has_what_the_flags_say() {
    let Some(flags) = option_env!("LIBSQLITE3_FLAGS") else {
        eprintln!("built without LIBSQLITE3_FLAGS (cargo ran outside the workspace without its config)");
        return;
    };
    assert!(flags.contains("SQLITE_OMIT_JSON"));
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    let mut statement = conn.prepare("PRAGMA compile_options").unwrap();
    let options: Vec<String> = statement.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect();
    assert!(options.iter().any(|o| o == "ENABLE_FTS5"), "{options:?}");
    assert!(options.iter().any(|o| o == "OMIT_JSON"), "{options:?}");
    assert!(!options.iter().any(|o| o.starts_with("ENABLE_FTS3") || o == "ENABLE_RTREE"), "{options:?}");
    conn.execute_batch("CREATE VIRTUAL TABLE t USING fts5(body, tokenize = 'trigram')").unwrap();
}
