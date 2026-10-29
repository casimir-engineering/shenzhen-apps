//! A finished download checked before it is saved (ADR 0018 § 5), and the blocks a transfer can take from files
//! already here: a held copy, a previous version, blocks indexed from earlier exchanges (blocks.rs).

use super::*;

impl Store {
    /// ADR 0018 § 5, in one call: [`Store::begin_block_check`], [`BlockCheck::run`], [`Store::complete_block_check`].
    pub fn finish_block_transfer(&mut self, transfer_id: &str, conversation_id: &str) -> Result<PathBuf> {
        let check = self.begin_block_check(transfer_id, conversation_id)?;
        self.complete_block_check(check.run())
    }

    /// Every block durable: the check before saving, handed out so it can run off the helper's thread (large files
    /// show "Finishing…" meanwhile). The download leaves the open set; its map stays until the check completes, so a
    /// helper that stops meanwhile runs the check again at its next start.
    pub fn begin_block_check(&mut self, transfer_id: &str, conversation_id: &str) -> Result<BlockCheck> {
        let record = receiving(&self.conn, transfer_id, conversation_id)?;
        self.flush_blocks(transfer_id)?;
        if !self.blocks_all_durable(transfer_id) {
            return Err(StoreError::Invalid("file is incomplete"));
        }
        let download = self.receiving.blocks.remove(transfer_id).expect("checked");
        Ok(BlockCheck {
            geometry: *download.assembly.geometry(),
            root: *download.assembly.root(),
            complete: download.assembly.complete().clone(),
            record,
            file: download.file,
            partial: download.partial,
            streamed: download.streamed,
        })
    }

    /// A file this computer holds that has the offered bytes: received from the same friend (or copied here from
    /// another of the person's computers), still where it was saved at its size, and still hashing to the digest.
    /// Never another friend's file: a friend learns at most that the person kept what that friend sent (§ 8).
    pub(super) fn held_copy(&self, record: &TransferRecord) -> Option<PathBuf> {
        let candidates = transfers::rows(
            &self.conn,
            "WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2 AND size = ?3 AND digest = ?4 \
             AND transfer_id != ?5 ORDER BY updated_at DESC LIMIT 4",
            &[
                &record.conversation_id,
                &(TransferState::Received as i64),
                &(record.size as i64),
                &record.digest.to_vec(),
                &record.transfer_id,
            ],
        )
        .ok()?;
        candidates.into_iter().filter_map(|r| r.received_path).find(|path| {
            fs::metadata(path).is_ok_and(|m| m.is_file() && m.len() == record.size)
                && crate::store::file_digest(path, u64::MAX).ok() == Some(record.digest)
        })
    }

    /// After acceptance: when this computer holds the offered file, its bytes go into the staging file and become
    /// the durable count, so the transfer completes without them crossing the route. `true` when it did.
    pub fn fill_from_held_copy(&mut self, transfer_id: &str) -> Result<bool> {
        let record = load(&self.conn, transfer_id)?.ok_or(StoreError::NotFound)?;
        if record.outgoing || record.state != TransferState::Receiving || record.size == 0 {
            return Ok(false);
        }
        let Some(source) = self.held_copy(&record) else { return Ok(false) };
        let partial = partial_path(&self.conn, transfer_id)?.ok_or(StoreError::Invalid("no staging file"))?;
        let mut out = open_rw(&partial, false)?;
        out.set_len(0)?;
        std::io::copy(&mut File::open(&source)?, &mut out)?;
        if self.batch.is_some() {
            crate::store::disk::order_writes(&out)?;
        } else {
            crate::store::disk::make_durable(&out)?;
        }
        if out.metadata()?.len() != record.size {
            out.set_len(0)?;
            return Ok(false);
        }
        self.receiving.forget(transfer_id);
        self.write(|conn| set_column(conn, transfer_id, "verified_bytes", &(record.size as i64)))?;
        Ok(true)
    }

    /// Whether a download's bytes are all here already (filled locally): it finishes by CHUNK's DONE, not by blocks.
    pub fn whole_file_held(&self, transfer_id: &str) -> bool {
        load(&self.conn, transfer_id).ok().flatten().is_some_and(|r| !r.outgoing && r.verified_bytes == r.size)
    }

