//! Where a phone's received files go (PROTOCOL.md § Views, `settings`, "The folder received files go to"):
//!
//! - Android 10 and later: the public Downloads, through MediaStore (the plugin's Kotlin `publishDownload`, which
//!   needs no permission and keeps the file hidden until it is whole). Android 9 and earlier would need the storage
//!   permission, which Friends does not ask for: the files stay in the app and leave it through Share….
//! - iOS: the app's Documents, which the Files app shows under On My iPhone ▸ the app (`UIFileSharingEnabled`,
//!   `LSSupportsOpeningDocumentsInPlace` in the app's Info.plist).
//! - A test home keeps them inside itself, whatever the phone.
//!
//! Built and tested on any computer; `native.rs` supplies the Android publisher.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use szfriends_core::store::{ExternalPublisher, PhoneFolder, ReceivedDefaults};

/// The first Android version whose MediaStore takes downloads without a permission (Android 10).
pub const MEDIASTORE_DOWNLOADS_SDK: u32 = 29;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(any(target_os = "android", target_os = "ios"), allow(dead_code))]
pub enum Phone {
    /// With its SDK version.
    Android(u32),
    Ios,
}

/// The defaults for `phone`: `home` is the app's home directory (iOS: its container, whose `Documents` the Files app
/// shows), `downloads` the Android publisher.
pub fn defaults(
    phone: Phone,
    state_dir: &Path,
    test_home: bool,
    home: Option<PathBuf>,
    downloads: Option<Arc<dyn ExternalPublisher>>,
) -> ReceivedDefaults {
    let kind = match phone {
        Phone::Android(sdk) if sdk >= MEDIASTORE_DOWNLOADS_SDK && downloads.is_some() => PhoneFolder::Downloads,
        Phone::Android(_) => PhoneFolder::App,
        Phone::Ios => PhoneFolder::AppFiles,
    };
    if test_home {
        return ReceivedDefaults { phone: Some(kind), ..ReceivedDefaults::contained(state_dir) };
    }
    match kind {
        PhoneFolder::Downloads => ReceivedDefaults { folder: None, external: downloads, phone: Some(kind) },
        PhoneFolder::App => {
            ReceivedDefaults { folder: Some(state_dir.join("received")), external: None, phone: Some(kind) }
        }
        PhoneFolder::AppFiles => ReceivedDefaults {
            folder: home.filter(|h| h.is_absolute()).map(|h| h.join("Documents")),
            external: None,
            phone: Some(kind),
        },
    }
}
