//! A download by blocks as it arrives (blocks.rs): what is still missing for WANT, leaves and PARTs gathered and
//! checked, the durability batches, and what HAVE reports.

use super::*;

impl Store {
    /// Blocks still missing, for WANT.
    pub fn block_missing(&self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get(transfer_id).map(|d| d.assembly.missing_ranges()).unwrap_or_default()
    }

    /// For a peer without Pieces: every block not complete, partly received ones included (they go again whole).
    pub fn block_missing_whole(&self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get(transfer_id).map(|d| d.assembly.complete().missing_ranges()).unwrap_or_default()
    }

    /// The pieces still missing from blocks partly received (WANT's Pieces, ADR 0018 § 3).
    pub fn block_missing_pieces(&self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get(transfer_id).map(|d| d.assembly.missing_pieces()).unwrap_or_default()
    }

    /// Pieces arrived since the last call in blocks not yet complete (HAVE's Pieces).
    pub fn take_piece_have(&mut self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get_mut(transfer_id).map(|d| d.assembly.take_arrived_pieces()).unwrap_or_default()
    }

    /// Leaves from a HASHES frame; once all are here and check, the map gains them. `Ok(true)` when they completed.
    pub fn block_hashes(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        index: u32,
        hashes: &[u8],
    ) -> Result<bool> {
        self.open_blocks(transfer_id, conversation_id)?;
        let map_path = self.block_map_path(transfer_id);
        let verified = load(&self.conn, transfer_id)?.map_or(0, |r| r.verified_bytes);
        let download = self.receiving.blocks.get_mut(transfer_id).expect("opened");
        let done = download.assembly.accept_hashes(index, hashes).map_err(|_| StoreError::Invalid("bad leaves"))?;
        if done && download.map.is_none() {
            let geometry = *download.assembly.geometry();
            let header = Header { geometry, root: *download.assembly.root(), digest: download.digest };
            // A download begun by CHUNK: the whole blocks of its durable prefix count once they check (§ 1).
            let whole = if verified >= geometry.size { geometry.blocks } else { (verified >> geometry.shift) as u32 };
            if whole > 0 && download.durable.is_empty() {
                let leaves = download.assembly.leaves().expect("checked").to_vec();
                let intact =
                    recheck(&download.file, &geometry, &leaves, &BlockSet::full(whole).widened(geometry.blocks));
                download.assembly = BlockAssembly::resumed(geometry, header.root, leaves, intact.clone())
                    .ok_or(StoreError::Invalid("map does not check"))?;
                // Reported at once, so the sender drops them from what it was asked for before the leaves arrived.
                download.unreported_complete.extend(intact.iter());
                download.unreported_durable.extend(intact.iter());
                download.durable = intact;
            }
            let mut map = BlockMap::new(header);
            map.leaves = download.assembly.leaves().map(<[_]>::to_vec);
            map.durable = download.durable.clone();
            write_sidecar(&map_path, &map.encode())?;
            download.map = Some(open_rw(&map_path, false)?);
            let reused = self.reuse_previous_version(transfer_id);
            if !reused.is_empty() {
                self.flush_blocks(transfer_id)?;
            }
            let download = self.receiving.blocks.get_mut(transfer_id).expect("opened");
            if geometry.size == 0 && download.assembly.is_complete() {
                // An empty file: its one block is complete and nothing needs writing.
                download.durable.insert(0);
                download.unreported_complete.push(0);
                download.unreported_durable.push(0);
            }
        }
        if done {
            // Blocks this computer already holds from the same friend are not wanted from them (§ 9.5).
            self.reuse_blocks(transfer_id, conversation_id)?;
        }
        Ok(done)
    }

