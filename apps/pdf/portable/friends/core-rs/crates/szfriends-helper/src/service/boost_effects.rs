//! What a boost asks of this helper (boost.rs): each effect of the negotiation carried out, the link hosted, the
//! direct lane dialed, and the way back to the Wi-Fi network applied.

use super::*;

impl State {
    // ----- effects -----

    /// Runs `step` on the group's boost, then everything it asks for.
    pub(super) fn with_boost(&mut self, head: u64, step: impl FnOnce(&mut Boost, Duration)) {
        let now = monotonic_now();
        let Some(live) = self.boost.boosts.get_mut(&head) else { return };
        step(&mut live.boost, now);
        let effects = live.boost.take_effects();
        let transfer = live.boost.transfer().to_owned();
        let shown = !effects.is_empty();
        for effect in effects {
            self.boost_effect(head, &transfer, effect);
        }
        if shown {
            self.changed();
        }
    }

    pub(super) fn boost_effect(&mut self, head: u64, transfer: &[u8; 16], effect: Effect) {
        let Some(platform) = self.boost.platform.clone() else { return };
        match effect {
            Effect::Send(message) => {
                self.send_on(head, &boost::encode(transfer, &message));
            }
            Effect::Ask(_) | Effect::Unask => {} // the row reads the phase (boost_facts)
            Effect::Host(link) => {
                let input = self.input.clone();
                platform.host(
                    &link,
                    Box::new(move |result| {
                        let _ = input.send(Input::Deferred(Box::new(move |state| state.boost_hosted(head, result))));
                    }),
                );
            }
            Effect::Join(link) => {
                let connectivity = platform.connectivity();
                let saved = Saved {
                    network: platform.current_network(),
                    network_name: connectivity.wifi_name,
                    joined: link.network.clone(),
                    left_at: unix_now(),
                };
                self.boost.rejoin.leaving(saved);
                self.apply_rejoin();
                if let Some(live) = self.boost.boosts.get(&head) {
                    self.boost.after = Some((live.transfer.clone(), BoostStage::None));
                }
                let input = self.input.clone();
                platform.join(
                    &link,
                    Box::new(move |joined| {
                        let _ = input.send(Input::Deferred(Box::new(move |state| {
                            state.with_boost(
                                head,
                                |boost, now| if joined { boost.joined(now) } else { boost.failed(now) },
                            );
                        })));
                    }),
                );
            }
            Effect::Dial { address, port } => self.dial_direct_lane(head, platform.dial_address(address), port),
            Effect::AllowDirectLane(allowed) => {
                if let Some(schedule) = self.sessions.groups.schedules.get_mut(&head) {
                    schedule.scheduler.allow_direct_wifi(allowed);
                }
                if !allowed {
                    if let Some(lane) = self.boost.boosts.get_mut(&head).and_then(|l| l.lane.take()) {
                        self.close(lane, CloseReason::Normal);
                    }
                }
            }
            Effect::StopHosting => {
                if let Some(stop) = self.boost.boosts.get_mut(&head).and_then(|l| l.listener.take()) {
                    stop.store(true, Ordering::SeqCst);
                }
                platform.stop_hosting();
            }
            Effect::LeaveJoined => {
                if let Some(live) = self.boost.boosts.get(&head) {
                    self.boost.after = Some((live.transfer.clone(), BoostStage::Rejoining));
                }
                self.boost.rejoin.come_back(monotonic_now());
                self.apply_rejoin();
            }
        }
    }

    /// The platform hosts: open the boost's lane listener on the link, then tell the joining side where.
    pub(super) fn boost_hosted(&mut self, head: u64, result: Result<IpAddr, String>) {
        let Some(platform) = self.boost.platform.clone() else { return };
        let address = match result {
            Ok(address) => address,
            Err(why) => {
                log!("direct Wi-Fi: could not host: {why}");
                return self.with_boost(head, |boost, now| boost.failed(now));
            }
        };
        let listener = match TcpListener::bind(SocketAddr::new(platform.listen_address(address), 0)) {
            Ok(listener) => listener,
            Err(error) => {
                log!("direct Wi-Fi: no listener on the link: {error}");
                return self.with_boost(head, |boost, now| boost.failed(now));
            }
        };
        let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
        let stop = Arc::new(AtomicBool::new(false));
        spawn_listener(listener, stop.clone(), self.input.clone());
        if let Some(live) = self.boost.boosts.get_mut(&head) {
            live.listener = Some(stop);
        }
        self.with_boost(head, |boost, now| boost.hosted(address, port, now));
    }

