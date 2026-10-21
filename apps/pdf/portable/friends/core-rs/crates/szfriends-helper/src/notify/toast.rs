//! A Windows toast's XML (the ToastGeneric schema): built on every platform so its tests run everywhere; posted only
//! on Windows (`notify/windows.rs`). The click is `activationType="protocol"` with the conversation's URL as
//! `launch`, so Windows opens the app with it even when the helper is gone; the title and body are escaped, since a
//! friend's name or message is anything they typed.

use super::Request;

/// Windows caps a toast's tag and group at 64 characters.
const TAG_MAX: usize = 64;

/// XML's five escapes, and nothing a toast's text cannot hold: controls other than tab and newline are dropped.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' => out.push(c),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// The toast for one request.
pub fn toast_xml(request: &Request) -> String {
    format!(
        concat!(
            "<toast activationType=\"protocol\" launch=\"{launch}\" displayTimestamp=\"{time}\">",
            "<visual><binding template=\"ToastGeneric\"><text>{title}</text><text>{body}</text></binding></visual>",
            "</toast>"
        ),
        launch = escape(&request.open.url),
        time = escape(&request.time),
        title = escape(&request.title),
        body = escape(&request.body),
    )
}

/// The tag a toast is replaced or removed by: the request's key, cut to Windows' limit.
pub fn tag(key: &str) -> String {
    key.chars().take(TAG_MAX).collect()
}

/// The group a conversation's toasts share, so reading it removes them together.
pub fn group(thread: &str) -> String {
    thread.chars().take(TAG_MAX).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notify::{Open, Request};

    fn request(title: &str, body: &str) -> Request {
        Request {
            key: "message:i_81f2".into(),
            kind: "message",
            channel: "messages",
            conversation_id: Some("c_mei".into()),
            thread: "c_mei".into(),
            title: title.into(),
            body: body.into(),
            time: "2026-10-21T08:12:03Z".into(),
            reply: None,
            open: Open {
                url: "shenzhen3d://friends/conversation/c_mei".into(),
                app_id: "com.shenzhen3d.viewer".into(),
                app_path: None,
            },
        }
    }

    #[test]
    fn a_toast_opens_the_conversation_by_protocol() {
        let xml = toast_xml(&request("Mei", "Can you check the bracket?"));
        assert_eq!(
            xml,
            "<toast activationType=\"protocol\" launch=\"shenzhen3d://friends/conversation/c_mei\" \
             displayTimestamp=\"2026-10-21T08:12:03Z\"><visual><binding template=\"ToastGeneric\"><text>Mei</text>\
             <text>Can you check the bracket?</text></binding></visual></toast>"
        );
    }

    #[test]
    fn what_a_friend_typed_is_escaped() {
        let xml = toast_xml(&request("<Mei & \"Co\">", "</text><text>injected 'quote'\u{7}\nline two"));
        assert!(xml.contains("<text>&lt;Mei &amp; &quot;Co&quot;&gt;</text>"), "{xml}");
        assert!(xml.contains("<text>&lt;/text&gt;&lt;text&gt;injected &apos;quote&apos;\nline two</text>"), "{xml}");
        assert_eq!(xml.matches("<text>").count(), 2, "nothing a friend typed opens an element");
    }

    #[test]
    fn tags_and_groups_fit_windows_limits() {
        let long = format!("request:{}:12", "a".repeat(64));
        assert_eq!(tag(&long).chars().count(), 64);
        assert_eq!(tag("message:i_81f2"), "message:i_81f2");
        assert_eq!(group("c_mei"), "c_mei");
    }
}
