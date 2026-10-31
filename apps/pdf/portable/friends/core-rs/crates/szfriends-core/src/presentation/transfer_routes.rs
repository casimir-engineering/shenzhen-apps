//! A moving transfer's progress by route (PROTOCOL.md § Fast transfers, Progress by route), for views that declared
//! `transfers.progress` (`SZFriendsSnapshotBuilder+TransferRoutes.m`): the routes carrying it as icons, the bar split by what
//! each route carried, "31.2 MB of 48 MB · 12.4 MB/s" with "2 s left", and "Via Same Wi-Fi + Bluetooth" with the
//! transfer's notes. Other views keep the percentage in `status_label` and the estimate in `route_note`.

use serde_json::{json, Map, Value};

use super::facts::{BoostStage, ItemFacts, RouteMethod, TransferState};
use super::shared::route_method_name;
use super::SnapshotBuilder;

/// The order the icons, the bar's segments and "Via …" follow: the owner's route rank.
const ORDER: [RouteMethod; 5] =
    [RouteMethod::Lan, RouteMethod::PeerToPeerWifi, RouteMethod::Internet, RouteMethod::Bluetooth, RouteMethod::Relay];

fn route_key(route: RouteMethod) -> &'static str {
    match route {
        RouteMethod::Lan => "transfer.route.lan",
        RouteMethod::PeerToPeerWifi => "transfer.route.p2p_wifi",
        RouteMethod::Internet => "transfer.route.internet",
        RouteMethod::Bluetooth => "transfer.route.bluetooth",
        RouteMethod::Relay | RouteMethod::None => "transfer.route.relay",
    }
}

/// "2 s left", "4 min left", "1 h 5 min left": exact seconds under a minute, so the helper's steady countdown shows.
fn time_left(s: &super::Strings, seconds: f64) -> String {
    if seconds < 59.5 {
        let n = (seconds.ceil() as i64).max(1).to_string();
        return s.text_with("transfer.left.seconds", &[("n", &n)]);
    }
    let minutes = ((seconds / 60.0).round() as i64).max(1);
    if minutes < 60 {
        return s.text_with("transfer.left.minutes", &[("n", &minutes.to_string())]);
    }
    let (h, m) = ((minutes / 60).to_string(), (minutes % 60).to_string());
    if minutes % 60 == 0 {
        return s.text_with("transfer.left.hours", &[("h", &h)]);
    }
    s.text_with("transfer.left.hours_minutes", &[("h", &h), ("m", &m)])
}

impl SnapshotBuilder {
    /// Adds the routes, segments and labels to a transfer whose `progress` is set, for a view that draws them.
    pub(crate) fn progress_by_route(&self, transfer: &mut Map<String, Value>, item: &ItemFacts) {
        if !self.audience().has("transfers.progress") {
            return;
        }
        let Some(Value::Object(progress)) = transfer.get("progress") else { return };
        let s = &self.strings;
        let mut progress = progress.clone();
        let finishing = item.finishing && item.state() == TransferState::Receiving;
        let fraction = progress.get("fraction").and_then(Value::as_f64).unwrap_or(0.0).clamp(0.0, 1.0);
        let size = item.file_size;
        let moving = matches!(item.state(), TransferState::Sending | TransferState::Receiving);
        let done = if moving { item.bytes_done } else { (fraction * size as f64).round() as u64 }.min(size);

        // What carried it: the helper's counts, or else the one route the transfer is on.
        let mut carried: Vec<(RouteMethod, u64)> = item.route_bytes.clone();
        let mut active: Vec<RouteMethod> = item.active_routes.clone();
        if carried.is_empty() && item.transfer_route != RouteMethod::None {
            carried.push((item.transfer_route, 1));
            active = vec![item.transfer_route];
        }
        if finishing {
            active.clear();
        }
        let routes: Vec<Value> = if finishing {
            Vec::new()
        } else {
            ORDER
                .iter()
                .filter(|r| active.contains(r) || carried.iter().any(|(c, _)| c == *r))
                .map(|r| {
                    let in_use = active.contains(r);
                    let name = s.text(route_key(*r));
                    let key = if in_use { "transfer.route.in_use" } else { "transfer.route.used" };
                    json!({"method": route_method_name(*r), "active": in_use, "label": s.text_with(key, &[("route", &name)])})
                })
                .collect()
        };
        let total: u64 = carried.iter().map(|(_, b)| b).sum();
        let segments: Vec<Value> = ORDER
            .iter()
            .filter_map(|r| carried.iter().find(|(c, _)| c == r))
            .map(|(r, b)| json!({"method": route_method_name(*r), "fraction": fraction * *b as f64 / total as f64}))
            .collect();

        let size_label = s.size_label(size);
        // Whole numbers, as the bar and its spoken label count them.
        let percent = ((fraction * 100.0).round() as i64).clamp(0, 100).to_string();
        let amount = if finishing {
            s.text_with("transfer.amount.whole", &[("size", &size_label), ("percent", &percent)])
        } else {
            let done_label = s.size_label(done);
            let amount =
                s.text_with("transfer.amount", &[("done", &done_label), ("size", &size_label), ("percent", &percent)]);
            if item.bytes_per_second > 0.0 {
                let rate = s.text_with("transfer.rate", &[("size", &s.size_label(item.bytes_per_second as u64))]);
                s.text_with("transfer.amount.rate", &[("amount", &amount), ("rate", &rate)])
            } else {
                amount
            }
        };
        let left = if finishing {
            Some(s.text("transfer.finishing"))
        } else if item.seconds_left > 0.0 && done < size {
            Some(time_left(s, item.seconds_left))
        } else {
            None
        };

        let mut parts: Vec<String> = Vec::new();
        if !active.is_empty() {
            let names: Vec<String> =
                ORDER.iter().filter(|r| active.contains(r)).map(|r| s.text(route_key(*r))).collect();
            parts.push(s.text_with("transfer.via", &[("routes", &names.join(&s.text("transfer.via.separator")))]));
        }
        if item.holders >= 2 {
            let key = if item.own_holders == item.holders { "transfer.note.holders" } else { "transfer.note.devices" };
            parts.push(s.text_with(key, &[("count", &item.holders.to_string())]));
        }
        let boost = &item.boost;
        if boost.stage == BoostStage::Direct && boost.leaves_wifi {
            let network = match boost.network.as_deref().filter(|n| !n.is_empty()) {
                Some(name) => s.text_with("transfer.boost.network", &[("name", name)]),
                None => s.text("transfer.boost.your_wifi"),
            };
            parts.push(s.text_with("transfer.note.rejoin", &[("network", &network)]));
        }
        let detail = (!parts.is_empty()).then(|| parts.join(&s.text("transfer.detail.separator")));

        progress.insert("routes".into(), Value::Array(routes));
        progress.insert("segments".into(), Value::Array(segments));
        progress.insert("amount_label".into(), json!(amount));
        progress.insert("time_left_label".into(), json!(left));
        progress.insert("detail_label".into(), json!(detail));
        progress.insert("finishing".into(), json!(finishing));
        transfer.insert("progress".into(), Value::Object(progress));
        // The detail line says the routes and the boost's direct leg; the estimate and the copy's route line would
        // say them again. The boost's question and its other steps stay, with their actions.
        let boost_speaks =
            matches!(boost.stage, BoostStage::Connecting | BoostStage::Rejoining | BoostStage::RejoinFailed)
                || (boost.stage == BoostStage::Asking && self.asks_boost(item));
        if !boost_speaks {
            transfer.insert("route_note".into(), Value::Null);
        }
        transfer.remove("route");
    }
}
