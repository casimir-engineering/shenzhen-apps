//! Coming back from a boost (boost.rs): what a device writes down before it leaves its Wi-Fi network, and the rejoin
//! that runs when the boost ends, on the next launch after a crash too.

use super::*;

/// What a device writes down before it leaves its Wi-Fi network for a joined link, so it comes back after the boost,
/// after a crash too. Kept in the helper's state directory (`direct-wifi.json`), never sent anywhere.
#[derive(Clone, Debug, PartialEq)]
pub struct Saved {
    /// The network to go back to: the platform's own reference (a name, or Android's network id); `None` when the
    /// device was on no Wi-Fi network, so coming back is only leaving the link.
    pub network: Option<String>,
    /// Its name as the person knows it, for "Couldn't rejoin …".
    pub network_name: Option<String>,
    /// The link joined, so a launch after a crash leaves it only if the device is still on it.
    pub joined: String,
    /// Unix time it left.
    pub left_at: f64,
}

impl Saved {
    pub fn to_json(&self) -> Value {
        json!({
            "version": 1,
            "network": self.network,
            "network_name": self.network_name,
            "joined": self.joined,
            "left_at": self.left_at,
        })
    }

    /// `None` for anything else, a later version included: such a record is left alone.
    pub fn from_json(value: &Value) -> Option<Self> {
        if value.get("version")?.as_u64()? != 1 {
            return None;
        }
        let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            network: text("network"),
            network_name: text("network_name"),
            joined: text("joined").filter(|j| !j.is_empty())?,
            left_at: value.get("left_at")?.as_f64()?,
        })
    }
}

/// Rejoining is tried this many times, this far apart.
pub const REJOIN_TRIES: u32 = 3;
pub const REJOIN_AGAIN_AFTER: Duration = Duration::from_secs(3);
/// After rejoining, the Internet must be back within this long, checked this often.
pub const ONLINE_WITHIN: Duration = Duration::from_secs(20);
pub const CHECK_EVERY: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq)]
pub enum RejoinEffect {
    /// Write the record (before leaving the network).
    Write(Saved),
    /// Leave the joined link (if still on it) and rejoin this network (`None`: only leave).
    Rejoin { network: Option<String>, joined: String },
    /// Is the device online again? Answer with [`Rejoin::online`].
    CheckOnline,
    /// Delete the record: back where it was.
    Forget,
    /// Tell the person their device did not get back on that network (or back online) by itself.
    Tell { network_name: Option<String> },
}

#[derive(Clone, Debug, PartialEq)]
enum RejoinStep {
    Idle,
    /// Off its network, on a joined link (the record is written).
    Away(Saved),
    Rejoining {
        saved: Saved,
        tries: u32,
        at: Duration,
    },
    Checking {
        saved: Saved,
        since: Duration,
        at: Duration,
    },
    /// Gave up and told the person.
    Failed,
}

/// One device's way back to its own Wi-Fi network.
#[derive(Debug)]
pub struct Rejoin {
    step: RejoinStep,
    effects: Vec<RejoinEffect>,
}

impl Default for Rejoin {
    fn default() -> Self {
        Self { step: RejoinStep::Idle, effects: Vec::new() }
    }
}

impl Rejoin {
    /// At launch, with the record a previous run left (it crashed or was killed while away): come back now.
    pub fn launched(record: Option<Saved>, now: Duration) -> Self {
        let mut rejoin = Self::default();
        if let Some(saved) = record {
            rejoin.step = RejoinStep::Away(saved);
            rejoin.come_back(now);
        }
        rejoin
    }

    pub fn away(&self) -> bool {
        !matches!(self.step, RejoinStep::Idle | RejoinStep::Failed)
    }

    pub fn take_effects(&mut self) -> Vec<RejoinEffect> {
        std::mem::take(&mut self.effects)
    }

    /// About to leave the network for a link: the record is written first.
    pub fn leaving(&mut self, saved: Saved) {
        self.effects.push(RejoinEffect::Write(saved.clone()));
        self.step = RejoinStep::Away(saved);
    }

    /// The boost ended (finished, failed, cancelled, slower, the session gone) or the app quits: rejoin now.
    pub fn come_back(&mut self, now: Duration) {
        if let RejoinStep::Away(saved) = &self.step {
            let saved = saved.clone();
            self.effects.push(RejoinEffect::Rejoin { network: saved.network.clone(), joined: saved.joined.clone() });
            self.step = RejoinStep::Rejoining { saved, tries: 1, at: now };
        }
    }

    /// The platform's answer to [`RejoinEffect::Rejoin`].
    pub fn rejoined(&mut self, ok: bool, now: Duration) {
        let RejoinStep::Rejoining { saved, tries, .. } = &self.step else { return };
        let (saved, tries) = (saved.clone(), *tries);
        if ok {
            if saved.network.is_none() {
                // It was on no Wi-Fi network: off the link is back where it was.
                self.done();
            } else {
                self.effects.push(RejoinEffect::CheckOnline);
                self.step = RejoinStep::Checking { saved, since: now, at: now };
            }
        } else if tries >= REJOIN_TRIES {
            self.give_up(&saved);
        } else {
            self.step = RejoinStep::Rejoining { saved, tries, at: now };
        }
    }

    /// The platform's answer to [`RejoinEffect::CheckOnline`].
    pub fn online(&mut self, online: bool, now: Duration) {
        let RejoinStep::Checking { saved, since, .. } = &self.step else { return };
        let (saved, since) = (saved.clone(), *since);
        if online {
            self.done();
        } else if now.saturating_sub(since) >= ONLINE_WITHIN {
            self.give_up(&saved);
        } else {
            self.step = RejoinStep::Checking { saved, since, at: now };
        }
    }

    /// Retries: rejoining again after [`REJOIN_AGAIN_AFTER`], checking again every [`CHECK_EVERY`].
    pub fn tick(&mut self, now: Duration) {
        match &self.step {
            RejoinStep::Rejoining { saved, tries, at } if now.saturating_sub(*at) >= REJOIN_AGAIN_AFTER => {
                let (saved, tries) = (saved.clone(), *tries);
                // A try still unanswered counts as failed after the wait.
                if tries >= REJOIN_TRIES {
                    self.give_up(&saved);
                    return;
                }
                self.effects
                    .push(RejoinEffect::Rejoin { network: saved.network.clone(), joined: saved.joined.clone() });
                self.step = RejoinStep::Rejoining { saved, tries: tries + 1, at: now };
            }
            RejoinStep::Checking { saved, since, at } if now.saturating_sub(*at) >= CHECK_EVERY => {
                let (saved, since) = (saved.clone(), *since);
                if now.saturating_sub(since) >= ONLINE_WITHIN {
                    self.give_up(&saved);
                    return;
                }
                self.effects.push(RejoinEffect::CheckOnline);
                self.step = RejoinStep::Checking { saved, since, at: now };
            }
            _ => {}
        }
    }

    pub(super) fn done(&mut self) {
        self.effects.push(RejoinEffect::Forget);
        self.step = RejoinStep::Idle;
    }

    pub(super) fn give_up(&mut self, saved: &Saved) {
        // The record goes too: the person now decides which network to be on, and a later launch must not fight it.
        self.effects.push(RejoinEffect::Forget);
        self.effects.push(RejoinEffect::Tell { network_name: saved.network_name.clone() });
        self.step = RejoinStep::Failed;
    }
}

#[cfg(test)]
mod tests;
