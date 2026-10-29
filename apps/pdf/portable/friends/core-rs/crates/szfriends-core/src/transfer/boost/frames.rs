//! BOOST frames (boost.rs): each step's meaning, and its encoding on the session.

use super::*;

/// One BOOST frame's meaning.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Message {
    Propose { abilities: Abilities },
    Ready { abilities: Abilities },
    Host { link: Link, address: IpAddr, port: u16 },
    End { reason: u8 },
    Decline { reason: u8 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageError {
    NotBoost,
    UnknownStep(u8),
    /// A field the step needs is missing or malformed.
    Missing(u8),
    /// HOST names a link a joining side refuses ([`Link::valid`], [`private_address`]).
    BadLink,
}

/// BOOST for `transfer` (the id of the file it is for).
pub fn encode(transfer: &[u8; 16], message: &Message) -> Frame {
    let frame = Frame::new(FrameType::Boost).with(tag::ID, transfer.to_vec());
    match message {
        Message::Propose { abilities } => {
            frame.with(tag::STEP, [boost_step::PROPOSE]).with(tag::ABILITIES, [abilities.byte()])
        }
        Message::Ready { abilities } => {
            frame.with(tag::STEP, [boost_step::READY]).with(tag::ABILITIES, [abilities.byte()])
        }
        Message::Host { link, address, port } => {
            let address = match address {
                IpAddr::V4(v4) => v4.octets().to_vec(),
                IpAddr::V6(v6) => v6.octets().to_vec(),
            };
            frame
                .with(tag::STEP, [boost_step::HOST])
                .with(tag::NETWORK, link.network.as_bytes().to_vec())
                .with(tag::PASSPHRASE, link.passphrase.as_bytes().to_vec())
                .with(tag::ADDRESS, address)
                .with(tag::PORT, port.to_be_bytes())
        }
        Message::End { reason } => frame.with(tag::STEP, [boost_step::END]).with(tag::REASON, [*reason]),
        Message::Decline { reason } => frame.with(tag::STEP, [boost_step::DECLINE]).with(tag::REASON, [*reason]),
    }
}

/// The transfer and the message of a BOOST the codec accepted.
pub fn decode(frame: &Frame) -> Result<([u8; 16], Message), MessageError> {
    if frame.frame_type != FrameType::Boost {
        return Err(MessageError::NotBoost);
    }
    let field = |t: u8| frame.fields.get(&t).ok_or(MessageError::Missing(t));
    let transfer: [u8; 16] = field(tag::ID)?.as_slice().try_into().map_err(|_| MessageError::Missing(tag::ID))?;
    let byte = |t: u8| field(t).and_then(|v| v.first().copied().ok_or(MessageError::Missing(t)));
    let message = match byte(tag::STEP)? {
        boost_step::PROPOSE => Message::Propose { abilities: Abilities::from_byte(byte(tag::ABILITIES)?) },
        boost_step::READY => Message::Ready { abilities: Abilities::from_byte(byte(tag::ABILITIES)?) },
        boost_step::HOST => {
            let text =
                |t: u8| field(t).and_then(|v| String::from_utf8(v.clone()).map_err(|_| MessageError::Missing(t)));
            let link = Link { network: text(tag::NETWORK)?, passphrase: text(tag::PASSPHRASE)? };
            let address = match field(tag::ADDRESS)?.as_slice() {
                bytes if bytes.len() == 4 => IpAddr::from(<[u8; 4]>::try_from(bytes).expect("4")),
                bytes if bytes.len() == 16 => IpAddr::from(<[u8; 16]>::try_from(bytes).expect("16")),
                _ => return Err(MessageError::Missing(tag::ADDRESS)),
            };
            let port = field(tag::PORT)?;
            let port = u16::from_be_bytes([port[0], port[1]]);
            if !link.valid() || !private_address(&address) || port == 0 {
                return Err(MessageError::BadLink);
            }
            Message::Host { link, address, port }
        }
        boost_step::END => Message::End { reason: byte(tag::REASON).unwrap_or(boost_reason::DONE) },
        boost_step::DECLINE => Message::Decline { reason: byte(tag::REASON).unwrap_or(boost_reason::FAILED) },
        other => return Err(MessageError::UnknownStep(other)),
    };
    Ok((transfer, message))
}
