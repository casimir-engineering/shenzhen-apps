//! The items behind the golden fixtures (`SZPItemsFor` and `SZPPreviewItems` in `SZFriendsPresentationWorld.m`):
//! messages, files and events as the helper's facts describe them, at Hong Kong wall-clock times.

use std::collections::HashMap;

use szfriends_core::presentation::mentions::mention_link;
use szfriends_core::presentation::{event, failure, ItemFacts, ItemKind, OutboxState, RouteMethod, TransferState};

use super::world::*;

pub fn message(id: &str, outgoing: bool, wall_clock: &str, text: &str, outbox: Option<OutboxState>) -> ItemFacts {
    ItemFacts {
        item_id: id.into(),
        kind: ItemKind::Message,
        outgoing,
        sent_at: hk(wall_clock),
        text: Some(text.into()),
        outbox_state: outbox,
        ..Default::default()
    }
}

pub fn transfer(id: &str, outgoing: bool, wall_clock: &str, name: &str, size: u64, state: TransferState) -> ItemFacts {
    let extension = name.rsplit_once('.').map(|(_, e)| e.to_owned());
    // What the helper derives from the name's extension (every fixture file is a PDF).
    let pdf = extension.as_deref().is_some_and(|e| e.eq_ignore_ascii_case("pdf"));
    ItemFacts {
        item_id: id.into(),
        transfer_id: Some(id.into()),
        kind: ItemKind::Transfer,
        outgoing,
        sent_at: hk(wall_clock),
        file_name: Some(name.into()),
        file_extension: extension,
        file_type_identifier: pdf.then(|| "com.adobe.pdf".into()),
        file_size: size,
        transfer_state: Some(state),
        ..Default::default()
    }
}

/// A preview in the helper's cache, named as the helper names them (random, never by the sender).
fn with_thumbnail(mut item: ItemFacts, name: &str, width: u32, height: u32, from_sender: bool) -> ItemFacts {
    item.thumbnail_path = Some(format!("/Users/raph/Library/Application Support/Shenzhen Friends/thumbnails/{name}"));
    item.thumbnail_width = width;
    item.thumbnail_height = height;
    item.thumbnail_from_sender = from_sender;
    item
}

pub fn event_item(id: &str, wall_clock: &str, kind: &str) -> ItemFacts {
    ItemFacts {
        item_id: id.into(),
        kind: ItemKind::Event,
        sent_at: hk(wall_clock),
        event_kind: Some(kind.into()),
        ..Default::default()
    }
}

fn daniel_guide() -> ItemFacts {
    let mut guide = transfer(
        "t_daniel_guide",
        false,
        "2026-10-12 11:05",
        "Enclosure assembly guide.pdf",
        3_120_000,
        TransferState::Received,
    );
    guide.accepted_automatically = true;
    guide.local_path =
        Some("/Users/raph/Library/Application Support/Shenzhen Friends/received/Enclosure assembly guide.pdf".into());
    guide
}

/// Daniel names people in every way a mention resolves for Raph: Mei, a friend, under Daniel's name for her; Leo,
/// whom Raph does not know; Raph himself; Lena, who asked Raph to be friends; Jonas, whom Raph blocked; and "Kenji"
/// under a key that is not Kenji's. Raph's reply names Priya.
fn daniel_items() -> Vec<ItemFacts> {
    let link = |name: &str, id: &str, k: &str| mention_link(name, id, &key(k)).unwrap();
    let (mei, leo, raph) = (
        link("Mei", "jasmine-street", KEY_MEI),
        link("Leo Park", "bonfire-otter", KEY_LEO),
        link("Raph", "cottage-violet", KEY_RAPH),
    );
    let (lena, jonas) = (link("Lena", "amber-falcon", KEY_LENA), link("Jonas", "copper-pebble", KEY_JONAS));
    let forged = link("Kenji", "cedar-lantern", KEY_FORGED);
    let priya = link("Priya Raman", "silver-ocean", KEY_PRIYA);
    vec![
        message(
            "m_d0a1",
            false,
            "2026-10-12 10:40",
            &format!("{mei} has the bracket drawing. Ask her for rev B."),
            None,
        ),
        message(
            "m_d0a2",
            false,
            "2026-10-12 10:41",
            &format!("{leo} can review the enclosure too. {raph} met him at the fair."),
            None,
        ),
        message("m_d0a3", false, "2026-10-12 10:42", &format!("{lena} and {jonas} asked about it as well."), None),
        message("m_d0a4", false, "2026-10-12 10:43", &format!("Or ask {forged}."), None),
        message(
            "m_d0a5",
            true,
            "2026-10-12 10:50",
            &format!("Thanks, I’ll ask {priya} too."),
            Some(OutboxState::Delivered),
        ),
    ]
}

