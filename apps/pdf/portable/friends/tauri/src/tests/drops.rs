//! Dropped files' paths: only regular files with plain paths are kept, every file the page names must match one the
//! system reported by name and size, a report is used once, and a ticket's report answers only its own question.

use std::fs;
use std::path::PathBuf;

use super::*;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let name = format!("szf-tauri-drops-{}", random.iter().map(|b| format!("{b:02x}")).collect::<String>());
        let path = std::env::temp_dir().join(name);
        fs::create_dir_all(&path).expect("a temporary directory");
        Self(fs::canonicalize(path).expect("canonical"))
    }

    fn file(&self, name: &str, text: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, text).unwrap();
        path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn wanted(list: &[(&str, u64)]) -> Vec<(String, u64)> {
    list.iter().map(|(n, s)| ((*n).to_owned(), *s)).collect()
}

#[test]
fn only_regular_files_are_kept() {
    let dir = TempDir::new();
    let gearbox = dir.file("Gearbox.stl", "solid");
    fs::create_dir(dir.0.join("Parts")).unwrap();
    assert_eq!(
        dropped(&gearbox),
        Some(Dropped { name: "Gearbox.stl".into(), size: 5, path: gearbox.to_str().unwrap().into() })
    );
    assert_eq!(dropped(&dir.0.join("Parts")), None, "a folder");
    assert_eq!(dropped(&dir.0.join("missing.stl")), None, "gone");
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&gearbox, dir.0.join("link.stl")).unwrap();
        assert_eq!(dropped(&dir.0.join("link.stl")), None, "a link");
    }
}

#[test]
fn every_file_must_match_by_name_and_size() {
    let dir = TempDir::new();
    let a = dir.file("a.stl", "12345");
    let b = dir.file("b.txt", "hi");
    let drops = Drops::default();
    drops.record("main", None, &[a.clone(), b.clone()]);
    assert_eq!(drops.take("main", &wanted(&[("a.stl", 4)]), None), None, "another size");
    assert_eq!(drops.take("main", &wanted(&[("a.stl", 5), ("c.stl", 1)]), None), None, "one unknown");
    assert_eq!(drops.take("other", &wanted(&[("a.stl", 5)]), None), None, "another window");
    assert_eq!(drops.take("main", &wanted(&[]), None), None, "nothing asked");
    let paths = drops.take("main", &wanted(&[("b.txt", 2), ("a.stl", 5)]), None).unwrap();
    assert_eq!(paths, vec![b.to_str().unwrap().to_owned(), a.to_str().unwrap().to_owned()], "in the page's order");
    assert_eq!(drops.take("main", &wanted(&[("a.stl", 5)]), None), None, "used once");
}

#[test]
fn two_files_with_one_name_need_two_reported() {
    let dir = TempDir::new();
    let first = dir.file("same.txt", "x");
    let files = vec![Dropped { name: "same.txt".into(), size: 1, path: first.to_str().unwrap().into() }];
    assert_eq!(matching(&files, &wanted(&[("same.txt", 1), ("same.txt", 1)])), None);
}

#[test]
fn a_ticket_answers_only_its_own_question() {
    let dir = TempDir::new();
    let a = dir.file("a.stl", "12345");
    let drops = Drops::default();
    drops.record("main", Some("t1".into()), std::slice::from_ref(&a));
    assert!(drops.has_ticket("main", "t1"));
    assert_eq!(drops.take("main", &wanted(&[("a.stl", 5)]), Some("t2")), None);
    assert_eq!(drops.take("main", &wanted(&[("a.stl", 5)]), None), None);
    assert!(drops.take("main", &wanted(&[("a.stl", 5)]), Some("t1")).is_some());
    // A report without a ticket (Linux, a Mac, the app's own) answers any question.
    drops.record("main", None, std::slice::from_ref(&a));
    assert!(drops.take("main", &wanted(&[("a.stl", 5)]), Some("t3")).is_some());
}

#[test]
fn only_the_latest_reports_are_kept() {
    let dir = TempDir::new();
    let drops = Drops::default();
    for index in 0..6 {
        let file = dir.file(&format!("{index}.txt"), "x");
        drops.record("main", None, &[file]);
    }
    assert_eq!(drops.take("main", &wanted(&[("0.txt", 1)]), None), None, "forgotten");
    assert!(drops.take("main", &wanted(&[("5.txt", 1)]), None).is_some());
}

#[test]
fn a_drag_seen_over_a_window_is_asked_about_once() {
    let drops = Drops::default();
    assert_eq!(drops.disarm("main"), None, "no drag was seen");
    drops.arm("main", 41);
    drops.arm("main", 42);
    assert_eq!(drops.disarm("other"), None, "only the window it was over");
    assert_eq!(drops.disarm("main"), Some(42), "the latest drag");
    assert_eq!(drops.disarm("main"), None, "used up");
}

#[test]
fn a_drag_is_read_for_the_one_window_it_was_dropped_on() {
    let dir = TempDir::new();
    let part = dir.file("part.stl", "solid");
    let drops = Drops::default();
    // One drag passed over both windows and was dropped on "second".
    drops.arm("main", 7);
    drops.arm("second", 7);
    assert_eq!(drops.disarm("second"), Some(7));
    drops.record_drag("second", 7, std::slice::from_ref(&part));
    assert_eq!(drops.disarm("main"), None, "the window it only passed over");
    assert!(drops.take("main", &wanted(&[("part.stl", 5)]), None).is_none());
    assert!(drops.take("second", &wanted(&[("part.stl", 5)]), None).is_some());
    // A window a later drag is over keeps that one.
    drops.arm("main", 8);
    drops.record_drag("second", 7, std::slice::from_ref(&part));
    assert_eq!(drops.disarm("main"), Some(8));
}
