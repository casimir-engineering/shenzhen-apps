//! A profile's name given right after a computer joins is the one every computer keeps, whichever computer gives it.
//! The new computer took the profile's name from the welcome; that copy is not an edit of its own and never wins over
//! a name given afterwards, and a name it gives at once wins over everything the profile held before it joined (it
//! starts its clock from the one the approving computer had, past what that computer recorded before the join).

mod clients;
mod support;

use std::sync::Mutex;

use clients::{join_profile, texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::service::ENV_TEST_LOOPBACK;
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: helpers start one group at a time.
static START: Mutex<()> = Mutex::new(());

fn start(homes: &[&Temp], network: &Temp) -> Vec<Client> {
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &homes[0].0);
    std::env::set_var(ENV_TEST_LOOPBACK, &network.0);
    homes.iter().map(|home| Client::connect(&home.0)).collect()
}

fn friends_id(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the profile", |d| d["id"]["friends_id"].is_string());
    data["data"]["id"]["friends_id"].as_str().unwrap().to_owned()
}

fn named(data: &Value, name: &str) -> bool {
    texts(data).contains(&format!("\"{name}\""))
}

/// Waits until `client`'s profile shows `name`, then until every computer's next capture (each renames itself) went
/// round every other one, and checks that each still shows `name`.
fn keeps(client: &mut Client, others: &mut [&mut Client], name: &str, round: &str) {
    let mut all: Vec<&mut Client> = vec![client];
    all.extend(others.iter_mut().map(|c| &mut **c));
    let devices: Vec<String> = (0..all.len()).map(|i| format!("{round} {i}")).collect();
    for (i, computer) in all.iter_mut().enumerate() {
        let view = computer.subscribe("profile", json!({}));
        computer.snapshot(&view, &format!("{name} on computer {i}"), |d| named(d, name));
        computer.send("rename_device", json!({"name": devices[i]}));
    }
    for (i, computer) in all.iter_mut().enumerate() {
        let view = computer.subscribe("profile", json!({}));
        let every = |d: &Value| devices.iter().all(|n| texts(d).contains(n.as_str()));
        let shown = computer.snapshot(&view, &format!("every computer's new name on computer {i}"), every);
        assert!(named(&shown["data"], name), "computer {i} went back from {name}: {}", shown["data"]);
    }
}

/// The new computer names the profile the moment it joined, while the profile already has a long history of names:
/// that name wins on every computer.
#[test]
fn a_name_given_on_the_new_computer_right_after_it_joins_wins() {
    let (a, b, c, network) = (Temp::new("ra"), Temp::new("rb"), Temp::new("rc"), Temp::new("rnet"));
    let mut clients = start(&[&a, &b, &c], &network);
    let (mut cy, mut bo, mut ada) = (clients.pop().unwrap(), clients.pop().unwrap(), clients.pop().unwrap());
    ada.send("set_name", json!({"name": "Ada"}));
    for client in [&mut ada, &mut bo, &mut cy] {
        client.send("activate", json!({}));
    }
    let ada_id = friends_id(&mut ada);
    join_profile(&mut ada, &ada_id, &mut bo);
    // Names that went to Bo: Ada's clock is well ahead of a computer that has not synced yet.
    let profile_b = bo.subscribe("profile", json!({}));
    for round in 1..=8 {
        let name = format!("Ada round {round}");
        ada.send("set_name", json!({"name": name}));
        bo.snapshot(&profile_b, &format!("{name} on Bo"), |d| named(d, &name));
    }
    join_profile(&mut ada, &ada_id, &mut cy);
    cy.send("set_name", json!({"name": "Ada Byron"}));
    keeps(&mut cy, &mut [&mut ada, &mut bo], "Ada Byron", "Kept after Cy joined");
}

/// The computer that approved names the profile the moment the new one joined: the copy the new computer took when
/// it joined never takes that name back.
#[test]
fn a_name_given_right_after_a_join_is_not_undone_by_the_new_computers_copy() {
    let (a, b, network) = (Temp::new("rd"), Temp::new("re"), Temp::new("rnet2"));
    let mut clients = start(&[&a, &b], &network);
    let (mut bo, mut ada) = (clients.pop().unwrap(), clients.pop().unwrap());
    ada.send("set_name", json!({"name": "Ada"}));
    for client in [&mut ada, &mut bo] {
        client.send("activate", json!({}));
    }
    let ada_id = friends_id(&mut ada);
    join_profile(&mut ada, &ada_id, &mut bo);
    ada.send("set_name", json!({"name": "Ada Lovelace"}));
    keeps(&mut ada, &mut [&mut bo], "Ada Lovelace", "Kept after Bo joined");
}
