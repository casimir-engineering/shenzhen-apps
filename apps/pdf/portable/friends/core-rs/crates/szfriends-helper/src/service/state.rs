//! The service's state made, and each input it handles (mod.rs).

use super::*;

impl State {
    pub(super) fn new(identity: Identity, mut store: Store, input: Sender<Input>, busy: Arc<AtomicBool>) -> Self {
        let test_home = std::env::var_os(crate::state::ENV_STATE_DIR).is_some();
        let fast_setting = store.fast_transfers_enabled();
        let adapters = crate::nearby::adapters(store.state_dir(), test_home, nearby::sink(input.clone()));
        let nearby = nearby::Nearby::new(adapters, store.visibility_deadline());
        let mut capabilities = capabilities(nearby.has_adapter(szfriends_core::nearby::Method::Bluetooth));
        #[cfg(feature = "online")]
        let links = links::LinkShelf::default();
        #[cfg(feature = "online")]
        let online = online::OnlineRoutes::from_environment(
            &identity,
            &mut store,
            input.clone(),
            Box::new(links.clone()),
            nearby.policy.clone(),
        );
        #[cfg(not(feature = "online"))]
        let online = online::OnlineRoutes::from_environment(&identity, &mut store, input.clone());
        let devices = devices::DeviceArea::new(&identity, store.state_dir().join("received"));
        let responses = std::sync::Mutex::new(input.clone());
        let responder: crate::notify::Responder = Arc::new(move |response| {
            let _ = responses.lock().unwrap_or_else(|e| e.into_inner()).send(Input::Notify(response));
        });
        let notifier = crate::notify::platform_notifier(store.state_dir(), test_home, responder);
        let notify = notifications::NotifyArea::new(&store, test_home, notifier);
        // Links are made for the Friends host's pages, so only a helper that checks in offers them.
        if online.is_some() {
            capabilities.push("links".to_owned());
        }
        let fast_transfers =
            fast_setting && !(test_home && std::env::var_os(ENV_TEST_FAST_TRANSFERS).is_some_and(|v| v == "0"));
        let switched_off = |name: &str| test_home && std::env::var_os(name).is_some_and(|v| v == "0");
        let mut session_capabilities = szfriends_core::session::local_capabilities(fast_transfers);
        // ADR 0019: the Wi-Fi Direct boost, where this device can host or join a direct link.
        let boost = boost::BoostArea::new(store.state_dir(), test_home);
        let lanes = !(test_home && std::env::var_os(ENV_TEST_LANES).is_some_and(|v| v == "0"));
        if fast_transfers && lanes && boost.available() {
            session_capabilities |= szfriends_core::wire::consts::CAPABILITY_DIRECT_WIFI_BOOST;
        }
        if switched_off(ENV_TEST_AES_LANES) {
            session_capabilities &= !szfriends_core::wire::consts::CAPABILITY_AES_LANES;
        }
        if switched_off(ENV_TEST_COMPRESSED_PARTS) {
            use szfriends_core::wire::consts::{CAPABILITY_COMPRESSED_PARTS, CAPABILITY_LZ4_PARTS};
            session_capabilities &= !(CAPABILITY_COMPRESSED_PARTS | CAPABILITY_LZ4_PARTS);
        }
        Self {
            identity,
            store,
            clients: HashMap::new(),
            next_subscription: 0,
            input,
            busy,
            sessions: sessions::Sessions::default(),
            nearby,
            online,
            #[cfg(feature = "online")]
            links,
            #[cfg(feature = "online")]
            links_swept_at: 0.0,
            #[cfg(feature = "online")]
            link_receipts: HashMap::new(),
            #[cfg(feature = "online")]
            next_receipt: 0,
            capabilities,
            finishing: HashMap::new(),
            meter: Default::default(),
            copies_by_blocks: !(test_home && std::env::var_os(ENV_TEST_COPIES_BY_BLOCKS).is_some_and(|v| v == "0")),
            // The settings key `transfers.fast` (on unless it holds 0), read as the helper starts.
            session_capabilities,
            lanes,
            boost,
            route_rates: if test_home {
                route_rates(&std::env::var(ENV_TEST_ROUTE_RATES).unwrap_or_default())
            } else {
                HashMap::new()
            },
            route_silence: test_home.then(|| std::env::var_os(ENV_TEST_ROUTE_SILENCE).map(Into::into)).flatten(),
            devices,
            again: again::AgainArea::default(),
            pulls: pulls::PullArea::default(),
            notify,
            dirty: false,
            stopped: None,
        }
    }

    /// Marks the views for an update after the current input.
    pub fn changed(&mut self) {
        self.dirty = true;
    }

    pub(super) fn handle(&mut self, input: Input) -> bool {
        match input {
            Input::Connected(connection) => {
                if let Some(client) = connection.client() {
                    let audience = audience(&client, &self.capabilities);
                    let id = connection.id();
                    self.clients.insert(id, Client { connection, audience, subscriptions: HashMap::new() });
                }
            }
            Input::Intent(connection, frame, reply) => self.intent(&connection, &frame, reply),
            Input::Disconnected(id) => {
                self.clients.remove(&id);
                self.notify.disconnected(id);
            }
            Input::Notify(response) => {
                let _ = self.notification_response(response);
            }
            Input::System(event) => self.system_event(event),
            Input::Nearby(event) => self.nearby_event(event),
            Input::Link(event) => self.link_event(event),
            #[cfg(feature = "online")]
            Input::Online(event) => self.online_event(event),
            Input::Deferred(work) => work(self),
            Input::Shutdown(done) => {
                self.boost_quitting();
                drop(self.online.take());
                let _ = self.store.flush_progress();
                self.stop_nearby();
                self.close_all_sessions();
                self.stopped = Some(done);
                return false;
            }
        }
        true
    }

    pub(super) fn system_event(&mut self, event: SystemEvent) {
        match event {
            // Before sleep, received bytes are made durable at a verified offset; sessions end with the network.
            SystemEvent::Sleep => {
                let _ = self.store.flush_progress();
            }
            SystemEvent::Wake | SystemEvent::NetworkChanged => {
                if let Some(online) = &self.online {
                    online.network_changed();
                }
                self.restart_nearby_after_wake();
            }
        }
    }
}