    /// The blocks a new version can take from the version the same friend sent before (§ 9.5): the newest file of
    /// the same name received from them, still here, hashed at this geometry; a block whose leaf matches at the same
    /// position is copied into the staging file and counts as arrived. Returns the blocks taken.
    pub(super) fn reuse_previous_version(&mut self, transfer_id: &str) -> Vec<u32> {
        let Ok(Some(record)) = load(&self.conn, transfer_id) else { return Vec::new() };
        let previous = transfers::rows(
            &self.conn,
            "WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2 AND file_name = ?3 AND transfer_id != ?4 \
             ORDER BY updated_at DESC LIMIT 1",
            &[&record.conversation_id, &(TransferState::Received as i64), &record.file_name, &record.transfer_id],
        )
        .ok()
        .and_then(|mut rows| rows.pop())
        .and_then(|r| r.received_path);
        let Some(download) = self.receiving.blocks.get_mut(transfer_id) else { return Vec::new() };
        let Some(old) = previous.and_then(|p| File::open(p).ok()) else { return Vec::new() };
        let Some(leaves) = download.assembly.leaves().map(<[_]>::to_vec) else { return Vec::new() };
        let geometry = *download.assembly.geometry();
        let old_size = old.metadata().map_or(0, |m| m.len());
        let mut taken = Vec::new();
        for block in 0..geometry.blocks {
            let (offset, length) = geometry.span(block);
            if download.assembly.complete().contains(block) || offset + length as u64 > old_size || length == 0 {
                continue;
            }
            let mut buffer = vec![0u8; length];
            if read_exact_at(&old, &mut buffer, offset).is_err() || tree::leaf(block, &buffer) != leaves[block as usize]
            {
                continue;
            }
            if write_all_at(&download.file, &buffer, offset).is_ok() && download.assembly.mark_complete(block) {
                download.unsynced.push(block);
                download.unsynced_bytes += length as u64;
                download.first_unsynced.get_or_insert_with(Instant::now);
                download.unreported_complete.push(block);
                download.streamed.advance(
                    &download.file,
                    &geometry,
                    download.assembly.complete(),
                    Some((block, &buffer)),
                );
                taken.push(block);
            }
        }
        taken
    }

    /// Whether a download's check is quick enough to run on the caller's thread (at most 16 MiB).
    pub fn block_check_is_quick(&self, transfer_id: &str) -> bool {
        self.receiving.blocks.get(transfer_id).is_some_and(|d| d.assembly.geometry().size <= 16 << 20)
    }

    /// Saves a file whose check passed, or deletes it and fails the transfer (DigestMismatch). A transfer cancelled
    /// while it was checked keeps nothing.
    pub fn complete_block_check(&mut self, checked: CheckedFile) -> Result<PathBuf> {
        let CheckedFile { record, partial, matches } = checked;
        let map = self.read_map(&record.transfer_id);
        let _ = fs::remove_file(self.block_map_path(&record.transfer_id));
        let still = receiving(&self.conn, &record.transfer_id, &record.conversation_id).is_ok();
        if matches && still {
            let published = self.publish_received(&record, &partial)?;
            // Its leaves, for blocks of a later version from the same friend (§ 9.5).
            if let Some(leaves) =
                map.as_ref().and_then(|m| m.leaves.as_deref()).filter(|_| !published.as_os_str().is_empty())
            {
                let geometry = map.as_ref().expect("read").header.geometry;
                self.index_blocks(&record.conversation_id, &record.transfer_id, &published, &geometry, leaves);
            }
            return Ok(published);
        }
        let _ = fs::remove_file(&partial);
        if !still {
            return Err(StoreError::Stale);
        }
        self.fail_received_transfer(&record.transfer_id)?;
        Err(StoreError::DigestMismatch)
    }

    /// The sender's tree for one of our offers: from `outgoing/<id>.tree` when it matches the row, else computed from
    /// the snapshot (whose digest must still be the offered one) and kept there.
    pub fn sender_tree(&self, record: &TransferRecord) -> Result<SenderTree> {
        let path = self.sender_tree_path(&record.transfer_id);
        if let Some(tree) = fs::read(&path).ok().and_then(|b| SenderTree::decode(&b)) {
            if tree.header.digest == record.digest && tree.header.geometry.size == record.size {
                self.index_sent_blocks(record, &tree);
                return Ok(tree);
            }
        }
        let geometry = Geometry::for_size(record.size).ok_or(StoreError::Invalid("too large for blocks"))?;
        let snapshot = record.staged_path.as_ref().ok_or(StoreError::FileMissing)?;
        let file = File::open(snapshot).map_err(|_| StoreError::FileMissing)?;
        if file.metadata()?.len() != record.size {
            return Err(StoreError::FileMissing);
        }
        let hashed = tree::hash_file(&file, &geometry, true)?;
        if hashed.digest != Some(record.digest) {
            return Err(StoreError::FileMissing);
        }
        let tree =
            SenderTree { header: Header { geometry, root: hashed.root, digest: record.digest }, leaves: hashed.leaves };
        // A cache: a write that fails only costs hashing again.
        write_tree_cache(&path, &tree);
        self.index_sent_blocks(record, &tree);
        Ok(tree)
    }

