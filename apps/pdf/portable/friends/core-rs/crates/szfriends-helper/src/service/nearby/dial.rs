//! Whom to connect to, and how (`SZFriendsNearbyService+Dial.m`; ADR 0004 § Route racing, § Add by ID nearby).
//!
//! One pass over the merger's candidates decides every attempt: IK to friends seen by tag on all their routes,
//! staggered toward the faster ones; a browse-only XX to each public entry nobody has identified; a full XX to deliver
//! a nearby friend request; IK probes at unrecognised devices for a person whose tags we cannot match but who has
//! something waiting; and the NN Add by ID request to every device once a day. Nothing here sends application data; a
//! live session does that.
//!
//! Outbound first (ADR 0015 § 15): a computer that cannot listen also probes for the people whose answer it waits
//! for (a request it sent nearby), since their answer can only arrive over a session it dials itself.

use std::collections::HashSet;

use szfriends_core::nearby::callbacks::{callback_day, window, window_end};
use szfriends_core::nearby::limits::*;
use szfriends_core::nearby::merger::Candidate;
use szfriends_core::nearby::racer::should_start;
use szfriends_core::nearby::{is_better, Method};
use szfriends_core::session::HandshakeOptions;
use szfriends_core::store::{unix_now, OutboxEvent, OutboxState, Person, Relation};
use szfriends_core::wire::{Fields, Pattern, RouteMethod};

use super::{DialPlan, Purpose};
use crate::service::sessions::deliverable;
use crate::service::State;

fn dial_key(purpose: Purpose, method: Method, endpoint: &str) -> String {
    format!("{purpose:?}|{}|{endpoint}", method as u8)
}

fn backoff(count: u32) -> f64 {
    (DIAL_BACKOFF_FIRST_SECONDS * 2f64.powi(count.saturating_sub(1).min(10) as i32)).min(DIAL_BACKOFF_MAX_SECONDS)
}

impl State {
    /// IK toward a person on `route`, presenting their Add by ID token until our ACCEPT reaches them.
    pub(crate) fn ik_options(&self, person: &Person, route: RouteMethod) -> HandshakeOptions {
        let mut options = HandshakeOptions::new(Pattern::IK, route);
        options.remote_static = person.static_key;
        options.expected_identity = person.identity_key;
        options.request_token = person.callback_token.map(|t| t.to_vec());
        options
    }

    pub(super) fn plan(
        &self,
        candidate_sighting: &szfriends_core::nearby::Sighting,
        purpose: Purpose,
        options: HandshakeOptions,
    ) -> DialPlan {
        DialPlan {
            method: candidate_sighting.method,
            endpoint: candidate_sighting.endpoint.clone(),
            route: candidate_sighting.route,
            purpose,
            options,
            conversation: None,
            probe: false,
            request_token: None,
            attempt_key: None,
            dial_key: dial_key(purpose, candidate_sighting.method, &candidate_sighting.endpoint),
        }
    }

    /// Something waits for this person: an outbox entry they may receive now, or a file asked again of them.
    pub(crate) fn has_deliverable(&self, person: &Person) -> bool {
        self.store.pending_outbox(&person.conversation_id).unwrap_or_default().iter().any(|e| deliverable(e, person))
            || (person.relation == Relation::Friend && self.has_asked_again(&person.conversation_id))
    }

    /// One pass over every candidate and everything waiting.
    pub(crate) fn reconsider(&mut self) {
        if self.nearby.shut_down || self.nearby.adapters.is_empty() {
            return;
        }
        let mut seen = HashSet::new();
        let candidates: Vec<Candidate> = self.nearby.merger.candidates().to_vec();
        for candidate in candidates {
            // Another device of ours (own.rs), one we removed (removed.rs), a friend's other computer.
            if self.reach_own_device_candidate(&candidate)
                || self.reach_removed_device_candidate(&candidate)
                || self.reach_friend_device_candidate(&candidate)
            {
                continue;
            }
            let mut conversation = candidate.conversation_id.clone();
            if conversation.is_none() {
                if let Some(key) = candidate.identity_key {
                    // Browsed as a stranger, in the list since: the merger learns whose entry it is.
                    let known = self.store.person_with_identity_key(&key).ok().flatten();
                    if let Some(known) = known.filter(|p| !matches!(p.relation, Relation::Blocked | Relation::Removed))
                    {
                        conversation = Some(known.conversation_id.clone());
                        for sighting in &candidate.sightings {
                            let id = Some(known.conversation_id.clone());
                            self.nearby.merger.identify(&sighting.endpoint, sighting.method, key, id);
                        }
                    }
                }
            }
            let Some(conversation) = conversation else {
                if candidate.public && !candidate.identified() {
                    self.browse_candidate(&candidate);
                }
                continue;
            };
            let Some(person) = self.store.person_with_conversation(&conversation).ok().flatten() else { continue };
            seen.insert(conversation);
            self.reach_person(&person, &candidate);
        }
        self.probe_for_people_not_seen(&seen);
        self.offer_requests_by_id();
        self.probe_for_own_devices();
        self.offer_join_nearby();
        #[cfg(feature = "online")]
        self.offer_join_online();
    }

