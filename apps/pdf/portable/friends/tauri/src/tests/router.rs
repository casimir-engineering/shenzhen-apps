//! The router's rules, case for case with Shenzhen 3D's Electron router tests (`electron/friends-bridge.test.cjs`).

use serde_json::{json, Value};

use super::*;

fn window(label: &str) -> Owner {
    Owner::Window(label.to_owned())
}

fn snapshot(subscription: &str, view: &str, rev: u64, data: Value) -> Value {
    json!({"type": "snapshot", "subscription": subscription, "view": view, "rev": rev, "data": data})
}

fn reply(re: &str, result: Value) -> Value {
    json!({"type": "reply", "re": re, "ok": true, "result": result})
}

fn delivered_to(deliveries: &[Delivery]) -> Vec<(String, Value)> {
    deliveries
        .iter()
        .filter_map(|d| match d {
            Delivery::To(label, event) => Some((label.clone(), event["frame"]["subscription"].clone())),
            Delivery::All(_) => None,
        })
        .collect()
}

#[test]
fn a_snapshot_sent_before_its_reply_reaches_the_window_with_that_reply() {
    let mut router = Router::default();
    let mut pending = router.sent("5", window("main"), "subscribe", json!({"view": "list"}));
    assert!(router.frame(snapshot("s_1", "list", 1, json!({"rows": []}))).is_empty());
    router.frame(reply("5", json!({"subscription": "s_1"})));
    let routed = pending.try_recv().expect("resolved");
    assert_eq!(routed.reply["result"]["subscription"], "s_1");
    assert_eq!(routed.snapshot.expect("the held snapshot")["rev"], 1);
    let next = router.frame(snapshot("s_1", "list", 2, json!({})));
    assert_eq!(delivered_to(&next), vec![("main".to_owned(), json!("s_1"))]);
}

#[test]
fn replies_and_snapshots_go_only_to_the_window_that_asked_and_the_badge_to_all() {
    let mut router = Router::default();
    let mut a = router.sent("1", window("a"), "open_conversation", json!({"conversation_id": "c_1"}));
    let mut b = router.sent("2", window("b"), "subscribe", json!({"view": "list"}));
    let mut badge = router.sent("3", Owner::Host, "subscribe", json!({"view": "badge"}));
    router.frame(reply("2", json!({"subscription": "s_2"})));
    router.frame(reply("1", json!({"subscription": "s_1", "conversation_id": "c_1"})));
    let data = json!({"count": 2, "label": "2", "accessibility_label": "Friends, 2 waiting for you"});
    router.frame(snapshot("s_3", "badge", 1, data.clone()));
    let all = router.frame(reply("3", json!({"subscription": "s_3"})));
    assert_eq!(all, vec![Delivery::All(json!({"kind": "badge", "data": data}))]);
    assert!(a.try_recv().is_ok() && b.try_recv().is_ok());
    assert_eq!(badge.try_recv().expect("resolved").snapshot, None, "the badge is the bridge's own");
    let mut out = router.frame(snapshot("s_1", "conversation", 1, json!({})));
    out.extend(router.frame(snapshot("s_2", "list", 1, json!({}))));
    assert_eq!(delivered_to(&out), vec![("a".to_owned(), json!("s_1")), ("b".to_owned(), json!("s_2"))]);
    assert_eq!(router.badge.as_ref().expect("a badge")["count"], 2);
}

#[test]
fn a_closed_windows_subscriptions_are_handed_back_and_its_intents_resolve_as_lost() {
    let mut router = Router::default();
    drop(router.sent("1", window("seven"), "subscribe", json!({"view": "list"})));
    router.frame(reply("1", json!({"subscription": "s_1"})));
    let mut waiting = router.sent("2", window("seven"), "accept_offer", json!({"transfer_id": "t_1"}));
    assert_eq!(router.drop_owner(&window("seven")), vec!["s_1".to_owned()]);
    assert_eq!(waiting.try_recv().expect("resolved").reply["error"]["code"], "connection_lost");
    // Held, never delivered: nobody owns it now.
    assert!(router.frame(snapshot("s_1", "list", 2, json!({}))).is_empty());
}

#[test]
fn leaving_ready_voids_every_subscription_and_stopping_answers_every_intent() {
    let mut router = Router::default();
    drop(router.sent("1", window("main"), "subscribe", json!({"view": "list"})));
    router.frame(reply("1", json!({"subscription": "s_1"})));
    drop(router.sent("9", Owner::Host, "subscribe", json!({"view": "badge"})));
    router.frame(reply("9", json!({"subscription": "s_9"})));
    router.frame(snapshot("s_9", "badge", 1, json!({"count": 1})));
    let out = router.connection_changed(false);
    assert_eq!(out, vec![Delivery::All(json!({"kind": "badge", "data": null}))]);
    assert!(router.frame(snapshot("s_1", "list", 3, json!({}))).is_empty());
    let mut waiting = router.sent("2", window("main"), "ping", json!({}));
    router.stopped();
    assert_eq!(waiting.try_recv().expect("resolved").reply["error"]["code"], "connection_lost");
}

#[test]
fn a_window_holds_a_bounded_number_of_subscriptions() {
    let mut router = Router::default();
    for index in 0..MAX_SUBSCRIPTIONS_PER_WINDOW {
        drop(router.sent(&index.to_string(), window("main"), "subscribe", json!({})));
    }
    assert!(!router.may_add_subscription(&window("main")));
    assert!(router.may_add_subscription(&window("other")));
}

#[test]
fn an_unsubscribe_forgets_the_owner_so_a_reused_id_cannot_reach_the_old_window() {
    let mut router = Router::default();
    drop(router.sent("1", window("main"), "subscribe", json!({"view": "list"})));
    router.frame(reply("1", json!({"subscription": "s_1"})));
    drop(router.sent("2", window("main"), "unsubscribe", json!({"subscription": "s_1"})));
    router.frame(reply("2", json!({})));
    assert!(router.frame(snapshot("s_1", "list", 2, json!({}))).is_empty());
}
