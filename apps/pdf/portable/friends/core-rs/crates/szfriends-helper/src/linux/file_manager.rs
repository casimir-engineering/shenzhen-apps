//! The freedesktop file manager interface (`org.freedesktop.FileManager1`), which Files, Dolphin, Nemo, Caja and
//! Thunar answer on the session bus: Show in Files opens the folder with the file selected. Each URI is one string
//! in the call, whatever it contains; `dbus-send`'s `array:string:` syntax would split a name at its commas.

use super::dbus::{Bus, Error};
use super::marshal::Value;

pub const NAME: &str = "org.freedesktop.FileManager1";
pub const PATH: &str = "/org/freedesktop/FileManager1";

/// Asks the file manager to show `uris` (`file:` URIs) selected; an error when none answers on this bus.
pub fn show_items(bus: &mut Bus, uris: &[String]) -> Result<(), Error> {
    let items = Value::Array("s".into(), uris.iter().map(|uri| Value::Str(uri.clone())).collect());
    // The second argument is a startup notification id; none, as the call does not start an app of ours.
    bus.call(NAME, PATH, NAME, "ShowItems", &[items, Value::Str(String::new())]).map(|_| ())
}
