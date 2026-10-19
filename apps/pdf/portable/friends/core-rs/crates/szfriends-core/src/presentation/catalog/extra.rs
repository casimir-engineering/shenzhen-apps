//! The English catalog: mentions (`SZFriendsCatalogMentions.m`), links (`SZFriendsCatalogLinks.m`) and joining a
//! profile from a new computer (`SZFriendsCatalogJoin.m`). A stranger named in a mention is always called by the name
//! the sender wrote, never by an ID. Joining has two readers: the person on a computer that already has the profile,
//! and the same person on the new computer.

pub(super) const MENTIONS: &[(&str, &str)] = &[
    // A mention's tooltip: who this is to the reader, before they click.
    ("mention.tooltip.friend", "Open your chat with {first}"),
    ("mention.tooltip.stranger", "{name} isn’t your friend yet"),
    ("mention.tooltip.requested", "You asked {name} to be friends"),
    ("mention.tooltip.asked", "{name} wants to be friends"),
    ("mention.tooltip.blocked", "You blocked {name}"),
    ("mention.tooltip.moved", "This link no longer matches {name}"),
    // The card a click on a stranger's mention opens: their name, their ID, and what the reader can do.
    ("mention.card.id", "Friends ID {id}"),
    ("mention.card.requested", "Request sent"),
    ("mention.card.asked", "Wants to be friends"),
    ("mention.card.blocked", "Blocked"),
    // The Friends host says the ID now belongs to another key: Add would reach someone else, so it is not offered.
    ("mention.card.moved", "This link no longer matches {name}: {id} belongs to someone else now."),
    ("mention.action.add", "Add"),
    // Under the @ picker, for the person writing: what the friend they are writing to can do with the name.
    (
        "mention.note",
        "{first} can click the name to open their chat with that person, or to add them if they aren’t friends yet.",
    ),
    ("composer.hint.mention", "Mention"),
    (
        "add_from_mention.sent",
        "Request sent to {name}. They’ll get it as soon as Friends reaches them, and you’ll be friends once they \
         accept.",
    ),
    (
        "add_from_mention.sent.online",
        "Request sent to {name}. They’ll get it while {apps} is open for both of you, and you’ll be friends once they \
         accept.",
    ),
    ("error.mention_mismatch", "This link no longer matches that person, so no request was sent."),
    ("error.mention_mismatch.name", "This link no longer matches {name}, so no request was sent."),
];

pub(super) const LINKS: &[(&str, &str)] = &[
    // "Your links", in the profile.
    ("links.title", "Your links"),
    ("links.friend.label", "Your friend link"),
    (
        "links.friend.note",
        "Whoever opens it can add you without waiting for you to accept. Reset it if it reached someone it shouldn’t \
         have.",
    ),
    ("links.friend.reset", "Reset link"),
    ("links.friend.reset.confirm.title", "Reset your friend link?"),
    ("links.friend.reset.confirm.body", "The link you shared stops working. Friends you already have stay friends."),
    ("links.friend.reset.confirm.button", "Reset link"),
    ("links.downloads.label", "Download links"),
    ("links.downloads.empty", "Download links you copy show here, with how many times each was downloaded."),
    ("links.downloads.none", "No downloads yet"),
    ("links.downloads.count.one", "1 download"),
    ("links.downloads.count.other", "{count} downloads"),
    ("links.expires.today", "Expires today"),
    ("links.expires.tomorrow", "Expires tomorrow"),
    ("links.expires.days.one", "Expires in 1 day"),
    ("links.expires.days.other", "Expires in {count} days"),
    ("links.revoke", "Revoke"),
    // The card a link opens on.
    ("link.friend.title", "Add {name}?"),
    ("link.friend.subtitle", "Friends ID {id}"),
    ("link.friend.note", "{name} made this link, so you’ll be friends as soon as your request reaches {name}."),
    ("link.friend.already", "You’re already friends with {name}"),
    ("link.friend.add", "Add"),
    ("link.download.title", "Download this file?"),
    (
        "link.download.note",
        "It comes straight from the computer of the person who shared it, while {apps} is open there.",
    ),
    ("link.download.action", "Download"),
    // After pressing.
    (
        "link.request_sent",
        "Request sent to {name}. They get it as soon as Friends reaches them, and you’re friends as soon as it \
         arrives.",
    ),
    (
        "link.request_sent.online",
        "Request sent to {name}. It reaches them while {apps} is open for both of you, and you’re friends as soon as \
         it does.",
    ),
    ("link.receiving", "Receiving {file} from {name}. You’ll find it in your chat with {first} once it arrives."),
    ("link.receiving.anonymous", "Receiving {file}. You’ll find it in Friends once it arrives."),
    ("link.made", "Download link copied. It works until {date}, whenever this computer is on with {apps} open."),
    // History and rows.
    ("event.received_through_link", "Sent you {file} through a link"),
    ("event.added_through_your_link", "Added through your link"),
    ("event.added_through_their_link", "Added through {first}’s link"),
    ("composer.note.link_contact", "Add {first} as a friend to send messages."),
    ("transfer.action.add", "Add {first}"),
    // Errors of the link intents.
    ("error.not_found.link", "This link no longer works. Ask for a new one."),
    ("error.invalid_field.payload", "This link isn’t complete. Copy the whole link and open it again."),
    (
        "error.link_offline",
        "The computer this file comes from isn’t online right now. It can send the file while {apps} is open there.",
    ),
    ("error.link_changed", "The file changed after this link was made. Ask for a new link."),
    ("error.link_failed", "The file couldn’t be received. Try again."),
    ("error.too_many_links", "You have 50 download links already. Revoke one to make another."),
];