    /// A file this person sends a friend: its leaves and the file they chose, for blocks of a version that friend may
    /// send back (§ 9.5). Every block found there is checked against the new file's leaf before it counts, so a file
    /// edited since costs only a failed check.
    pub(super) fn index_sent_blocks(&self, record: &TransferRecord, tree: &SenderTree) {
        if let Some(source) = &record.source_path {
            self.index_blocks(
                &record.conversation_id,
                &record.transfer_id,
                source,
                &tree.header.geometry,
                &tree.leaves,
            );
        }
    }

    /// Blocks of a download whose leaves an indexed file of the same friend holds at the same position: read there,
    /// and taken exactly as if they had arrived (checked against their leaves, written, reported in the next HAVE), so
    /// the sender skips them. Returns how many.
    pub(super) fn reuse_blocks(&mut self, transfer_id: &str, conversation_id: &str) -> Result<u32> {
        let Some(download) = self.receiving.blocks.get(transfer_id) else { return Ok(0) };
        let Some(leaves) = download.assembly.leaves().map(<[_]>::to_vec) else { return Ok(0) };
        let geometry = *download.assembly.geometry();
        let complete = download.assembly.complete().clone();
        let found = self.reusable_blocks(conversation_id, &geometry, &leaves, |b| !complete.contains(b));
        let mut reused = 0;
        let mut open: Option<(PathBuf, File)> = None;
        for (block, path) in found {
            if open.as_ref().is_none_or(|(p, _)| *p != path) {
                open = File::open(&path).ok().map(|f| (path.clone(), f));
            }
            let Some((_, file)) = &open else { continue };
            let (offset, length) = geometry.span(block);
            let mut data = vec![0u8; length];
            if read_exact_at(file, &mut data, offset).is_err() {
                continue;
            }
            if let BlockPart::Written(_) = self.block_part(transfer_id, conversation_id, offset, &data)? {
                reused += 1;
            }
        }
        Ok(reused)
    }

    /// They took our offer by blocks (OFFER_REPLY with Blocks, or a WANT on a later session): Sending, without hashing
    /// the whole snapshot first, since every block is checked against its leaf as it is read (§ 4). Returns the record
    /// and whether this was the first acceptance (then every block is wanted, before any WANT).
    pub fn peer_took_blocks(&mut self, transfer_id: &str, conversation_id: &str) -> Result<(TransferRecord, bool)> {
        self.write(|conn| {
            let record = owned(conn, transfer_id, conversation_id, true)?;
            let first = match record.state {
                TransferState::Sending => false,
                state if TransferEvent::Accepted.next_state(true, state) == TransferState::Sending => true,
                _ => return Err(StoreError::Stale),
            };
            if record.staged_path.as_ref().is_none_or(|p| fs::metadata(p).map(|m| m.len()).ok() != Some(record.size)) {
                apply_event(
                    conn,
                    transfer_id,
                    TransferEvent::Failed,
                    Some(crate::store::outbox::FAILURE_SOURCE_MISSING),
                )?;
                return Err(StoreError::FileMissing);
            }
            if first {
                apply_event(conn, transfer_id, TransferEvent::Accepted, None)?;
            }
            Ok((load(conn, transfer_id)?.ok_or(StoreError::NotFound)?, first))
        })
    }

    /// Our snapshot no longer matches its tree: the transfer fails as a missing source does.
    pub fn snapshot_changed(&mut self, transfer_id: &str) -> Result<()> {
        self.write(|conn| {
            apply_event(conn, transfer_id, TransferEvent::Failed, Some(crate::store::outbox::FAILURE_SOURCE_MISSING))
                .map(|_| ())
        })
    }

    /// Reads block `index` of an outgoing transfer's snapshot whole, for the sender to check against its leaf.
    pub fn read_outgoing_block(&self, record: &TransferRecord, geometry: &Geometry, index: u32) -> Result<Vec<u8>> {
        let path = record.staged_path.as_ref().ok_or(StoreError::FileMissing)?;
        let file = File::open(path).map_err(|_| StoreError::FileMissing)?;
        let (offset, length) = geometry.span(index);
        let mut buffer = vec![0u8; length];
        read_exact_at(&file, &mut buffer, offset).map_err(|_| StoreError::FileMissing)?;
        Ok(buffer)
    }

    /// Sidecars whose transfer still needs them; the recovery sweep keeps these and deletes the rest.
    pub(in crate::store) fn live_sidecars(&self) -> Result<Vec<PathBuf>> {
        let open = transfers::rows(
            &self.conn,
            "WHERE state IN (?1, ?2, ?3, ?4, ?5)",
            &[
                &(TransferState::Queued as i64),
                &(TransferState::Offered as i64),
                &(TransferState::WaitingForYou as i64),
                &(TransferState::Sending as i64),
                &(TransferState::Receiving as i64),
            ],
        )?;
        Ok(open
            .iter()
            .map(
                |r| {
                    if r.outgoing {
                        self.sender_tree_path(&r.transfer_id)
                    } else {
                        self.block_map_path(&r.transfer_id)
                    }
                },
            )
            .collect())
    }
}