    fn reach_person(&mut self, person: &Person, candidate: &Candidate) {
        let conversation = &person.conversation_id;
        let live = self.sessions.live_for(conversation);
        let deliverable = self.has_deliverable(person);
        match person.relation {
            Relation::Blocked | Relation::IncomingRequest => return,
            Relation::OutgoingRequest => {
                if live.is_some() || person.identity_key.is_none() || !deliverable || !self.may_dial(conversation) {
                    return;
                }
                let Some(sighting) = candidate.sightings.iter().find(|s| s.public).cloned() else { return };
                let mut options = HandshakeOptions::new(Pattern::XX, sighting.route);
                // The person whose entry we browsed, or nobody: anyone else is refused before message 3.
                options.expected_identity = person.identity_key;
                let mut plan = self.plan(&sighting, Purpose::Request, options);
                plan.conversation = Some(conversation.clone());
                if self.dial(plan, 0.0) {
                    self.mark_connecting(conversation);
                }
                return;
            }
            Relation::Removed if !deliverable => return,
            Relation::Removed | Relation::Friend => {}
        }
        if person.static_key.is_none() || person.identity_key.is_none() || !self.may_dial(conversation) {
            return;
        }
        let current = live.map_or(RouteMethod::None, |id| self.sessions.map[&id].channel.initiator_route());
        let now = unix_now();
        let attempts = self.nearby.racer.attempts(candidate, self.nearby.merger.matcher(), now);
        if attempts.is_empty() && live.is_none() && deliverable {
            // Every route to them is backing off: look again when the first backoff ends. A sooner reconsider would
            // otherwise take the place of the one the failure asked for, and nothing would dial them until the next
            // window (a removed friend's answer to their Add by ID waited out the test's half minute).
            if let Some(end) = self.nearby.racer.next_backoff_end(now) {
                self.schedule_reconsider_after(end - now);
            }
        }
        let mut started = false;
        for attempt in attempts {
            if !should_start(&attempt, current) {
                continue;
            }
            let options = self.ik_options(person, attempt.sighting.route);
            let mut plan = self.plan(&attempt.sighting, Purpose::Friend, options);
            plan.conversation = Some(conversation.clone());
            started |= self.dial(plan, attempt.delay);
        }
        if started && live.is_none() && deliverable {
            self.mark_connecting(conversation);
        }
    }

    /// IK at each unrecognised device, once per device and window, for people with something to deliver whose tags
    /// we cannot match. A wrong device cannot decrypt IK's first message and learns nothing.
    fn probe_for_people_not_seen(&mut self, seen: &HashSet<String>) {
        let devices: Vec<Candidate> = self.nearby.merger.unmatched().to_vec();
        if devices.is_empty() {
            return;
        }
        let (now, current) = (unix_now(), window(unix_now()));
        let listening = self.nearby.listening();
        for person in self.store.people_by_latest_interaction().unwrap_or_default() {
            let conversation = person.conversation_id.clone();
            let awaited = !listening && person.relation == Relation::OutgoingRequest && person.request_found_nearby;
            let reachable = matches!(person.relation, Relation::Friend | Relation::Removed) || awaited;
            if !reachable
                || seen.contains(&conversation)
                || person.static_key.is_none()
                || person.identity_key.is_none()
                || self.sessions.live_for(&conversation).is_some()
                || !(awaited || self.has_deliverable(&person))
            {
                continue;
            }
            let mut started = false;
            for device in &devices {
                let Some(sighting) = device.sightings.first().filter(|s| !s.public).cloned() else { continue };
                let key = format!("probe|{conversation}|{}|{current}", sighting.endpoint);
                if self.nearby.attempts.contains_key(&key) {
                    continue;
                }
                self.nearby.attempts.insert(key, window_end(now));
                let options = self.ik_options(&person, sighting.route);
                let mut plan = self.plan(&sighting, Purpose::Friend, options);
                plan.conversation = Some(conversation.clone());
                plan.probe = true;
                started |= self.dial(plan, 0.0);
            }
            if started {
                self.mark_connecting(&conversation);
            }
        }
    }

