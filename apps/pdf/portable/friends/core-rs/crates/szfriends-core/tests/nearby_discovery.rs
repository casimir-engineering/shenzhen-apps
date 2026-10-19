//! The merger and the racer with scripted sightings (ADR 0004 § Verification, as `SZFriendsDiscoveryTests.m` runs
//! them against the helper's own): simultaneous, out-of-order, flapping and expiring sightings, one row per person,
//! the stagger toward better routes, and the backoff a relayed tag earns.

use szfriends_core::crypto::presence;
use szfriends_core::nearby::callbacks::{window, TagMatcher};
use szfriends_core::nearby::merger::{Merger, BLUETOOTH_SIGHTING_LIFE_SECONDS, BONJOUR_REMOVAL_GRACE_SECONDS};
use szfriends_core::nearby::racer::{self, Decision, Racer};
use szfriends_core::nearby::{Method, RouteMethod, Sighting, Tag};

const NOW: f64 = 1_800_000_000.0;
const SECRET: [u8; 32] = [42; 32];

fn tag() -> Tag {
    presence::tag(&SECRET, window(NOW))
}

fn matcher() -> TagMatcher {
    TagMatcher::new([("friend", &SECRET[..])], NOW)
}

fn sighting(method: Method, route: RouteMethod, endpoint: &str, tag: Option<Tag>, at: f64) -> Sighting {
    Sighting {
        method,
        route,
        endpoint: endpoint.into(),
        presence_tag: tag,
        callback_tags: Vec::new(),
        public: false,
        seen_at: at,
    }
}

fn public(endpoint: &str, at: f64) -> Sighting {
    Sighting { public: true, ..sighting(Method::Network, RouteMethod::Lan, endpoint, None, at) }
}

#[test]
fn one_candidate_per_person_across_methods() {
    let mut merger = Merger::new(matcher());
    merger.add_sighting(sighting(Method::Bluetooth, RouteMethod::Bluetooth, "bt1", Some(tag()), NOW));
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW));
    let candidates = merger.candidates();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].conversation_id.as_deref(), Some("friend"));
    assert_eq!(candidates[0].sightings[0].route, RouteMethod::Lan, "best route first");
    assert!(merger.unmatched().is_empty());
}

#[test]
fn ids_survive_merges_and_flaps() {
    let mut merger = Merger::new(TagMatcher::default());
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW));
    let before = merger.unmatched()[0].id.clone();
    assert!(merger.candidates().is_empty(), "an unmatched device is never a candidate");
    merger.set_matcher(matcher());
    assert_eq!(merger.candidates()[0].id, before, "matching keeps the id");
    let generation = merger.generation();
    merger.remove_endpoint("lan1", Method::Network, NOW + 1.0);
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW + 2.0));
    assert_eq!(merger.candidates()[0].id, before);
    assert_eq!(merger.generation(), generation, "a flap inside the grace changes nothing");
}

#[test]
fn out_of_order_sightings_never_revive() {
    let mut merger = Merger::new(matcher());
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW + 5.0));
    merger.remove_endpoint("lan1", Method::Network, NOW + 6.0);
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW + 4.0));
    assert!(!merger.expire(NOW + 6.0 + BONJOUR_REMOVAL_GRACE_SECONDS - 0.1));
    assert!(merger.expire(NOW + 6.0 + BONJOUR_REMOVAL_GRACE_SECONDS));
    assert!(merger.candidates().is_empty());
}

#[test]
fn methods_expire_on_their_own() {
    let mut merger = Merger::new(matcher());
    merger.add_sighting(sighting(Method::Bluetooth, RouteMethod::Bluetooth, "bt1", Some(tag()), NOW));
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW));
    assert_eq!(merger.next_expiry(), Some(NOW + BLUETOOTH_SIGHTING_LIFE_SECONDS));
    merger.expire(NOW + BLUETOOTH_SIGHTING_LIFE_SECONDS);
    let candidate = &merger.candidates()[0];
    assert_eq!(candidate.sightings.len(), 1, "Bluetooth expired, the LAN sighting carries on");
    merger.remove_endpoint("lan1", Method::Network, NOW + 100.0);
    merger.remove_endpoint("lan1", Method::Network, NOW + 120.0);
    assert_eq!(merger.next_expiry(), Some(NOW + 100.0 + BONJOUR_REMOVAL_GRACE_SECONDS), "no extension");
}

