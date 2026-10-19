//! The animal set on phones: built into the plugin (`build.rs`) and written beside Friends' files the first time a
//! version runs, so the same reader serves it as on desktops (`files::AnimalSet`).

use std::path::{Path, PathBuf};

include!(concat!(env!("OUT_DIR"), "/animals.rs"));

/// The set's directory under `base`, written when missing or different; None when it cannot be written.
pub fn unpack(base: &Path) -> Option<PathBuf> {
    let directory = base.join("FriendsAnimals");
    let manifest = FILES.iter().find(|(name, _)| *name == "manifest.json")?.1;
    if std::fs::read(directory.join("manifest.json")).ok().as_deref() == Some(manifest) {
        return Some(directory);
    }
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(directory.join("svg")).ok()?;
    // The manifest last: a set interrupted half-way is written again at the next start.
    for (name, bytes) in FILES.iter().filter(|(name, _)| *name != "manifest.json") {
        std::fs::write(directory.join(name), bytes).ok()?;
    }
    std::fs::write(directory.join("manifest.json"), manifest).ok()?;
    Some(directory)
}