    /// Who is behind a public entry? A browse-only XX returns their key and profile and stops before revealing us.
    fn browse_candidate(&mut self, candidate: &Candidate) {
        let now = unix_now();
        for sighting in candidate.sightings.iter().filter(|s| s.public) {
            let key = format!("browse|{}", sighting.endpoint);
            if self.nearby.attempts.get(&key).is_some_and(|until| *until > now) {
                continue;
            }
            self.nearby.attempts.insert(key, f64::MAX); // until it answers or fails
            let mut options = HandshakeOptions::new(Pattern::XX, sighting.route);
            options.browse_only = true;
            let plan = self.plan(sighting, Purpose::Browse, options);
            self.dial(plan, 0.0);
        }
    }

    pub(crate) fn browse_failed(&mut self, endpoint: &str) {
        self.nearby.attempts.insert(format!("browse|{endpoint}"), unix_now() + BROWSE_RETRY_SECONDS);
        self.schedule_reconsider_after(BROWSE_RETRY_SECONDS);
    }

    /// A browse returned this person's key and public profile: the merger learns whose entry it is.
    pub(crate) fn browsed_profile(
        &mut self,
        method: Method,
        endpoint: &str,
        key: [u8; 32],
        static_key: Option<[u8; 32]>,
        mut fields: Fields,
    ) {
        if key == self.identity.public_key() {
            return;
        }
        fields.remove(&szfriends_core::wire::tag::DATA); // nothing decodes a stranger's photo, so nothing keeps it
        self.nearby.public_profiles.insert(key, (fields, static_key));
        let person = self.store.person_with_identity_key(&key).ok().flatten();
        if person.as_ref().is_some_and(|p| p.relation == Relation::Blocked) {
            return;
        }
        // A removed person is identified like a stranger, so Nearby offers a new request.
        let conversation = person.filter(|p| p.relation != Relation::Removed).map(|p| p.conversation_id);
        self.nearby.merger.identify(endpoint, method, key, conversation);
        self.schedule_reconsider();
        self.changed();
    }

    /// Each pending Add by ID goes to every device we cannot recognise, hidden or public, once per device per day of
    /// the request, carrying that day's callback secret; every device answers alike.
    fn offer_requests_by_id(&mut self) {
        let now = unix_now();
        let requests = self.store.pending_id_requests(now);
        if requests.is_empty() {
            return;
        }
        let mut devices: Vec<Candidate> = self.nearby.merger.unmatched().to_vec();
        devices.extend(
            self.nearby.merger.candidates().iter().filter(|c| c.conversation_id.is_none() && c.public).cloned(),
        );
        for request in requests {
            let day = callback_day(request.created_at, now);
            let day_end = request.created_at + (day + 1) as f64 * CALLBACK_DAY_SECONDS;
            for device in &devices {
                let Some(sighting) = device.sightings.first().cloned() else { continue };
                let key = format!("byid|{}|{}|{day}", hex::encode(request.request_token), sighting.endpoint);
                if self.nearby.attempts.contains_key(&key) {
                    continue;
                }
                self.nearby.attempts.insert(key.clone(), day_end);
                // NN carries the token inside REQUEST_BY_ID, never in the handshake.
                let options = HandshakeOptions::new(Pattern::NN, sighting.route);
                let mut plan = self.plan(&sighting, Purpose::ById, options);
                plan.request_token = Some(request.request_token);
                plan.attempt_key = Some(key);
                self.dial(plan, 0.0);
            }
        }
    }

    pub(crate) fn by_id_attempt_failed(&mut self, key: &str) {
        self.nearby.attempts.insert(key.to_owned(), unix_now() + BY_ID_RETRY_SECONDS);
        self.schedule_reconsider_after(BY_ID_RETRY_SECONDS);
    }

    /// Stages a dial after `delay`; `false` when one for that purpose and endpoint already runs.
    pub(super) fn dial(&mut self, plan: DialPlan, delay: f64) -> bool {
        if self.nearby.dialing.contains(&plan.dial_key) || !self.nearby.has_adapter(plan.method) {
            return false;
        }
        self.nearby.dialing.insert(plan.dial_key.clone());
        self.nearby.staged.push((unix_now() + delay, plan));
        true
    }

