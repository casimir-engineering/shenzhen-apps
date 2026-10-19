//! Loads the golden vectors that `core-rs/tools/objc-vectors` exports from the Objective-C helper into
//! `portable/friends/fixtures/vectors/`, and the view-contract fixtures beside them. Test-only: no product crate
//! depends on it.
//!
//! Inputs too large to keep as hex are written as segments: a list of hex strings and `"bb*N"` runs (N bytes of
//! 0xbb), concatenated in order.

use std::path::PathBuf;

use serde_json::Value;

/// `portable/friends`: `$SZFRIENDS_DIR` when set (a device or simulator run, where the tree is copied next to the test
/// binaries), otherwise found from this crate's manifest so tests run from any working directory.
pub fn friends_dir() -> PathBuf {
    std::env::var_os("SZFRIENDS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.."))
}

/// `portable/friends/fixtures`.
pub fn fixtures_dir() -> PathBuf {
    friends_dir().join("fixtures")
}

/// One exported vector file, `fixtures/vectors/<name>`. Panics with the path when it is missing or not JSON: a
/// vector suite that silently loads nothing would pass while checking nothing.
pub fn load(name: &str) -> Value {
    let path = fixtures_dir().join("vectors").join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// Bytes from a hex string, or from a segments array.
pub fn bytes(value: &Value) -> Vec<u8> {
    match value {
        Value::String(text) => segment(text),
        Value::Array(parts) => parts.iter().flat_map(bytes).collect(),
        other => panic!("not hex or segments: {other}"),
    }
}

fn segment(text: &str) -> Vec<u8> {
    match text.split_once('*') {
        Some((byte, count)) => {
            let byte = u8::from_str_radix(byte, 16).expect("run byte");
            vec![byte; count.parse().expect("run length")]
        }
        None => hex::decode(text).unwrap_or_else(|e| panic!("bad hex {text:?}: {e}")),
    }
}

/// Field `key` of `value` as bytes.
pub fn field(value: &Value, key: &str) -> Vec<u8> {
    bytes(value.get(key).unwrap_or_else(|| panic!("missing {key}")))
}

/// Field `key` as an array, failing when it is missing or empty, so a broken filter cannot pass vacuously.
pub fn cases<'a>(value: &'a Value, key: &str) -> &'a Vec<Value> {
    let list = value.get(key).and_then(Value::as_array).unwrap_or_else(|| panic!("missing array {key}"));
    assert!(!list.is_empty(), "{key} has no cases");
    list
}

/// Field `key` as a string.
pub fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_else(|| panic!("missing string {key}"))
}

/// Field `key` as an unsigned integer.
pub fn number(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or_else(|| panic!("missing number {key}"))
}

/// Field `key` as a flag: the exporter writes booleans as `true`/`false` or as 1/0.
pub fn flag(value: &Value, key: &str) -> bool {
    match value.get(key) {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(n)) => n.as_u64() == Some(1),
        _ => panic!("missing flag {key}"),
    }
}
