//! Snapshots cloned rather than copied, and read at offsets (ADR 0018 § 9.1): the snapshot is private, ours to delete
//! whatever the source's mode, independent of later edits to the source, and refused for anything but a file.

use std::io::Write;

use szfriends_core::store::disk::{clone_snapshot, make_durable, order_writes, OutgoingFile};

fn scratch(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("szf-disk-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

#[test]
fn a_snapshot_is_a_private_independent_copy_read_at_offsets() {
    let directory = scratch("snapshot");
    let source = directory.join("source.bin");
    let bytes: Vec<u8> = (0..300_000u32).map(|i| (i * 7 % 251) as u8).collect();
    std::fs::write(&source, &bytes).unwrap();
    let mut permissions = std::fs::metadata(&source).unwrap().permissions();
    permissions.set_readonly(true);
    std::fs::set_permissions(&source, permissions.clone()).unwrap();
    let snapshot = directory.join("snapshot");
    clone_snapshot(&source, &snapshot).unwrap();
    assert!(clone_snapshot(&source, &snapshot).is_err(), "never over an existing file");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&snapshot).unwrap().permissions().mode() & 0o777, 0o600);
    }
    // Later edits of the source do not reach the snapshot.
    #[allow(clippy::permissions_set_readonly_false)]
    permissions.set_readonly(false);
    std::fs::set_permissions(&source, permissions).unwrap();
    std::fs::OpenOptions::new().write(true).open(&source).unwrap().write_all(&[0xff; 1000]).unwrap();
    let file = OutgoingFile::open(&snapshot, bytes.len() as u64).unwrap();
    let mut buffer = vec![0u8; 61_440];
    for offset in [0u64, 61_440, 238_560] {
        let length = buffer.len().min(bytes.len() - offset as usize);
        file.read_at(offset, &mut buffer[..length]).unwrap();
        assert_eq!(&buffer[..length], &bytes[offset as usize..offset as usize + length]);
    }
    assert!(file.read_at(299_000, &mut buffer).is_err(), "past the end");
    std::fs::remove_file(&snapshot).unwrap();
    assert!(clone_snapshot(&directory, &snapshot).is_err(), "a directory is not a file");
    assert!(!snapshot.exists());
    std::fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_batch_is_ordered_then_made_durable() {
    let directory = scratch("durable");
    let mut file = std::fs::File::create(directory.join("blocks")).unwrap();
    file.write_all(&[1; 4096]).unwrap();
    order_writes(&file).unwrap();
    file.write_all(&[2; 16]).unwrap();
    make_durable(&file).unwrap();
    std::fs::remove_dir_all(&directory).unwrap();
}
