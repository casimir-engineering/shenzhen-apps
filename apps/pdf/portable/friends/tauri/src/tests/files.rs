//! The helper-file rules, case for case with Shenzhen 3D's Electron tests (`electron/friends-bridge.test.cjs`).

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::*;

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let name = format!("szf-tauri-{label}-{}", random.iter().map(|b| format!("{b:02x}")).collect::<String>());
        let path = std::env::temp_dir().join(name);
        fs::create_dir_all(&path).expect("a temporary directory");
        Self(fs::canonicalize(path).expect("canonical"))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = vec![0u8; 64];
    bytes[..8].copy_from_slice(&[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    bytes[12..16].copy_from_slice(b"IHDR");
    bytes[16..20].copy_from_slice(&width.to_be_bytes());
    bytes[20..24].copy_from_slice(&height.to_be_bytes());
    bytes
}

fn text(path: &Path) -> String {
    path.to_str().expect("UTF-8").to_owned()
}

#[test]
fn previews_and_photos_are_read_only_from_the_state_folders_as_small_files_of_the_stated_size() {
    let state = TempDir::new("files");
    let dir = &state.0;
    fs::create_dir_all(dir.join("thumbnails").join("sub")).unwrap();
    fs::create_dir_all(dir.join("pictures")).unwrap();
    let thumb = dir.join("thumbnails").join("a.png");
    fs::write(&thumb, png(136, 192)).unwrap();
    let read = |kind: &str, file: &str, width: Option<u32>, height: Option<u32>| {
        read_helper_image(Some(dir), kind, file, (width, height)).map(|(size, _)| size)
    };
    assert_eq!(read("thumbnail", &text(&thumb), Some(136), Some(192)).map(|s| s.width), Some(136));
    assert_eq!(read("thumbnail", &text(&thumb), Some(100), Some(192)), None, "a different size than stated");
    assert_eq!(read("picture", &text(&thumb), None, None), None, "a preview is not a photo");
    fs::write(dir.join("thumbnails").join("sub").join("b.png"), png(10, 10)).unwrap();
    let sub = text(&dir.join("thumbnails").join("sub").join("b.png"));
    assert_eq!(read("thumbnail", &sub, Some(10), Some(10)), None, "subfolder");
    let sep = std::path::MAIN_SEPARATOR;
    let dotdot = format!("{}{sep}thumbnails{sep}..{sep}thumbnails{sep}a.png", text(dir));
    assert_eq!(read("thumbnail", &dotdot, Some(136), Some(192)), None, "dot-dot");
    let doubled = format!("{}{sep}thumbnails{sep}{sep}a.png", text(dir));
    assert_eq!(read("thumbnail", &doubled, Some(136), Some(192)), None, "doubled separator");
    fs::write(dir.join("pictures").join("big.png"), [png(256, 256), vec![0; 300 * 1024]].concat()).unwrap();
    assert_eq!(read("picture", &text(&dir.join("pictures").join("big.png")), None, None), None, "over 256 KiB");
    fs::write(dir.join("pictures").join("huge.png"), png(5000, 5000)).unwrap();
    assert_eq!(read("picture", &text(&dir.join("pictures").join("huge.png")), None, None), None, "over 1024 px");
    let jpeg = [0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8, 0, 200, 1, 0, 3, 0, 0, 0, 0];
    assert_eq!(jpeg_size(&jpeg), Some(ImageSize { kind: "image/jpeg", width: 256, height: 200 }));
    fs::write(dir.join("pictures").join("me.jpg"), jpeg).unwrap();
    assert_eq!(read("picture", &text(&dir.join("pictures").join("me.jpg")), None, None).map(|s| s.height), Some(200));
    assert_eq!(classify_path(&text(dir)), "folder");
    assert_eq!(classify_path(&text(&thumb)), "file");
    assert_eq!(classify_path(&text(&dir.join("missing"))), "missing");
    #[cfg(unix)]
    {
        let link = dir.join("thumbnails").join("link.png");
        std::os::unix::fs::symlink(&thumb, &link).unwrap();
        assert_eq!(read("thumbnail", &text(&link), Some(136), Some(192)), None, "a link is not followed");
        assert_eq!(classify_path(&text(&link)), "other");
        let fifo = dir.join("thumbnails").join("fifo.png");
        let status = std::process::Command::new("mkfifo").arg(&fifo).status().expect("mkfifo");
        assert!(status.success());
        assert_eq!(read("thumbnail", &text(&fifo), Some(1), Some(1)), None, "a FIFO never blocks");
        assert_eq!(read("thumbnail", "/etc/hosts", Some(1), Some(1)), None);
    }
}

#[test]
fn the_animal_set_comes_from_its_manifest_and_names_outside_svg_are_refused() {
    let directory = TempDir::new("animals");
    fs::create_dir_all(directory.0.join("svg")).unwrap();
    fs::write(directory.0.join("svg").join("00-goose.svg"), "<svg/>").unwrap();
    let manifest = json!({"set": 1, "animals": [
        {"index": 0, "name": "Goose", "color": "#5a4a7a", "svg": "svg/00-goose.svg"},
        {"index": 1, "name": "Bad", "svg": "../manifest.json"},
    ]});
    fs::write(directory.0.join("manifest.json"), manifest.to_string()).unwrap();
    let set = AnimalSet::new(directory.0.clone());
    assert_eq!(set.animal(&json!(1), &json!(0)), Some(json!({"svg": "<svg/>", "color": "#5a4a7a", "name": "Goose"})));
    assert_eq!(set.animal(&json!(1), &json!(1)), None);
    assert_eq!(set.animal(&json!(2), &json!(0)), None, "another set");
    assert_eq!(set.list().expect("a list")["animals"].as_array().map(Vec::len), Some(2));
}

#[test]
fn staged_projects_are_private_plain_names_of_the_apps_own_kinds() {
    let outgoing = TempDir::new("outgoing");
    let kinds = vec!["sz3d".to_owned()];
    let file = stage(&outgoing.0, "Gearbox.sz3d", b"PK", &kinds).expect("staged");
    assert_eq!(fs::read(&file).unwrap(), b"PK");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    }
    for name in [".hidden.sz3d", "a/b.sz3d", "..", "x.stl", ".sz3d", &format!("{}.sz3d", "x".repeat(200))] {
        assert!(stage(&outgoing.0, name, b"PK", &kinds).is_err(), "{name}");
    }
    // An app that stages dropped files takes any plain name.
    assert!(stage(&outgoing.0, "triangle.stl", b"solid", &[]).is_ok());
    assert!(stage(&outgoing.0, ".hidden", b"solid", &[]).is_err());
}

