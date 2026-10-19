//! One person's two computers between two whole helpers, whichever implementation each is (ADR 0013, ADR 0014): the
//! new computer asks to join by the profile's Friends ID over nearby, the computer holding the profile approves and
//! shows a code, a wrong code is refused and the right one joins; then both list both computers, and a computer's new
//! name and the profile's new name reach the other over the session between them. Each helper is driven through its
//! client protocol, as an app drives it.

use serde_json::{json, Value};

use crate::helpers::Client;

fn join_row(data: &Value) -> Option<Value> {
    data["join_requests"].as_array()?.first().cloned()
}

fn friends_id(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the profile's ID", |d| d["id"]["friends_id"].is_string());
    client.send("unsubscribe", json!({"subscription": profile}));
    data["id"]["friends_id"].as_str().expect("checked").to_owned()
}

/// `joiner` joins `holder`'s profile over nearby: asked by ID, approved on `holder`, a wrong code, then the right one.
pub fn join(holder: &mut Client, joiner: &mut Client) -> String {
    let id = friends_id(holder);
    let view = joiner.subscribe("join", json!({}));
    joiner.snapshot(&view, "joining offered", |d| d["state"] == "idle");
    joiner.send("join_profile", json!({"friends_id": id}));
    joiner.snapshot(&view, "the request on its way", |d| d["state"] == "waiting");

    let list = holder.subscribe("list", json!({}));
    let asked = holder.snapshot(&list, "the new computer's request", |d| join_row(d).is_some());
    let join_id = join_row(&asked).expect("checked")["join_id"].as_str().expect("an id").to_owned();
    holder.send("approve_join", json!({"join_id": join_id}));
    let approved = holder.snapshot(&list, "the code shown", |d| join_row(d).is_some_and(|r| r["code"].is_string()));
    let code: String = join_row(&approved).expect("checked")["code"].as_str().expect("a code").replace(' ', "");

    let wrong = if code.starts_with('0') { "11111111" } else { "00000000" };
    joiner.send("enter_join_code", json!({"code": wrong}));
    joiner.snapshot(&view, "a wrong code said so", |d| d["state"] == "wrong_code");
    joiner.send("enter_join_code", json!({"code": code}));
    joiner.snapshot(&view, "joined", |d| d["state"] == "joined");
    holder.snapshot(&list, "the request answered", |d| join_row(d).is_none());
    holder.send("unsubscribe", json!({"subscription": list}));
    joiner.send("unsubscribe", json!({"subscription": view}));
    id
}

/// The joined computer holds the profile, both list both computers, and names given on one reach the other.
pub fn join_and_sync(holder: &mut Client, holder_name: &str, joiner: &mut Client) {
    let id = join(holder, joiner);
    let profile_j = joiner.subscribe("profile", json!({}));
    joiner.snapshot(&profile_j, "the profile on the new computer", |d| {
        d["id"]["friends_id"] == id.as_str() && d.to_string().contains(holder_name)
    });
    joiner.send("rename_device", json!({"name": "Workshop PC"}));
    let profile_h = holder.subscribe("profile", json!({}));
    holder.snapshot(&profile_h, "the new computer's name in Your computers", |d| d.to_string().contains("Workshop PC"));
    let renamed = format!("{holder_name} Lovelace");
    holder.send("set_name", json!({"name": renamed}));
    joiner.snapshot(&profile_j, "the new name on the new computer", |d| d.to_string().contains(&renamed));
}
