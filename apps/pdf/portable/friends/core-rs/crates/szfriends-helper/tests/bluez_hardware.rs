//! BlueZ on a Linux laptop with a radio (the `bluetooth` feature). Hardware tests: ignored by default, run with
//! `cargo test -p szfriends-helper --features bluetooth --test bluez_hardware -- --ignored` on a laptop whose
//! Bluetooth is on. They change no setting: a radio that is off is reported as off and the test says so.

#[cfg(all(target_os = "linux", feature = "bluetooth"))]
mod hardware {
    use std::sync::mpsc::channel;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use szfriends_helper::nearby::bluez::BlueZ;
    use szfriends_helper::nearby::radio::{Power, Radio, RadioEvent, RadioReports};
    use szfriends_helper::nearby::{Event, Sink};

    #[test]
    #[ignore = "hardware: needs a Bluetooth radio"]
    fn the_radio_reports_its_power_and_publishes_a_channel() {
        let (sender, events) = channel();
        let sender = Mutex::new(sender);
        let sink: Arc<Sink> = Arc::new(Box::new(move |event: Event| {
            let _ = sender.lock().unwrap().send(event);
        }));
        let mut radio = BlueZ::new();
        radio.power_up(RadioReports::new(sink));
        let power = loop {
            match events.recv_timeout(Duration::from_secs(10)).expect("a power report") {
                Event::Radio(RadioEvent::Power(power)) => break power,
                _ => continue,
            }
        };
        if power != Power::On {
            eprintln!("the radio is {power:?}: nothing more to check");
            return;
        }
        radio.publish_channel(false);
        let psm = loop {
            match events.recv_timeout(Duration::from_secs(10)).expect("a channel") {
                Event::Radio(RadioEvent::Published { psm, .. }) => break psm,
                _ => continue,
            }
        };
        assert!((0x0080..=0x00FF).contains(&psm), "an LE dynamic PSM: {psm:#x}");
        radio.unpublish_channel(psm);
        radio.power_down();
    }
}