#[test]
fn a_snapshot_offers_only_its_open_file_actions() {
    let data = json!({"items": [{"actions": [{"action": "open_file", "path": "/r/a.stl"},
                                             {"action": "show_file", "path": "/r/b.stl"}]}]});
    let mut found = Vec::new();
    openable_paths(&data, &mut found, 0);
    assert_eq!(found, vec!["/r/a.stl".to_owned()]);
}

#[test]
fn picked_and_shared_files_are_the_regular_files_the_platform_copied_into_their_folder() {
    let outgoing = TempDir::new("picked");
    let folder = picked_folder(&outgoing.0).expect("a folder");
    assert_eq!(folder.parent(), Some(outgoing.0.as_path()));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&folder).unwrap().permissions().mode() & 0o777, 0o700);
    }
    let write = |n: &str, name: &str, bytes: &[u8]| {
        let directory = folder.join(n);
        fs::create_dir_all(&directory).unwrap();
        let file = directory.join(name);
        fs::write(&file, bytes).unwrap();
        file.to_str().unwrap().to_owned()
    };
    let survey = write("0", "Site survey 2026.pdf", b"%PDF");
    let again = write("1", "Site survey 2026.pdf", b"%PDF 2");
    let notes = write("2", "wiring notes.txt", b"red to 12 V");
    // What the platform must not hand over: a folder, a link, a file elsewhere, one not in a numbered subfolder.
    fs::create_dir_all(folder.join("3").join("Parts")).unwrap();
    let folder_entry = folder.join("3").join("Parts").to_str().unwrap().to_owned();
    let elsewhere = TempDir::new("elsewhere");
    let outside = elsewhere.0.join("secret.txt");
    fs::write(&outside, b"no").unwrap();
    #[cfg(unix)]
    let link = {
        fs::create_dir_all(folder.join("4")).unwrap();
        let link = folder.join("4").join("link.txt");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        link.to_str().unwrap().to_owned()
    };
    #[cfg(not(unix))]
    let link = outside.to_str().unwrap().to_owned();
    let flat = folder.join("flat.txt");
    fs::write(&flat, b"x").unwrap();
    let copied = json!([
        {"path": survey}, {"path": again}, {"path": notes}, {"path": folder_entry}, {"path": link},
        {"path": outside.to_str().unwrap()}, {"path": flat.to_str().unwrap()},
        {"path": format!("{}/0/../2/wiring notes.txt", folder.display())}, {"path": 7}, {"name": "x"},
    ]);
    assert_eq!(
        picked_files(&folder, &copied),
        vec![
            json!({"path": survey, "display_name": "Site survey 2026.pdf"}),
            json!({"path": again, "display_name": "Site survey 2026.pdf"}),
            json!({"path": notes, "display_name": "wiring notes.txt"}),
        ]
    );
    assert!(picked_files(&folder, &json!(null)).is_empty(), "cancelled");
    let many: Vec<_> = (0..150).map(|_| json!({"path": notes})).collect();
    assert_eq!(picked_files(&folder, &json!(many)).len(), 100, "as many as send_files takes");
}
