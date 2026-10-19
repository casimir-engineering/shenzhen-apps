#import "SPDFUpdaterDownloadBounds.h"

// The bounds the updater enforces on a download live here, apart from the
// updater itself, because every one of them is a pure decision over untrusted
// release-JSON input and is worth testing directly.

const long long kSPDFMaxDownloadBytes = 64LL * 1024 * 1024;

// asset.size is untrusted, so clamp it into [0, kSPDFMaxDownloadBytes] before
// any arithmetic. A size above the hard max could never be downloaded anyway,
// so clamping never rejects a viable update.
static long long spdf_clamp_asset_size(long long assetSize) {
    if (assetSize <= 0) return 0;
    return MIN(assetSize, kSPDFMaxDownloadBytes);
}

long long spdf_download_ceiling(long long expectedAssetSize) {
    long long declared = spdf_clamp_asset_size(expectedAssetSize);
    if (declared <= 0) return kSPDFMaxDownloadBytes;  // no declared size: hard max
    // One byte of slack so a download of exactly the declared size passes and
    // the first byte beyond it trips. The clamp above keeps the +1 in range.
    return MIN(declared + 1, kSPDFMaxDownloadBytes);
}

BOOL spdf_download_must_cancel(long long totalBytesWritten, long long totalBytesExpectedToWrite,
                               long long expectedAssetSize) {
    // The written-bytes ceiling is the HARD bound and is always evaluated, even
    // for chunked/CDN responses where totalBytesExpectedToWrite is -1 (in which
    // case the declared-length early reject simply does not fire).
    if (totalBytesWritten > spdf_download_ceiling(expectedAssetSize)) return YES;
    return totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > kSPDFMaxDownloadBytes;
}

BOOL spdf_has_free_space_for_asset(long long freeBytes, long long assetSize) {
    long long declared = spdf_clamp_asset_size(assetSize);
    // An absent size or an unreadable volume must never block an update.
    if (declared <= 0 || freeBytes <= 0) return YES;
    return freeBytes >= declared * 3;
}