    /// The joining side dials the host's listener: an ordinary lane of the group, route peer-to-peer Wi-Fi.
    pub(super) fn dial_direct_lane(&mut self, head: u64, address: IpAddr, port: u16) {
        let Some(session) = self.sessions.map.get(&head) else { return };
        let (Some(conversation), Some(remote_static)) =
            (session.conversation.clone(), session.channel.remote_static().copied())
        else {
            return;
        };
        let aes = session.channel.aes_lanes();
        let Some(person) = self.store.person_with_conversation(&conversation).ok().flatten() else { return };
        let provisional = self.sessions.groups.provisional();
        let Some(group) = self.sessions.groups.by_head.get_mut(&head) else { return };
        let identity = *group.lanes.identity();
        let Some((_, token)) = group.lanes.reserve(provisional, RouteMethod::PeerToPeerWifi) else {
            return self.with_boost(head, |boost, now| boost.failed(now));
        };
        let mut options = self.ik_options(&person, RouteMethod::PeerToPeerWifi);
        options.remote_static = Some(remote_static);
        options.expected_identity = Some(identity);
        options.request_token = None;
        options.lane = Some(token);
        if aes {
            options.cipher = szfriends_core::wire::NoiseCipher::AesGcm;
        }
        let endpoint = SocketAddr::new(address, port).to_string();
        let plan = DialPlan {
            method: Method::Network,
            endpoint: endpoint.clone(),
            route: RouteMethod::PeerToPeerWifi,
            purpose: Purpose::Lane,
            options,
            conversation: None,
            probe: false,
            request_token: None,
            attempt_key: None,
            dial_key: format!("boost|{head}|{endpoint}"),
            lane: Some((head, provisional)),
        };
        self.sessions.groups.head_of.insert(provisional, head);
        let dial = self.nearby.next_dial_id();
        self.nearby.dialing.insert(plan.dial_key.clone());
        self.nearby.dials.insert(dial, plan);
        let input = self.input.clone();
        let target = SocketAddr::new(address, port);
        std::thread::spawn(move || {
            let stream = std::net::TcpStream::connect_timeout(&target, Duration::from_secs(5)).ok();
            let _ = input.send(Input::Nearby(Event::Dialed { dial, stream: stream.map(Into::into) }));
        });
    }

    // ----- the way back -----

    pub(super) fn apply_rejoin(&mut self) {
        for effect in self.boost.rejoin.take_effects() {
            let platform = self.boost.platform.clone();
            match effect {
                RejoinEffect::Write(saved) => {
                    let bytes = serde_json::to_vec(&saved.to_json()).unwrap_or_default();
                    let temporary = self.boost.record.with_extension("json.new");
                    let written = std::fs::write(&temporary, bytes)
                        .and_then(|()| std::fs::rename(&temporary, &self.boost.record));
                    if let Err(error) = written {
                        log!("direct Wi-Fi: the network to come back to was not written down: {error}");
                    }
                }
                RejoinEffect::Rejoin { network, joined } => {
                    let Some(platform) = platform else { continue };
                    let input = self.input.clone();
                    platform.rejoin(
                        network.as_deref(),
                        &joined,
                        Box::new(move |ok| {
                            let _ = input.send(Input::Deferred(Box::new(move |state| {
                                state.boost.rejoin.rejoined(ok, monotonic_now());
                                state.apply_rejoin();
                            })));
                        }),
                    );
                }
                RejoinEffect::CheckOnline => {
                    let Some(platform) = platform else { continue };
                    let input = self.input.clone();
                    platform.online(Box::new(move |online| {
                        let _ = input.send(Input::Deferred(Box::new(move |state| {
                            state.boost.rejoin.online(online, monotonic_now());
                            state.apply_rejoin();
                        })));
                    }));
                }
                RejoinEffect::Forget => {
                    let _ = std::fs::remove_file(&self.boost.record);
                    if let Some((_, stage)) = &mut self.boost.after {
                        if *stage == BoostStage::Rejoining {
                            *stage = BoostStage::None;
                        }
                    }
                    self.changed();
                }
                RejoinEffect::Tell { network_name } => {
                    log!("direct Wi-Fi: did not get back on its network by itself");
                    if let Some((_, stage)) = &mut self.boost.after {
                        *stage = BoostStage::RejoinFailed;
                    }
                    self.boost.failed_name = network_name;
                    self.changed();
                }
            }
        }
    }
}
