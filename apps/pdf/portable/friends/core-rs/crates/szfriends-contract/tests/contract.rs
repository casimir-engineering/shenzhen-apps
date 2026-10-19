//! PROTOCOL.md's own fixtures and test vectors through this crate: every snapshot, reply, frame and intent the
//! Objective-C helper and the views are tested with must frame and parse here unchanged.

use std::path::Path;

use serde_json::Value;
use szfriends_contract::framing::{encode, FramingError, LineReader, FRAME_MAX};
use szfriends_contract::ids::{client_frame_id_is_valid, opaque_id_is_valid};
use szfriends_contract::socket::{fnv1a64, socket_path, SUN_PATH_MAX};
use szfriends_vectors::fixtures_dir;

fn json_files(directory: &Path) -> Vec<std::path::PathBuf> {
    let mut files: Vec<_> = std::fs::read_dir(directory)
        .expect("fixture directory")
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no fixtures in {}", directory.display());
    files
}

#[test]
fn every_fixture_round_trips_through_the_framing() {
    let mut count = 0;
    for directory in ["frames", "replies", "snapshots"] {
        for path in json_files(&fixtures_dir().join(directory)) {
            let original: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            assert!(original.get("type").and_then(Value::as_str).is_some(), "{}: no type", path.display());
            let line = encode(&original).expect("encodes");
            assert_eq!(line.iter().filter(|&&b| b == b'\n').count(), 1, "one line feed, at the end");
            let mut reader = LineReader::new();
            // Two bytes at a time, as a socket might deliver them.
            let frames: Vec<Value> = line.chunks(2).flat_map(|c| reader.push(c).expect("frames")).collect();
            assert_eq!(frames, vec![original], "{}", path.display());
            count += 1;
        }
    }
    let intents = std::fs::read_to_string(fixtures_dir().join("intents.jsonl")).expect("intents");
    let frames = LineReader::new().push(intents.as_bytes()).expect("intents frame");
    assert!(frames.len() > 10, "intents.jsonl has its intents");
    for intent in &frames {
        let id = intent["id"].as_str().expect("every client frame has an id");
        assert!(client_frame_id_is_valid(id), "{id}");
    }
    assert!(count > 40);
}

#[test]
fn framing_rules() {
    let mut reader = LineReader::new();
    assert_eq!(reader.push(b"\n \r\n{\"type\":\"ping\",\"id\":\"1\"}\r\n").unwrap().len(), 1, "blank lines, CR");
    assert_eq!(LineReader::new().push(b"[1]\n"), Err(FramingError::BadFrame));
    assert_eq!(LineReader::new().push(b"{\"type\":\n"), Err(FramingError::BadFrame));
    let mut big = LineReader::new();
    assert!(big.push(&vec![b' '; FRAME_MAX]).is_ok());
    assert_eq!(big.push(b" "), Err(FramingError::FrameTooLarge), "stops buffering past the cap");
    let text = serde_json::json!({"type": "x", "text": "a\nb"});
    assert!(!encode(&text).unwrap()[..encode(&text).unwrap().len() - 1].contains(&b'\n'));
    assert!(opaque_id_is_valid("c_1-A") && !opaque_id_is_valid("c 1") && !opaque_id_is_valid(&"a".repeat(65)));
    assert!(!client_frame_id_is_valid("") && !client_frame_id_is_valid(&"1".repeat(33)));
}

#[test]
fn socket_paths_follow_protocol_md() {
    assert_eq!(format!("{:016x}", fnv1a64(b"")), "cbf29ce484222325");
    assert_eq!(format!("{:016x}", fnv1a64(b"a")), "af63dc4c8601ec8c");
    let state = "/Users/raph/Library/Application Support/Shenzhen Friends";
    assert_eq!(format!("{:016x}", fnv1a64(state.as_bytes())), "b481e2f85812919d");
    assert_eq!(socket_path(state, "/tmp", SUN_PATH_MAX), Some((format!("{state}/ipc/helper.sock"), false)));
    let deep = format!("/home/someone/{}", "d".repeat(100));
    let (fallback, used) = socket_path(&deep, "/run/user/1000/", SUN_PATH_MAX).expect("fallback fits");
    assert!(used && fallback.starts_with("/run/user/1000/szfriends-") && fallback.ends_with("/helper.sock"));
}
