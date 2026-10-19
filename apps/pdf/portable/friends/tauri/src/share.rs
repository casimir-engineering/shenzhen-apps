//! File ▸ Copy Download Link in the app's own menu (PROTOCOL.md § Links, "Copying a download link"), as the Electron
//! app has it (`electron/friends/share-menu.cjs`): there while the helper announces `links`, enabled while the
//! focused window has a model open, and its choice of 7, 1 or 30 days sent to that window alone, which stages its
//! model and asks for the link as its header's Copy Download Link does. The menu is the app's; the plugin tells it
//! when to show and enable the item ([`crate::Config::share_menu`]) and takes its choice
//! ([`crate::copy_download_link`]).

use std::collections::HashSet;

use serde_json::json;
use tauri::{Manager, Runtime};

use super::Host;
use crate::link::LinkState;

/// What the app's Copy Download Link item shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ShareMenu {
    /// The item is there: Friends is ready and its helper makes download links.
    pub offered: bool,
    /// It can be chosen: the focused window has a model open.
    pub enabled: bool,
}

/// The windows with a model open, and what the app was last told.
#[derive(Debug, Default)]
pub(super) struct Share {
    shareable: HashSet<String>,
    shown: Option<ShareMenu>,
}

/// The item is there while Friends is ready and the helper's welcome announces `links`, and can be chosen while the
/// focused window also has a model open.
pub(super) fn decide(ready: bool, welcome: Option<&serde_json::Value>, focused_shareable: bool) -> ShareMenu {
    let links =
        welcome.and_then(|w| w["capabilities"].as_array()).is_some_and(|list| list.iter().any(|c| c == "links"));
    let offered = ready && links;
    ShareMenu { offered, enabled: offered && focused_shareable }
}

/// How long a link may live, in days: the menu's three choices.
pub const LINK_DAYS: [u32; 3] = [7, 1, 30];

impl<R: Runtime> Host<R> {
    /// The served window that has the focus, asked without holding the host's lock (the answer comes from the main
    /// thread).
    fn focused_served_window(&self) -> Option<String> {
        let served = self.config.windows.clone();
        self.app
            .webview_windows()
            .into_iter()
            .find(|(label, window)| served.contains(label) && window.is_focused().unwrap_or(false))
            .map(|(label, _)| label)
    }

    fn share_menu(&self, focused: Option<&str>) -> ShareMenu {
        let state = self.lock();
        let ready = state.link_state == Some(LinkState::Ready);
        let shareable = focused.is_some_and(|label| state.share.shareable.contains(label));
        decide(ready, state.router.welcome.as_ref(), shareable)
    }

    /// Tells the app's menu what to show, when that changed.
    pub fn refresh_share_menu(&self) {
        let Some(hook) = self.config.share_menu.clone() else { return };
        let focused = self.focused_served_window();
        let menu = self.share_menu(focused.as_deref());
        {
            let mut state = self.lock();
            if state.share.shown == Some(menu) {
                return;
            }
            state.share.shown = Some(menu);
        }
        hook(&self.app, menu);
    }

    /// A window says whether it has a model open.
    pub fn set_shareable(&self, label: &str, value: bool) {
        {
            let mut state = self.lock();
            if value {
                state.share.shareable.insert(label.to_owned());
            } else {
                state.share.shareable.remove(label);
            }
        }
        self.refresh_share_menu();
    }

    pub(super) fn forget_shareable(&self, label: &str) {
        self.lock().share.shareable.remove(label);
    }

    /// The app's menu chose an expiry: the focused window, when it has a model open, makes the link.
    pub fn copy_download_link(&self, days: u32) -> bool {
        if !LINK_DAYS.contains(&days) {
            return false;
        }
        let Some(label) = self.focused_served_window() else { return false };
        if !self.share_menu(Some(&label)).enabled {
            return false;
        }
        let state = self.lock();
        let Some(channel) = state.windows.get(&label) else { return false };
        channel.send(json!({"kind": "copy_download_link", "days": days})).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{decide, ShareMenu};

    #[test]
    fn there_while_links_are_made_and_enabled_for_a_window_with_a_model() {
        let links = json!({"capabilities": ["mentions", "links"]});
        let none = json!({"capabilities": ["mentions"]});
        assert_eq!(decide(true, Some(&links), true), ShareMenu { offered: true, enabled: true });
        assert_eq!(decide(true, Some(&links), false), ShareMenu { offered: true, enabled: false });
        assert_eq!(decide(false, Some(&links), true), ShareMenu::default(), "not while Friends is not ready");
        assert_eq!(decide(true, Some(&none), true), ShareMenu::default(), "not while the helper makes no links");
        assert_eq!(decide(true, None, true), ShareMenu::default(), "not before a welcome");
    }
}