    /// One PART: gathered, and when its block completes, checked and written at its offset.
    pub fn block_part(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        offset: u64,
        data: &[u8],
    ) -> Result<BlockPart> {
        self.open_blocks(transfer_id, conversation_id)?;
        let download = self.receiving.blocks.get_mut(transfer_id).expect("opened");
        let outcome = match download.assembly.accept_part(offset, data) {
            Ok(outcome) => outcome,
            Err(AssemblyError::TooManyInFlight) => return Err(StoreError::Invalid("too many blocks in flight")),
            Err(_) => return Err(StoreError::Invalid("part out of place")),
        };
        match outcome {
            PartOutcome::Pending => Ok(BlockPart::Pending),
            PartOutcome::Late => Ok(BlockPart::Late),
            PartOutcome::Corrupt { block } => Ok(BlockPart::Corrupt(block)),
            PartOutcome::Complete { block, data } => {
                let (block_offset, _) = download.assembly.geometry().span(block);
                if let Err(error) = write_all_at(&download.file, &data, block_offset) {
                    download.assembly.unwritten(block);
                    return Err(error.into());
                }
                let geometry = *download.assembly.geometry();
                download.streamed.advance(
                    &download.file,
                    &geometry,
                    download.assembly.complete(),
                    Some((block, &data)),
                );
                download.unsynced.push(block);
                download.unsynced_bytes += data.len() as u64;
                download.first_unsynced.get_or_insert_with(Instant::now);
                download.unreported_complete.push(block);
                let due = download.unsynced_bytes >= BATCH_BYTES || download.assembly.is_complete();
                if due {
                    self.flush_blocks(transfer_id)?;
                }
                Ok(BlockPart::Written(block))
            }
        }
    }

    /// When the oldest written block not yet durable became so overdue that a batch should run now.
    pub fn block_flush_due(&self) -> Option<Instant> {
        self.receiving.blocks.values().filter_map(|d| d.first_unsynced).min().map(|at| at + BATCH_INTERVAL)
    }

    /// A durability batch: the blocks, then the map's bitmap, then both durable at once; then the prefix committed.
    pub fn flush_blocks(&mut self, transfer_id: &str) -> Result<()> {
        let Some(download) = self.receiving.blocks.get_mut(transfer_id) else { return Ok(()) };
        if download.unsynced.is_empty() {
            return Ok(());
        }
        let Some(map) = download.map.as_ref() else { return Ok(()) };
        // Blocks ordered before the bitmap that claims them, without the drive cache flush (`disk::order_writes`);
        // the map's full flush below then makes both durable at once: one F_FULLFSYNC per batch on Apple systems.
        crate::store::disk::order_writes(&download.file)?;
        for &block in &download.unsynced {
            download.durable.insert(block);
        }
        let geometry = *download.assembly.geometry();
        let bitmap_offset = (HEADER_BYTES + 32 * geometry.blocks as usize) as u64;
        write_all_at(map, &download.durable.to_bitmap(), bitmap_offset)?;
        if self.batch.is_some() {
            crate::store::disk::order_writes(map)?; // the batch's commit flushes the drive
        } else {
            crate::store::disk::make_durable(map)?;
        }
        download.unreported_durable.append(&mut download.unsynced);
        download.unsynced_bytes = 0;
        download.first_unsynced = None;
        let prefix = durable_prefix(&geometry, &download.durable);
        self.write(|conn| set_column(conn, transfer_id, "verified_bytes", &(prefix as i64)))
    }

    /// Every download by blocks whose batch is due (or all of them, at a session's end or exit).
    pub fn flush_due_blocks(&mut self, all: bool) -> Result<Vec<String>> {
        let now = Instant::now();
        let due: Vec<String> = self
            .receiving
            .blocks
            .iter()
            .filter(|(_, d)| d.first_unsynced.is_some_and(|at| all || now >= at + BATCH_INTERVAL))
            .map(|(id, _)| id.clone())
            .collect();
        for id in &due {
            self.flush_blocks(id)?;
        }
        Ok(due)
    }

    /// What changed since the last HAVE: blocks written, blocks made durable.
    pub fn take_block_have(&mut self, transfer_id: &str) -> (Ranges, Ranges) {
        let Some(download) = self.receiving.blocks.get_mut(transfer_id) else { return (Vec::new(), Vec::new()) };
        (ranges(&mut download.unreported_complete), ranges(&mut download.unreported_durable))
    }

    /// Every block durable: ready for the publish check.
    pub fn blocks_all_durable(&self, transfer_id: &str) -> bool {
        self.receiving.blocks.get(transfer_id).is_some_and(|d| d.durable.is_full())
    }

    /// The blocks complete so far, as a fraction of the file's bytes (the item's progress).
    pub fn block_progress(&self, transfer_id: &str) -> Option<u64> {
        let download = self.receiving.blocks.get(transfer_id)?;
        let geometry = download.assembly.geometry();
        Some(download.assembly.complete().iter().map(|b| geometry.span(b).1 as u64).sum())
    }

    /// A group ended with these downloads open.
    ///
    /// Since pieces (ADR 0018 § 3), partly received blocks are kept: the next session's WANT names only their missing
    /// pieces. Only a restart loses them (they live in memory).
    pub fn blocks_session_ended(&mut self, _transfers: &[String]) {}
}
