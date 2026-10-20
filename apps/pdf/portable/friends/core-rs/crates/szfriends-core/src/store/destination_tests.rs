//! `destination`'s private steps, driven directly.

use super::*;

fn scratch(label: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("szf-destination-{label}-{}", new_identifier()));
    fs::create_dir_all(&path).unwrap();
    path
}

/// The other-volume path, driven directly (one test volume cannot make EXDEV happen): a hidden `.part` beside
/// the final name, a leftover one replaced, the final name never replaced, the staged file removed last.
#[test]
fn a_copy_to_another_volume_shows_only_when_whole() {
    let base = scratch("across");
    let (staged, folder) = (base.join("staged.part"), base.join("Downloads"));
    fs::create_dir_all(&folder).unwrap();
    fs::write(&staged, b"the whole file").unwrap();
    fs::write(folder.join(".Plan.pdf.part"), b"half").unwrap();
    let claims = std::cell::RefCell::new(Vec::new());
    let mut claim = |p: Option<&str>| -> Result<()> {
        claims.borrow_mut().push(p.map(str::to_owned));
        Ok(())
    };
    let published = copy_across(&folder, &staged, "Plan.pdf", folder.join("Plan.pdf"), &mut claim).unwrap().unwrap();
    assert_eq!(published, folder.join("Plan.pdf"));
    assert_eq!(fs::read(&published).unwrap(), b"the whole file");
    assert!(!folder.join(".Plan.pdf.part").exists() && !staged.exists());
    assert!(claims.borrow().is_empty(), "the name claimed before the copy stood");

    // The name was taken while copying: the next one, claimed first.
    fs::write(&staged, b"another").unwrap();
    let taken = folder.join("Plan.pdf");
    let published = copy_across(&folder, &staged, "Plan.pdf", taken.clone(), &mut claim).unwrap().unwrap();
    assert_eq!(published, folder.join("Plan (2).pdf"));
    assert_eq!(fs::read(&taken).unwrap(), b"the whole file", "never replaced");
    assert_eq!(*claims.borrow(), vec![Some(folder.join("Plan (2).pdf").to_string_lossy().into_owned())]);
    assert_eq!(fs::read_dir(&folder).unwrap().count(), 2, "no part file left");
    let _ = fs::remove_dir_all(base);
}

#[test]
fn an_exclusive_rename_refuses_an_existing_name() {
    let base = scratch("exclusive");
    fs::write(base.join("a"), b"a").unwrap();
    fs::write(base.join("b"), b"b").unwrap();
    let error = rename_no_replace(&base.join("a"), &base.join("b")).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(fs::read(base.join("b")).unwrap(), b"b");
    rename_no_replace(&base.join("a"), &base.join("c")).unwrap();
    assert!(!base.join("a").exists() && fs::read(base.join("c")).unwrap() == b"a");
    assert_eq!(part_path(&base.join("Plan (2).pdf")), base.join(".Plan (2).pdf.part"));
    let _ = fs::remove_dir_all(base);
}
