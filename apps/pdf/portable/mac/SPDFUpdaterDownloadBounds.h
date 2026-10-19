#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Hard ceiling on any update download, matching the DMG bound asserted by
/// portable/release/verify-mac-artifact.sh.
extern const long long kSPDFMaxDownloadBytes;

/// Pure zip-bomb bound for an in-flight update download, in bytes written.
/// asset.size arrives from the release JSON and is therefore untrusted: it is
/// clamped into [0, kSPDFMaxDownloadBytes] before the one-byte slack that lets
/// a download of exactly the declared size through, so a hostile or corrupt
/// size can never overflow the arithmetic. An absent size (<= 0) falls back to
/// the hard max. Always positive — a negative ceiling would cancel every
/// download and silently disable auto-update.
long long spdf_download_ceiling(long long expectedAssetSize);

/// YES when an in-flight download must be cancelled: it has written past the
/// ceiling (always evaluated, including for chunked responses whose declared
/// length is -1), or it declared a length above the hard max up front.
BOOL spdf_download_must_cancel(long long totalBytesWritten, long long totalBytesExpectedToWrite,
                               long long expectedAssetSize);

/// YES when the staging volume has room for the update (~3x the DMG: download,
/// expand, swap). An absent asset size or an unreadable volume must never block
/// an update, so both answer YES; the clamped size keeps the multiply in range.
BOOL spdf_has_free_space_for_asset(long long freeBytes, long long assetSize);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
