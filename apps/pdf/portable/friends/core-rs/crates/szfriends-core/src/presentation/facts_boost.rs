//! The Wi-Fi Direct boost's facts (ADR 0019), for one transfer as this device sees it (facts.rs).

/// Where the Wi-Fi Direct boost (ADR 0019) stands for one transfer, as this device sees it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BoostStage {
    #[default]
    None,
    /// The question: Go faster, Not now (only for views that declared `transfers.boost`).
    Asking,
    /// Both agreed; the link and its lane are being set up.
    Connecting,
    /// The direct lane carries the file.
    Direct,
    /// The transfer ended; this device is getting back on its own Wi-Fi.
    Rejoining,
    /// It did not get back on its Wi-Fi (or back online) by itself.
    RejoinFailed,
}

/// Which device says it, for "Your Mac rejoins it…".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BoostDevice {
    #[default]
    Computer,
    Mac,
    Phone,
}

/// How a device that leaves its Wi-Fi stays online meanwhile (then it is not asked, and the note says so).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StaysOnline {
    Mobile,
    Ethernet,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct BoostFacts {
    pub stage: BoostStage,
    pub device: BoostDevice,
    /// This device's Wi-Fi network by name, when it knows it.
    pub network: Option<String>,
    /// This device leaves its Wi-Fi network for the link.
    pub leaves_wifi: bool,
    pub stays_online: Option<StaysOnline>,
    /// The rest of the file over Bluetooth, and with the boost (setup included), in seconds.
    pub bluetooth_seconds: f64,
    pub direct_seconds: f64,
    /// iOS asks again with its own prompt after Go faster.
    pub system_asks_too: bool,
}