pub(super) const JOIN: &[(&str, &str)] = &[
    // The row on the person's other computers.
    ("join.row.title", "{device} wants to join your profile"),
    ("join.row.subtitle", "{system} · Approve only if you’re setting up that computer now"),
    ("join.row.approve", "Approve"),
    ("join.row.deny", "Deny"),
    ("join.row.deny.arm", "Deny?"),
    ("join.row.deny.arm.accessibility", "Click again to deny {device}"),
    ("join.row.accessibility", "{device} wants to join your profile, {system}"),
    ("join.row.approved.title", "Type this code on {device}"),
    ("join.row.approved.subtitle", "{system} · Waiting for the code"),
    ("join.row.approved.note", "It works until {time}. Type it on that computer only, and never send it to anyone."),
    ("join.row.approved.cancel", "Cancel"),
    ("join.row.approved.accessibility", "Type the code {code} on {device}. It works until {time}."),
    // The new computer.
    ("join.title", "Use your existing profile"),
    (
        "join.idle.message",
        "Type the Friends ID of the profile you already use on another computer. You’ll approve this computer there.",
    ),
    ("join.idle.placeholder", "Friends ID"),
    ("join.idle.button", "Continue"),
    ("join.waiting.title", "Approve this computer"),
    (
        "join.waiting.message",
        "On a computer that uses {id}, open Friends in {apps} and choose Approve. Then type the code it shows.",
    ),
    ("join.code.placeholder", "8-digit code"),
    ("join.code.button", "Join"),
    ("join.checking.message", "Checking the code with your other computer…"),
    ("join.wrong_code", "That code didn’t match. Check the code on your other computer and type it again."),
    ("join.not_reached", "Your other computer didn’t answer. Open {apps} there, and type the code again."),
    ("join.denied.title", "This computer wasn’t approved"),
    ("join.denied.message", "Your other computer chose Deny. Start again if you meant to approve it."),
    ("join.expired.title", "The code expired"),
    ("join.expired.message", "A code works for 5 minutes. Start again to get a new one."),
    ("join.too_many.title", "Too many wrong codes"),
    ("join.too_many.message", "After three wrong codes, the code stops working. Start again to get a new one."),
    ("join.start_again", "Start again"),
    ("join.cancel", "Cancel"),
    ("join.joined.title", "This computer now uses your profile"),
    ("join.joined.message", "Your friends and chats arrive from your other computers while they’re nearby or online."),
    (
        "join.unavailable.message",
        "This computer already has friends in Friends. To use your existing profile here instead, choose Reset \
         Friends in Settings first.",
    ),
    // Replies.
    ("error.not_found.join", "This request is no longer waiting. The other computer may have started again."),
    (
        "error.not_allowed.join",
        "This computer already has friends in Friends. Choose Reset Friends in Settings to use your existing profile \
         here.",
    ),
    ("error.invalid_field.code", "Type the 8 digits the other computer shows."),
];
