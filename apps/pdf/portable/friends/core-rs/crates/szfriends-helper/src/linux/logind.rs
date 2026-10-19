//! Sleep and wake from logind (ADR 0015 § 16): its `PrepareForSleep` signal on the system bus, `true` before the
//! system sleeps and `false` after it wakes. NetworkManager and an inhibitor lock are not needed for this.

use super::dbus::{Bus, Error};
use super::marshal::Value;

const INTERFACE: &str = "org.freedesktop.login1.Manager";
const MEMBER: &str = "PrepareForSleep";
/// The well-known name the signal must come from on the system bus; the bus fills in the sender, so no other
/// process can forge it.
pub const LOGIND: &str = "org.freedesktop.login1";

/// Calls `on_sleep(true)` before each sleep and `on_sleep(false)` after each wake, until the bus fails. `sender`
/// limits the signals to logind's (`None` in tests, where a test process sends them).
pub fn watch(mut bus: Bus, sender: Option<&str>, on_sleep: impl Fn(bool)) -> Result<(), Error> {
    let mut rule = format!("type='signal',interface='{INTERFACE}',member='{MEMBER}',path='/org/freedesktop/login1'");
    if let Some(sender) = sender {
        rule.push_str(&format!(",sender='{sender}'"));
    }
    bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", &[Value::Str(rule)])?;
    bus.set_timeout(None)?;
    loop {
        let message = bus.next_message()?;
        if message.is_signal(INTERFACE, MEMBER) {
            if let Some(Value::Bool(going_to_sleep)) = message.body.first() {
                on_sleep(*going_to_sleep);
            }
        }
    }
}