pub fn items_for(conversation: &str) -> Vec<ItemFacts> {
    match conversation {
        "c_daniel" => daniel_items(),
        "c_mei" => {
            let mut receiving = transfer(
                "t_3e8b5d10",
                false,
                "2026-10-12 09:21",
                "Bracket drawing rev B.pdf",
                18_604_277,
                TransferState::Receiving,
            );
            receiving.bytes_done = 11_534_652; // 62.00 %
            receiving.bytes_per_second = 350_000.0;
            receiving.transfer_route = RouteMethod::Lan;
            receiving.accepted_automatically = true;
            let receiving = with_thumbnail(receiving, "5e0c2a9b71d84f36b2a1c09e8d7f4b63.png", 192, 136, true);
            let mut note = message(
                "m_5f2a90c1",
                true,
                "2026-10-12 09:14:22",
                "Here it is. Pages 3–5 changed.",
                Some(OutboxState::Delivered),
            );
            note.via_assistant = true;
            let mut contract = transfer(
                "t_91c4e2a7",
                true,
                "2026-10-12 09:14:40",
                "Supplier contract v3.pdf",
                2_431_029,
                TransferState::Delivered,
            );
            contract.via_assistant = true;
            let contract = with_thumbnail(contract, "a9c4e1f07b3d42d8915e6f0a2c7b8d14.png", 136, 192, false);
            vec![
                message("m_a4109f52", false, "2026-10-12 14:32:05", "Can you check pages 3–5 before Friday?", None),
                note,
                contract,
                message(
                    "m_77d0b3e4",
                    false,
                    "2026-10-12 09:20:40",
                    "Thanks. Here is my markup of the bracket drawing.",
                    None,
                ),
                receiving,
            ]
        }
        "c_kenji" => {
            let mut offer = transfer(
                "t_kenji_site",
                false,
                "2026-10-12 13:10",
                "Site photos.pdf",
                42_318_806,
                TransferState::WaitingForYou,
            );
            offer.bytes_per_second = 117_000.0; // measured over Bluetooth: about 6 minutes for 42.3 MB
            offer.transfer_route = RouteMethod::Bluetooth;
            let offer = with_thumbnail(offer, "0f7d3b9e2c5a4168a4e0b7c91d26f835.png", 136, 192, true);
            let mut note =
                message("m_1b7e44d9", false, "2026-10-12 13:09", "Photos from this morning's site visit.", None);
            note.via_assistant = true;
            vec![note, offer]
        }
        "c_priya" => {
            let mut expired = message(
                "m_9b31c7e5",
                true,
                "2026-09-04 10:15",
                "Are you free for the site visit on Thursday?",
                Some(OutboxState::Failed),
            );
            expired.failure_reason = Some(failure::NOT_DELIVERED_30_DAYS.into());
            let mut withdrawn =
                message("m_7a3e5b21", true, "2026-10-11 17:40", "The new delivery dates are on page 5.", None);
            withdrawn.cancelled = true;
            withdrawn.via_assistant = true;
            vec![
                event_item("e_3c90f1a2", "2026-09-02 16:20", event::NOW_FRIENDS),
                expired,
                withdrawn,
                message(
                    "m_c4d27a19",
                    true,
                    "2026-10-11 17:58",
                    "I've marked the new delivery dates on page 4.",
                    Some(OutboxState::Queued),
                ),
                message(
                    "m_0d1e2f30",
                    true,
                    "2026-10-11 18:02",
                    "Here's the latest contract.",
                    Some(OutboxState::Queued),
                ),
                // No preview: none came within two seconds when Raph sent it, so views draw the PDF icon.
                transfer(
                    "t_6a2f90b8",
                    true,
                    "2026-10-11 18:02:10",
                    "Supplier contract v3.pdf",
                    2_431_029,
                    TransferState::Queued,
                ),
            ]
        }
        _ => Vec::new(),
    }
}

pub fn preview_items() -> HashMap<String, ItemFacts> {
    let mut items: HashMap<String, ItemFacts> = HashMap::new();
    for conversation in ["c_mei", "c_kenji", "c_priya"] {
        for item in items_for(conversation) {
            items.insert(item.item_id.clone(), item);
        }
    }
    let guide = daniel_guide();
    items.insert(guide.item_id.clone(), guide);
    items.insert("e_tulip_friends".into(), event_item("e_tulip_friends", "2026-10-03 16:00", event::NOW_FRIENDS));
    items
}
