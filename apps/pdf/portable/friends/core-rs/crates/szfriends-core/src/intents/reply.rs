//! Replies (PROTOCOL.md § Replies and errors): exactly one per intent, `result` when it worked and `error` when it did
//! not, whose `message` is display-ready text for the person or null where the view has nothing useful to say.

use serde_json::{json, Map, Value};

use super::{IntentError, Wording};
use crate::presentation::Strings;

/// Codes worth trying again as they are (PROTOCOL.md's Retryable column).
pub fn retryable(code: &str) -> bool {
    matches!(
        code,
        "rate_limited" | "disk_full" | "link_offline" | "link_failed" | "internal" | "not_ready" | "connection_lost"
    )
}

/// The words for an error, written for the person who tried something.
pub fn error_message(error: &IntentError, strings: &Strings) -> Option<String> {
    let field = error.details.get("field").and_then(Value::as_str);
    match &error.wording {
        Wording::General => strings.error_message(error.code, &error.details),
        Wording::Join => {
            strings.join_error_message(error.code, field).or_else(|| strings.error_message(error.code, &error.details))
        }
        Wording::Devices(reason) => strings
            .devices_error_message(error.code, reason)
            .or_else(|| strings.error_message(error.code, &error.details)),
        Wording::ReceivedFolder => {
            let mut details = Map::new();
            details.insert("field".into(), json!("received_folder"));
            strings.error_message(error.code, &details)
        }
        Wording::Named(name) => {
            let mut details = Map::new();
            details.insert("name".into(), json!(name));
            strings.error_message(error.code, &details)
        }
    }
}

/// `{"type":"reply","re":…,"ok":true,"result":…}`; an empty result when there is nothing to return.
pub fn ok_frame(re: &str, result: Option<Value>) -> Value {
    json!({"type": "reply", "re": re, "ok": true, "result": result.unwrap_or_else(|| json!({}))})
}

/// `{"type":"reply","re":…,"ok":false,"error":{code, message, retryable, details}}`.
pub fn error_frame(re: &str, error: &IntentError, strings: &Strings) -> Value {
    json!({
        "type": "reply",
        "re": re,
        "ok": false,
        "error": {
            "code": error.code,
            "message": error_message(error, strings),
            "retryable": retryable(error.code),
            "details": error.details,
        },
    })
}