    /// Dials whose stagger has passed, asked again first: a faster session may have won meanwhile.
    pub(crate) fn start_staged_dials(&mut self, now: f64) {
        let (due, waiting): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.nearby.staged).into_iter().partition(|(at, _)| *at <= now);
        self.nearby.staged = waiting;
        for (_, plan) in due {
            let live = match plan.purpose {
                Purpose::Friend => plan.conversation.as_deref().and_then(|c| self.sessions.live_for(c)),
                // Another of our devices: the session carrying our sync with it.
                Purpose::OwnDevice => plan.options.expected_identity.and_then(|d| self.own_device_live_link(&d)),
                _ => None,
            };
            let pointless =
                live.is_some_and(|id| !is_better(plan.route, self.sessions.map[&id].channel.initiator_route()));
            if self.nearby.shut_down || pointless {
                self.nearby.dialing.remove(&plan.dial_key);
                continue;
            }
            let dial = self.nearby.next_dial_id();
            let adapter = self.nearby.adapters.iter_mut().find(|a| a.method() == plan.method);
            let started = adapter.is_some_and(|a| a.dial(&plan.endpoint, dial));
            if started {
                self.nearby.dials.insert(dial, plan);
            } else {
                self.nearby.dialing.remove(&plan.dial_key);
                self.dial_failed(&plan);
            }
        }
    }

    /// Unreachable endpoints are normal (a device that just left); only a person's own attempts back off.
    pub(crate) fn dial_failed(&mut self, plan: &DialPlan) {
        match (&plan.purpose, &plan.attempt_key, &plan.conversation) {
            (Purpose::Browse, _, _) => self.browse_failed(&plan.endpoint),
            (_, Some(key), _) => self.by_id_attempt_failed(key),
            (Purpose::Friend, None, Some(conversation)) => {
                if !plan.probe {
                    self.note_failure(conversation, None);
                }
                self.nearby.racer.note_failed(&plan.endpoint, plan.method, conversation, unix_now());
            }
            (Purpose::OwnDevice, None, Some(name)) => {
                self.nearby.racer.note_failed(&plan.endpoint, plan.method, name, unix_now());
            }
            _ => {}
        }
    }

    pub(crate) fn may_dial(&self, conversation: &str) -> bool {
        self.nearby.retry_after.get(conversation).is_none_or(|after| *after <= unix_now())
    }

    /// A failed attempt or an ended session backs the person off; a session that lasted starts afresh.
    pub(crate) fn note_failure(&mut self, conversation: &str, live_at: Option<f64>) {
        let now = unix_now();
        if live_at.is_some_and(|at| now - at >= HEALTHY_SESSION_SECONDS) {
            self.nearby.failures.remove(conversation);
        }
        let count = self.nearby.failures.entry(conversation.to_owned()).or_insert(0);
        *count += 1;
        let delay = backoff(*count);
        self.nearby.retry_after.insert(conversation.to_owned(), now + delay);
        self.schedule_reconsider_after(delay);
    }

    /// The person's entries say Connecting while a dial is under way, and go back to Queued if none connects.
    fn mark_connecting(&mut self, conversation: &str) {
        let Some(person) = self.store.person_with_conversation(conversation).ok().flatten() else { return };
        let mut marked = false;
        for entry in self.store.pending_outbox(conversation).unwrap_or_default() {
            if entry.state == OutboxState::Queued && deliverable(&entry, &person) {
                let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::RouteAvailable);
                marked = true;
            }
        }
        if marked {
            self.nearby.connecting.insert(conversation.to_owned(), unix_now() + CONNECTING_TIMEOUT_SECONDS);
            self.changed();
        }
    }

    pub(crate) fn connecting_timed_out(&mut self, now: f64) {
        let due: Vec<String> =
            self.nearby.connecting.iter().filter(|(_, at)| **at <= now).map(|(c, _)| c.clone()).collect();
        for conversation in due {
            self.nearby.connecting.remove(&conversation);
            if self.sessions.live_for(&conversation).is_some() {
                continue;
            }
            for entry in self.store.pending_outbox(&conversation).unwrap_or_default() {
                if entry.state == OutboxState::Connecting {
                    let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::SessionLost);
                    self.changed();
                }
            }
        }
    }
}