#[test]
fn public_entries_are_strangers_until_identified() {
    let mut merger = Merger::new(matcher());
    merger.add_sighting(public("pub1", NOW));
    merger.add_sighting(public("pub2", NOW));
    assert_eq!(merger.candidates().len(), 2, "entry names are never identity");
    assert_eq!(merger.identified().count(), 0);
    merger.identify("pub1", Method::Network, [7; 32], None);
    merger.identify("pub2", Method::Network, [7; 32], None);
    let shown: Vec<_> = merger.identified().collect();
    assert_eq!(shown.len(), 1, "one key, one row");
    assert!(shown[0].public);
    // A friend's hidden entry and their public one: one candidate under the conversation, not public.
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW));
    merger.identify("pub1", Method::Network, [8; 32], Some("friend".into()));
    let friend = merger.candidates().iter().find(|c| c.conversation_id.as_deref() == Some("friend")).unwrap();
    assert_eq!(friend.sightings.len(), 2);
    assert!(!friend.public);
}

#[test]
fn callback_tags_count_only_without_a_presence_match() {
    let callback_secret = [9u8; 32];
    let callback = presence::tag(&callback_secret, window(NOW));
    let matcher = TagMatcher::new([("friend", &SECRET[..]), ("asker", &callback_secret[..])], NOW);
    let mut merger = Merger::new(matcher);
    let mut device = sighting(Method::Network, RouteMethod::Lan, "lan2", Some([1; 8]), NOW);
    device.callback_tags = vec![[0; 8], callback];
    merger.add_sighting(device.clone());
    assert_eq!(merger.candidates()[0].conversation_id.as_deref(), Some("asker"));
    device.presence_tag = Some(tag());
    merger.add_sighting(Sighting { seen_at: NOW + 1.0, ..device });
    assert_eq!(merger.candidates()[0].conversation_id.as_deref(), Some("friend"));
}

#[test]
fn racer_staggers_toward_better_routes() {
    let mut merger = Merger::new(matcher());
    merger.add_sighting(sighting(Method::Bluetooth, RouteMethod::Bluetooth, "bt1", Some(tag()), NOW));
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "lan1", Some(tag()), NOW));
    let mut friend_public = public("pub1", NOW);
    friend_public.presence_tag = None;
    merger.add_sighting(friend_public);
    merger.identify("pub1", Method::Network, [3; 32], Some("friend".into()));
    let mut racer = Racer::default();
    let attempts = racer.attempts(&merger.candidates()[0], merger.matcher(), NOW);
    let order: Vec<_> = attempts.iter().map(|a| (a.sighting.endpoint.as_str(), a.delay)).collect();
    assert_eq!(order, vec![("lan1", racer::DIAL_DELAY_LAN), ("bt1", racer::DIAL_DELAY_BLUETOOTH)]);
    assert!(racer::should_start(&attempts[1], RouteMethod::None));
    assert!(!racer::should_start(&attempts[1], RouteMethod::Lan));
    assert_eq!(racer::decision(RouteMethod::Lan, RouteMethod::None), Decision::Adopt);
    assert_eq!(racer::decision(RouteMethod::Internet, RouteMethod::Bluetooth), Decision::Upgrade);
    assert_eq!(racer::decision(RouteMethod::Bluetooth, RouteMethod::Internet), Decision::Close);
    assert_eq!(racer::decision(RouteMethod::Lan, RouteMethod::Lan), Decision::Close);
}

#[test]
fn a_failing_tag_backs_off_wherever_it_is_shown() {
    let mut merger = Merger::new(matcher());
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "relay1", Some(tag()), NOW));
    let mut racer = Racer::default();
    assert_eq!(racer.attempts(&merger.candidates()[0], merger.matcher(), NOW).len(), 1);
    racer.note_failed("relay1", Method::Network, "friend", NOW);
    assert_eq!(racer.next_backoff_end(NOW), Some(NOW + racer::ENDPOINT_BACKOFF_FIRST_SECONDS));
    // The relayer re-advertises the same tag under a new name: still backing off.
    merger.add_sighting(sighting(Method::Network, RouteMethod::Lan, "relay2", Some(tag()), NOW + 0.5));
    assert!(racer.attempts(&merger.candidates()[0], merger.matcher(), NOW + 0.5).is_empty());
    let later = NOW + racer::ENDPOINT_BACKOFF_FIRST_SECONDS;
    assert_eq!(racer.attempts(&merger.candidates()[0], merger.matcher(), later).len(), 2);
    racer.note_failed("relay2", Method::Network, "friend", later);
    assert_eq!(racer.next_backoff_end(later), Some(later + 2.0 * racer::ENDPOINT_BACKOFF_FIRST_SECONDS), "doubles");
    racer.note_succeeded("relay2", Method::Network, "friend");
    assert_eq!(racer.next_backoff_end(later), None);
}
