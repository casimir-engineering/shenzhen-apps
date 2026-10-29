//! Stable sorts with one sort compiled for all of them (ADR 0015 § 12: phone builds count every kilobyte).
//!
//! `slice::sort_by` and `sort_by_key` compile a whole stable sort, about 2.3 KB on arm64 at opt-level "z", for every
//! element type and comparison they are called with. These sort the elements' positions instead, through one sort of
//! `usize` with the comparison behind a `dyn`, then move the elements into that order: the same result as the slice
//! methods (stable: equal elements keep their order) for a few hundred bytes per call. For the lists the core sorts
//! by a field (rows, candidates, records); plain `sort` and `sort_unstable` of numbers keep the slice methods, whose
//! one copy per element type every caller shares.

use std::cmp::Ordering;

/// `v.sort_by(compare)`.
pub fn sort_by<T>(v: &mut [T], mut compare: impl FnMut(&T, &T) -> Ordering) {
    if v.len() < 2 {
        return;
    }
    let mut order: Vec<usize> = (0..v.len()).collect();
    sort_positions(&mut order, &mut |a, b| compare(&v[a], &v[b]));
    permute(v, &mut order);
}

/// `v.sort_by_key(key)`.
pub fn sort_by_key<T, K: Ord>(v: &mut [T], mut key: impl FnMut(&T) -> K) {
    sort_by(v, |a, b| key(a).cmp(&key(b)));
}

#[inline(never)]
fn sort_positions(order: &mut [usize], compare: &mut dyn FnMut(usize, usize) -> Ordering) {
    order.sort_by(|&a, &b| compare(a, b));
}

/// Moves `v[order[i]]` to `v[i]` for every `i`, following each cycle of the permutation once.
fn permute<T>(v: &mut [T], order: &mut [usize]) {
    for start in 0..v.len() {
        let mut at = start;
        loop {
            let from = std::mem::replace(&mut order[at], usize::MAX);
            if from == usize::MAX || from == start {
                break;
            }
            v.swap(at, from);
            at = from;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_order_as_the_slice_methods() {
        // A fixed pseudo-random sequence with many equal keys, so stability shows.
        let mut seed = 0x2545_f491_u32;
        let values: Vec<(u8, u32)> = (0..500)
            .map(|i| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                ((seed % 7) as u8, i)
            })
            .collect();
        for len in [0, 1, 2, 3, 17, 500] {
            let mut ours = values[..len].to_vec();
            let mut theirs = ours.clone();
            sort_by(&mut ours, |a, b| a.0.cmp(&b.0).reverse());
            theirs.sort_by(|a, b| a.0.cmp(&b.0).reverse());
            assert_eq!(ours, theirs, "sort_by, {len}");
            let mut ours = values[..len].to_vec();
            let mut theirs = ours.clone();
            sort_by_key(&mut ours, |v| v.0);
            theirs.sort_by_key(|v| v.0);
            assert_eq!(ours, theirs, "sort_by_key, {len}");
        }
    }

    #[test]
    fn moves_elements_that_own_memory() {
        let mut words: Vec<String> = ["pear", "fig", "apple", "kiwi", "date"].map(String::from).to_vec();
        sort_by_key(&mut words, |w| w.len());
        assert_eq!(words, ["fig", "pear", "kiwi", "date", "apple"]);
    }
}
