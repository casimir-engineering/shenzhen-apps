//! Two whole helpers with no route between them but the local host (`host.rs`), whichever implementation each is:
//! a new computer joins the other's profile through the host (`to.join`), then the two computers of one person sync
//! over the sessions online carries between them, each way; and Add by ID through the host, answered by the ID's
//! holder online. Each helper is driven through its client protocol, as an app drives it.

use std::time::Duration;

use serde_json::{json, Value};

use crate::helpers::Client;

/// Online waits can include a reach made before the other side checked in, which waits out the driver's backoff.
const ONLINE_WAIT: Duration = Duration::from_secs(120);

/// The profile's Friends ID once the host reserved it: the helper is checked in.
pub fn reserved_id(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data =
        client.snapshot_within(&profile, "a reserved Friends ID", ONLINE_WAIT, |d| d["id"]["state"] == "reserved");
    client.send("unsubscribe", json!({"subscription": profile}));
    data["id"]["friends_id"].as_str().expect("an ID").to_owned()
}

/// Names `holder`, opens Friends in both, and waits until both are checked in.
pub fn start(holder: &mut Client, holder_name: &str, other: &mut Client, other_name: Option<&str>) {
    holder.send("set_name", json!({"name": holder_name}));
    if let Some(name) = other_name {
        other.send("set_name", json!({"name": name}));
    }
    for client in [&mut *holder, &mut *other] {
        client.send("activate", json!({}));
        reserved_id(client);
    }
}

fn texts(data: &Value) -> String {
    data.to_string()
}

/// `joiner` joins `holder`'s profile through the host, then each computer's change reaches the other online: the
/// new computer's name on the first, the profile's new name on the new one.
pub fn join_and_sync(holder: &mut Client, holder_name: &str, joiner: &mut Client) {
    start(holder, holder_name, joiner, None);
    let id = crate::nearby_devices::join(holder, joiner);
    let profile_j = joiner.subscribe("profile", json!({}));
    joiner.snapshot_within(&profile_j, "the profile on the new computer", ONLINE_WAIT, |d| {
        d["id"]["friends_id"] == id.as_str() && texts(d).contains(holder_name)
    });
    joiner.send("rename_device", json!({"name": "Workshop PC"}));
    let profile_h = holder.subscribe("profile", json!({}));
    holder.snapshot_within(&profile_h, "the new computer's name, online", ONLINE_WAIT, |d| {
        texts(d).contains("Workshop PC")
    });
    let renamed = format!("{holder_name} Lovelace");
    holder.send("set_name", json!({"name": renamed}));
    joiner.snapshot_within(&profile_j, "the new name on the new computer, online", ONLINE_WAIT, |d| {
        texts(d).contains(&renamed)
    });
}

fn rows(data: &Value) -> Vec<Value> {
    data["rows"].as_array().cloned().unwrap_or_default()
}

/// `asker` adds `holder` by the Friends ID the host reserved for them; `holder` accepts; the answer calls `asker`
/// back online (a request to accept where no host vouched for it); then a message each way.
pub fn add_by_id(asker: &mut Client, asker_name: &str, holder: &mut Client, holder_name: &str) {
    start(holder, holder_name, asker, Some(asker_name));
    let id = reserved_id(holder);
    let holder_in_a = asker.send("add_by_id", json!({"friends_id": id}))["conversation_id"]
        .as_str()
        .expect("a conversation")
        .to_owned();
    let list_h = holder.subscribe("list", json!({}));
    let waiting = |d: &Value| rows(d).into_iter().find(|r| r["waiting"]["kind"] == "request");
    let asked =
        holder.snapshot_within(&list_h, "the request by ID, through the host", ONLINE_WAIT, |d| waiting(d).is_some());
    let asker_in_h = waiting(&asked).expect("checked")["conversation_id"].as_str().expect("an id").to_owned();
    holder.send("accept_request", json!({"conversation_id": asker_in_h}));
    let list_a = asker.subscribe("list", json!({}));
    let row = |d: &Value| rows(d).into_iter().find(|r| r["conversation_id"] == holder_in_a.as_str());
    let answered = asker.snapshot_within(&list_a, "the answer, online", ONLINE_WAIT, |d| {
        row(d).is_some_and(|r| r["subtitle"] != "Request sent" && texts(&r).contains(holder_name))
    });
    if texts(&row(&answered).expect("checked")["actions"]).contains("accept_request") {
        asker.send("accept_request", json!({"conversation_id": holder_in_a}));
    }
    let (chat_a, chat_h) = (asker.open(&holder_in_a), holder.open(&asker_in_h));
    let token = "00112233445566778899aabbccddeeff";
    asker.send("send_message", json!({"conversation_id": holder_in_a, "text": "Hello by ID", "client_token": token}));
    holder.snapshot_within(&chat_h, "the message, online", ONLINE_WAIT, |d| texts(d).contains("Hello by ID"));
    let token = "ffeeddccbbaa99887766554433221100";
    holder.send("send_message", json!({"conversation_id": asker_in_h, "text": "Got it", "client_token": token}));
    asker.snapshot_within(&chat_a, "the reply, online", ONLINE_WAIT, |d| texts(d).contains("Got it"));
}
