//! Files copied between a person's own computers inside the sync exchange (exchange.rs): which file is copied next, its
//! WANTs, PARTs and NONEs, and the same file by blocks when both ends have fast transfers.

use super::*;

impl SyncExchange {
    pub(super) fn start_next_copy(&mut self, engine: &SyncEngine, store: &Store) {
        if self.copy.is_some() || self.stopped || self.pulled {
            return;
        }
        for file in engine.files_wanted(store) {
            if !file.holders.contains(&self.peer_key) || self.unavailable.contains(&file.transfer_id) {
                continue;
            }
            let partial = engine.received_dir.join(".partial");
            if std::fs::create_dir_all(&partial).is_err() {
                continue;
            }
            let path = partial.join(format!("sync-{}", file.transfer_id));
            if self.request_blocks {
                let map = partial.join(format!("sync-{}.map", file.transfer_id));
                let digest: Option<[u8; 32]> = file.digest.clone().try_into().ok();
                let Some(blocks) = digest.and_then(|d| BlockCopy::open(file.size, d, path.clone(), map).ok()) else {
                    continue;
                };
                let Ok(handle) = std::fs::File::open(&path) else { continue };
                let want = CopyMessage::WantBlocks {
                    id: file.transfer_id.clone(),
                    shift: blocks.shift(),
                    ranges: blocks.missing(),
                };
                if let Some(message) = want.encode_sync() {
                    self.outgoing.push(message);
                }
                self.copy = Some(Copy { file, path, handle, received: 0, requested: 0, blocks: Some(blocks) });
                return;
            }
            let Ok(mut handle) =
                std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&path)
            else {
                continue;
            };
            let mut held = handle.seek(SeekFrom::End(0)).unwrap_or(0);
            if held > file.size {
                let _ = handle.set_len(0);
                let _ = handle.seek(SeekFrom::Start(0));
                held = 0;
            }
            self.copy = Some(Copy { file, path, handle, received: held, requested: held, blocks: None });
            self.request_more();
            return;
        }
    }

    pub(super) fn request_more(&mut self) {
        let Some(copy) = self.copy.as_mut() else { return };
        let size = copy.file.size;
        let mut first = copy.requested == copy.received;
        while (copy.requested < size || (size == 0 && first))
            && copy.requested - copy.received < COPY_AHEAD * FILE_PART_MAX as u64
        {
            let mut want = vec![WANT];
            put_id(&mut want, &copy.file.transfer_id);
            want.extend_from_slice(&copy.requested.to_be_bytes());
            want.extend_from_slice(&COPY_PARTS.to_be_bytes());
            self.outgoing.push(want);
            copy.requested = size.min(copy.requested + u64::from(COPY_PARTS) * FILE_PART_MAX as u64);
            if size == 0 {
                break;
            }
            first = false;
        }
    }

    pub(super) fn receive_want(
        &mut self,
        engine: &mut SyncEngine,
        store: &Store,
        message: &[u8],
    ) -> Result<(), SyncError> {
        let mut offset = 1;
        let id = get_id(message, &mut offset).filter(|_| offset + 10 == message.len());
        let id = id.ok_or(SyncError::Malformed("a WANT that does not decode"))?;
        let start = u64::from_be_bytes(message[offset..offset + 8].try_into().expect("8"));
        let parts = u64::from(u16::from_be_bytes([message[offset + 8], message[offset + 9]])).min(COPY_AHEAD);
        let path = engine.local_path_of_file(store, &id);
        let size = path.as_ref().and_then(|_| sync_files::transfer(&store.conn, &id).ok().flatten()).map(|t| t.size);
        let handle = path.and_then(|p| std::fs::File::open(p).ok());
        let (Some(mut handle), Some(size)) = (handle, size.filter(|s| start <= *s)) else {
            let mut none = vec![NONE];
            put_id(&mut none, &id);
            self.outgoing.push(none);
            if size.is_none() {
                // Listed as holding it and it is gone (moved or deleted here): every device hears so now.
                if engine.capture_local_changes(store) > 0 {
                    self.pump(engine, store);
                }
            }
            return Ok(());
        };
        let _ = handle.seek(SeekFrom::Start(start));
        let mut at = start;
        for _ in 0..parts {
            let length = (FILE_PART_MAX as u64).min(size - at) as usize;
            let mut bytes = vec![0u8; length];
            let read = handle.read(&mut bytes).unwrap_or(0);
            bytes.truncate(read);
            let last = at + bytes.len() as u64 >= size;
            let mut part = vec![PART];
            put_id(&mut part, &id);
            part.extend_from_slice(&at.to_be_bytes());
            part.push(u8::from(last));
            part.extend_from_slice(&bytes);
            self.outgoing.push(part);
            at += bytes.len() as u64;
            if last || bytes.is_empty() {
                break;
            }
        }
        let fraction = if size > 0 { at as f64 / size as f64 } else { 1.0 };
        self.serving = (at < size).then_some((id, fraction));
        Ok(())
    }

    pub(super) fn receive_part(
        &mut self,
        engine: &mut SyncEngine,
        store: &Store,
        message: &[u8],
    ) -> Result<(), SyncError> {
        let mut offset = 1;
        let id = get_id(message, &mut offset).filter(|_| offset + 9 <= message.len());
        let id = id.ok_or(SyncError::Malformed("a PART that does not decode"))?;
        let at = u64::from_be_bytes(message[offset..offset + 8].try_into().expect("8"));
        let last = message[offset + 8] != 0;
        let bytes = &message[offset + 9..];
        let Some(copy) = self.copy.as_mut() else { return Ok(()) };
        if copy.file.transfer_id != id || at != copy.received {
            return Ok(());
        }
        let end = copy.received + bytes.len() as u64;
        if end > copy.file.size || (last && end != copy.file.size) {
            self.abandon_copy(true);
            return Ok(());
        }
        if copy.handle.write_all(bytes).is_err() {
            // No room left here: what arrived goes, and so does the Get; the item offers Get, which then says so.
            self.abandon_copy(true);
            let _ = engine.cancel_file_request(store, &id);
            return Ok(());
        }
        copy.received = end;
        if copy.received < copy.file.size {
            self.request_more();
            return Ok(());
        }
        let copy = self.copy.take().expect("present");
        let _ = copy.handle.sync_all();
        drop(copy.handle);
        if matches_digest(&copy.path, copy.file.size, &copy.file.digest) {
            let _ = engine.adopt_copied_file(store, &id, &copy.path);
        } else {
            remove_copy(&copy.path);
            self.unavailable.insert(id);
        }
        self.start_next_copy(engine, store);
        Ok(())
    }

    pub(super) fn receive_none(
        &mut self,
        engine: &mut SyncEngine,
        store: &Store,
        message: &[u8],
    ) -> Result<(), SyncError> {
        let mut offset = 1;
        let id = get_id(message, &mut offset).filter(|_| offset == message.len());
        let id = id.ok_or(SyncError::Malformed("a NONE that does not decode"))?;
        self.unavailable.insert(id.clone());
        if self.copy.as_ref().is_some_and(|c| c.file.transfer_id == id) {
            self.abandon_copy(false);
        }
        self.start_next_copy(engine, store);
        Ok(())
    }

    /// WANT BLOCKS from the other device (serve the file by blocks), or BLOCKS FOLLOW for our copy.
    pub(super) fn receive_blocks_message(
        &mut self,
        engine: &mut SyncEngine,
        store: &Store,
        message: &[u8],
    ) -> Result<(), SyncError> {
        match CopyMessage::decode_sync(message).ok_or(SyncError::Malformed("a block message that does not decode"))? {
            CopyMessage::WantBlocks { id, shift, ranges } => {
                let path = engine.local_path_of_file(store, &id);
                let record = sync_files::transfer(&store.conn, &id).ok().flatten();
                let size =
                    path.as_ref().and_then(|_| sync_files::transfer(&store.conn, &id).ok().flatten()).map(|t| t.size);
                let served = (|| {
                    let (path, size) = (path?, size?);
                    let geometry = crate::transfer::Geometry::new(size, shift)?;
                    let file = std::fs::File::open(&path).ok()?;
                    // The digest in the same read: a copy here that changed (a stale version) is not served, so
                    // every holder a requester pulls from has the same tree.
                    let hashed = crate::transfer::tree::hash_file(&file, &geometry, true).ok()?;
                    if hashed.digest.map(|d| d.to_vec()) != record.as_ref().map(|r| r.digest.clone()) {
                        return None;
                    }
                    let wire = hex::decode(&id).ok()?;
                    let mut serve =
                        crate::transfer::BlockServe::new(&wire, geometry, hashed.leaves, FILE_PART_MAX, 8 << 20);
                    serve.want(&ranges).ok()?;
                    Some((hashed.root, serve, path))
                })();
                match served {
                    Some((root, serve, path)) => {
                        if let Some(follow) = (CopyMessage::BlocksFollow { id: id.clone(), root, shift }).encode_sync()
                        {
                            self.outgoing.push(follow);
                        }
                        // The session serves it from here on, and says how far it is (the helper's `you_copying`).
                        self.serve_blocks.push(ServeBlocks { transfer_id: id, serve, path, root });
                    }
                    None => {
                        let mut none = vec![NONE];
                        put_id(&mut none, &id);
                        self.outgoing.push(none);
                        if size.is_none() && engine.capture_local_changes(store) > 0 {
                            self.pump(engine, store);
                        }
                    }
                }
            }
            CopyMessage::BlocksFollow { id, root, shift } => {
                let followed = self
                    .copy
                    .as_mut()
                    .filter(|c| c.file.transfer_id == id)
                    .and_then(|c| c.blocks.as_mut())
                    .map(|b| b.follow(root, shift));
                if followed == Some(false) {
                    self.abandon_copy(false);
                    self.start_next_copy(engine, store);
                }
            }
        }
        Ok(())
    }

    /// HASHES for the copy by blocks; `false` when this exchange is not copying `id` by blocks.
    pub fn hashes(&mut self, id: &str, index: u32, hashes: &[u8]) -> bool {
        let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == id) else { return false };
        let Some(blocks) = copy.blocks.as_mut() else { return false };
        if blocks.hashes(index, hashes).is_none() {
            self.abandon_copy(false);
            return true;
        }
        self.queue_have(id);
        true
    }

    pub(super) fn queue_have(&mut self, id: &str) {
        let Some(blocks) = self.copy.as_mut().and_then(|c| c.blocks.as_mut()) else { return };
        let have = blocks.take_have();
        if let Ok(wire) = hex::decode(id) {
            self.frames.extend(crate::transfer::frames::have(&wire, &have, &[]));
        }
    }

    /// A PART for the copy by blocks; `false` when this exchange is not copying `id` by blocks.
    pub fn part(&mut self, engine: &mut SyncEngine, store: &Store, id: &str, offset: u64, data: &[u8]) -> bool {
        let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == id) else { return false };
        let Some(blocks) = copy.blocks.as_mut() else { return false };
        match blocks.part(offset, data) {
            CopyPart::Pending | CopyPart::Late => {}
            CopyPart::Written(_) => self.queue_have(id),
            CopyPart::Corrupt(block) => {
                let want =
                    CopyMessage::WantBlocks { id: id.to_owned(), shift: blocks.shift(), ranges: vec![(block, 1)] };
                if let Some(message) = want.encode_sync() {
                    self.outgoing.push(message);
                }
            }
            CopyPart::Refused => {
                self.abandon_copy(false);
                self.start_next_copy(engine, store);
            }
            CopyPart::Complete => {
                self.queue_have(id);
                let copy = self.copy.take().expect("present");
                drop(copy.handle);
                match copy.blocks.expect("by blocks").finish() {
                    Some(path) => {
                        let _ = engine.adopt_copied_file(store, id, &path);
                    }
                    None => {
                        self.unavailable.insert(id.to_owned());
                    }
                }
                self.start_next_copy(engine, store);
            }
        }
        true
    }

    pub(super) fn abandon_copy(&mut self, discard: bool) {
        if let Some(copy) = self.copy.take() {
            if discard {
                remove_copy(&copy.path);
            }
            self.unavailable.insert(copy.file.transfer_id);
        }
    }
}
