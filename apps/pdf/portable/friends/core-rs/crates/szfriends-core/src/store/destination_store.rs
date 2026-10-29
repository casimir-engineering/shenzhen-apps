//! The received folder a person chose or the platform's default, and the files received so far (destination.rs).

use super::*;

impl Store {
    /// Where received files go when the person chose nothing; set by the helper for its platform (a store opens
    /// with [`ReceivedDefaults::contained`]).
    pub fn set_received_defaults(&mut self, defaults: ReceivedDefaults) {
        self.received_defaults = defaults;
    }

    pub fn received_defaults(&self) -> &ReceivedDefaults {
        &self.received_defaults
    }

    /// The folder the person chose on this computer, if any (never on a phone).
    pub fn chosen_received_folder(&self) -> Option<PathBuf> {
        if self.received_defaults.phone.is_some() {
            return None;
        }
        let text = fs::read_to_string(self.state_dir().join(RECEIVED_FOLDER_FILE)).ok()?;
        Some(PathBuf::from(text.trim_end_matches(['\n', '\r']))).filter(|p| p.is_absolute())
    }

    /// The folder received files go to now: the chosen one, else the default; `None` where there is no folder to
    /// show (a phone's MediaStore).
    pub fn received_folder(&self) -> Option<PathBuf> {
        self.chosen_received_folder().or_else(|| {
            if self.received_defaults.external.is_some() {
                None
            } else {
                self.received_defaults.folder.clone()
            }
        })
    }

    pub(crate) fn places(&self) -> Places {
        Places {
            chosen: self.chosen_received_folder(),
            defaults: self.received_defaults.clone(),
            own: self.state_dir().join("received"),
        }
    }

    /// `set_received_folder`: checks `path` and remembers its real path; the default Downloads clears the choice.
    pub fn set_received_folder(&mut self, path: &str) -> std::result::Result<(), FolderRefusal> {
        let given = Path::new(path);
        if path.is_empty() || !given.is_absolute() {
            return Err(FolderRefusal::NotAbsolute);
        }
        let real = resolved(given)?;
        if fs::read_dir(&real).is_err() && real.is_dir() {
            return Err(FolderRefusal::Missing);
        }
        if self.received_defaults.phone.is_some() || !real.is_dir() {
            return Err(FolderRefusal::NotAllowed);
        }
        let file = self.state_dir().join(RECEIVED_FOLDER_FILE);
        // Downloads clears the choice (a test's Downloads may sit inside its home).
        let default = self.received_defaults.folder.as_deref().and_then(|d| fs::canonicalize(d).ok());
        if default.as_deref() == Some(real.as_path()) {
            if let Err(e) = fs::remove_file(&file) {
                if e.kind() != io::ErrorKind::NotFound {
                    return Err(FolderRefusal::NotAllowed);
                }
            }
            // A new folder: what happened to the last file in the old one no longer applies.
            record_fallback(self.state_dir(), None);
            return Ok(());
        }
        let state = fs::canonicalize(self.state_dir()).unwrap_or_else(|_| self.state_dir().to_path_buf());
        if real.starts_with(&state) || real.starts_with(self.state_dir()) || !writable(&real) {
            return Err(FolderRefusal::NotAllowed);
        }
        // Written beside it and renamed over it, so a crash leaves the old choice or the new one, never half.
        let temporary = self.state_dir().join(format!(".{RECEIVED_FOLDER_FILE}.{}", new_identifier()));
        let written = (|| -> io::Result<()> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            let mut out = options.open(&temporary)?;
            io::Write::write_all(&mut out, real.to_string_lossy().as_bytes())?;
            out.sync_all()?;
            fs::rename(&temporary, &file)?;
            sync_directory(self.state_dir());
            Ok(())
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(FolderRefusal::NotAllowed);
        }
        record_fallback(self.state_dir(), None);
        Ok(())
    }

    /// The `received` view's rows: files published since the store records when (schema v10), newest first, at most
    /// 100, whose file still exists.
    pub fn received_files(&self) -> Vec<ReceivedFile> {
        let sql = "SELECT transfer_id, received_path, file_name, received_at, received_via FROM transfers \
                   WHERE received_at IS NOT NULL AND received_path IS NOT NULL \
                   ORDER BY received_at DESC, transfer_id DESC";
        let Ok(mut statement) = self.conn.prepare(sql) else { return Vec::new() };
        let Ok(rows) = statement.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, f64>(3)?,
                r.get::<_, i64>(4)?,
            ))
        }) else {
            return Vec::new();
        };
        let mut files = Vec::new();
        for (transfer_id, path, name, at, via) in rows.flatten() {
            if files.len() == RECEIVED_VIEW_MAX {
                break;
            }
            let local = Path::new(&path);
            // A content URI (Android 10) is not a path to check; the transfer's name stands for its own.
            let file_name = if local.is_absolute() {
                if !fs::metadata(local).is_ok_and(|m| m.is_file()) {
                    continue;
                }
                local.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            } else {
                name
            };
            let source = ReceivedSource::from_via(via);
            files.push(ReceivedFile { transfer_id, path, file_name, received_at: at.floor() as i64, source });
        }
        files
    }
}
