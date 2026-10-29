//! ADR 0018 § 2's measurement: the tree's leaf function, BLAKE3 against BLAKE2b-256, per core, on 1 MiB blocks; and a
//! whole file hashed on every core with its digest in the same pass. Prints one JSON line per measurement.
//!
//!     cargo run --release --example tree_hash_bench [MiB]       (tools/tree-hash-bench.sh runs it on a phone)

use std::time::Instant;

use blake2::digest::{Update, VariableOutput};
use szfriends_core::transfer::{tree, Geometry};

fn rate(bytes: u64, seconds: f64) -> f64 {
    bytes as f64 / seconds / 1e9
}

fn main() {
    let mib: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1024);
    let block: Vec<u8> = (0..1usize << 20).map(|i| (i % 251) as u8).collect();
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;
    let mut best = (0f64, 0f64);
    for _ in 0..3 {
        let start = Instant::now();
        let mut sink = 0u8;
        for i in 0..mib {
            sink ^= tree::leaf(i as u32, &block)[0];
        }
        let blake3 = rate(mib << 20, start.elapsed().as_secs_f64());
        let start = Instant::now();
        for _ in 0..mib {
            let mut hasher = blake2::Blake2bVar::new(32).expect("32");
            hasher.update(&block);
            let mut out = [0u8; 32];
            hasher.finalize_variable(&mut out).expect("32");
            sink ^= out[0];
        }
        let blake2b = rate(mib << 20, start.elapsed().as_secs_f64());
        std::hint::black_box(sink);
        best = (best.0.max(blake3), best.1.max(blake2b));
    }
    println!(
        "{{\"bench\":\"leaf_per_core\",\"os\":\"{os}\",\"arch\":\"{arch}\",\"mib\":{mib},\"blake3_gbps\":{:.3},\
         \"blake2b_gbps\":{:.3},\"ratio\":{:.2}}}",
        best.0,
        best.1,
        best.0 / best.1
    );
    let path = std::env::temp_dir().join(format!("szf-tree-bench-{}", std::process::id()));
    let file_bytes: Vec<u8> = block.iter().copied().cycle().take((mib as usize) << 20).collect();
    std::fs::write(&path, &file_bytes).expect("scratch file");
    drop(file_bytes);
    let file = std::fs::File::open(&path).expect("scratch file");
    let geometry = Geometry::for_size(mib << 20).expect("geometry");
    let start = Instant::now();
    let hashed = tree::hash_file(&file, &geometry, true).expect("hash");
    let seconds = start.elapsed().as_secs_f64();
    let _ = std::fs::remove_file(&path);
    let cores = std::thread::available_parallelism().map_or(1, usize::from);
    println!(
        "{{\"bench\":\"file_tree_and_digest\",\"os\":\"{os}\",\"arch\":\"{arch}\",\"cores\":{cores},\"mib\":{mib},\
         \"seconds\":{seconds:.3},\"gbps\":{:.3},\"blocks\":{}}}",
        rate(mib << 20, seconds),
        hashed.leaves.len()
    );
}
