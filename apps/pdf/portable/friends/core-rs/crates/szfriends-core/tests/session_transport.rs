//! The live channel, Rust against Rust: rekey per direction, the session age, closing, queue priority, and the chunk
//! flow's windows, PROGRESS and resume (`SZFriendsChannelLifetimeTests`, `SZFriendsChunkFlowTests`,
//! `SZFriendsTransferResumeTests`).

mod support;

use std::time::Duration;

use support::*;
use szfriends_core::session::{
    ChannelConfig, ChunkReceiver, ChunkSender, Event, FlowError, SecureChannel, SessionError,
};
use szfriends_core::wire::consts::{CHUNK_BYTES_BLUETOOTH, CHUNK_BYTES_WIFI, SEND_WINDOW_WIFI};
use szfriends_core::wire::{tag, Frame, FrameType, Pattern, RouteMethod};

fn configured(config: ChannelConfig) -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    let mut initiator = SecureChannel::initiator(keys(&alice), options);
    let mut responder = SecureChannel::responder(keys(&bob), None, allow_all());
    initiator.set_config(config);
    responder.set_config(config);
    Pipe::new(initiator, responder)
}

#[test]
fn each_direction_rekeys_after_its_bytes_and_after_its_interval() {
    let config = ChannelConfig { rekey_after_bytes: 300, ..ChannelConfig::default() };
    let mut pipe = configured(config);
    for i in 0..10 {
        assert!(pipe.send(Side::Initiator, &message(&"x".repeat(100), i)));
    }
    assert_eq!(Pipe::frames(&pipe.responder_events).len(), 10);
    let (sent, received) = pipe.initiator.rekeys();
    assert!(sent >= 3 && received == 0, "{sent} {received}");
    assert_eq!(pipe.responder.rekeys(), (0, sent));
    // Fifteen minutes on, the next frame each way goes under a new key.
    pipe.advance(Duration::from_secs(900));
    pipe.send(Side::Responder, &message("later", 20));
    assert_eq!(pipe.responder.rekeys().0, 1);
    assert_eq!(Pipe::frames(&pipe.initiator_events), vec![message("later", 20)]);
}

#[test]
fn a_session_a_day_old_closes_as_expired_on_both_sides() {
    let mut pipe = configured(ChannelConfig::default());
    assert_eq!(pipe.initiator.poll_timeout(), Some(pipe.now + Duration::from_secs(86_400)));
    pipe.advance(Duration::from_secs(86_400));
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(Some(SessionError::Expired)));
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::Expired)));
}

#[test]
fn messages_jump_queued_chunks_and_close_drains_control_frames_first() {
    let config = ChannelConfig { preferred_write_size: 1024, ..ChannelConfig::default() };
    let mut pipe = configured(config);
    let now = pipe.now;
    // Hold the link: nothing is delivered until run(), so the queues fill.
    for offset in 0..4u64 {
        let chunk = Frame::new(FrameType::Chunk)
            .with(tag::ID, [9; 16])
            .with(tag::OFFSET, (offset * 3000).to_be_bytes())
            .with(tag::DATA, vec![offset as u8; 3000]);
        assert!(pipe.initiator.send_frame(&chunk, now));
    }
    assert!(pipe.initiator.send_frame(&message("overtakes", 1), now));
    pipe.run();
    let types: Vec<FrameType> = Pipe::frames(&pipe.responder_events).iter().map(|f| f.frame_type).collect();
    let position = types.iter().position(|t| *t == FrameType::Message).unwrap();
    assert!(position < 3, "{types:?}");
    // CLOSE drops queued chunks but still sends queued control frames.
    for offset in 0..4u64 {
        let chunk = Frame::new(FrameType::Chunk)
            .with(tag::ID, [8; 16])
            .with(tag::OFFSET, offset.to_be_bytes())
            .with(tag::DATA, vec![1; 3000]);
        pipe.initiator.send_frame(&chunk, now);
    }
    pipe.initiator.send_frame(&Frame::new(FrameType::Ack).with(tag::ID, [5; 16]), now);
    pipe.initiator.close(now);
    assert!(!pipe.initiator.send_frame(&message("too late", 2), now));
    pipe.run();
    let frames = Pipe::frames(&pipe.responder_events);
    assert_eq!(frames.last().map(|f| f.frame_type), Some(FrameType::Ack));
    assert!(frames.iter().filter(|f| f.get(tag::ID) == Some(&[8; 16][..])).count() < 4);
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::PeerClosed(0))));
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(None));
}

#[test]
fn channel_frames_and_disallowed_types_are_never_sent() {
    let mut pipe = configured(ChannelConfig::default());
    let now = pipe.now;
    for frame_type in [FrameType::Hello, FrameType::Rekey, FrameType::Ping, FrameType::Received] {
        assert!(!pipe.initiator.send_frame(&Frame::new(frame_type), now), "{frame_type:?}");
    }
    let bad = Frame::new(FrameType::Message).with(tag::ID, [1; 15]);
    assert!(!pipe.initiator.send_frame(&bad, now));
    pipe.run();
    assert!(Pipe::frames(&pipe.responder_events).is_empty());
}

#[test]
fn the_sender_keeps_to_its_window_and_resumes_from_progress() {
    let id = [3u8; 16];
    let size = 20 * CHUNK_BYTES_WIFI as u64 + 5;
    let mut sender = ChunkSender::new(&id, size, 0, CHUNK_BYTES_WIFI, 4 * CHUNK_BYTES_WIFI as u64).unwrap();
    let mut receiver = ChunkReceiver::new(&id, size, 0, CHUNK_BYTES_WIFI, 4 * CHUNK_BYTES_WIFI as u64).unwrap();
    let mut chunks = 0;
    while let Some((_, length)) = sender.next_chunk() {
        let frame = sender.chunk_frame(&vec![0; length]).unwrap();
        receiver.accept_chunk(&frame).unwrap();
        chunks += 1;
    }
    assert_eq!(chunks, 4);
    assert_eq!(receiver.accept_chunk(&Frame::new(FrameType::Chunk)), Err(FlowError::AnotherTransfer));
    let progress = receiver.progress_frame(2 * CHUNK_BYTES_WIFI as u64).unwrap();
    sender.handle_progress(&progress).unwrap();
    assert_eq!(sender.next_chunk(), Some((4 * CHUNK_BYTES_WIFI as u64, CHUNK_BYTES_WIFI)));
    assert_eq!(sender.handle_progress(&progress_at(&id, CHUNK_BYTES_WIFI as u64)), Err(FlowError::WentBackwards));
    assert_eq!(sender.handle_progress(&progress_at(&id, size)), Err(FlowError::NeverSent));
    // A new session resumes at the recipient's PROGRESS: the same mechanism moves a transfer between routes.
    let receiver = ChunkReceiver::for_route(&id, size, 2 * CHUNK_BYTES_WIFI as u64, RouteMethod::Bluetooth).unwrap();
    let resume = receiver.resume_progress_frame();
    let mut sender = ChunkSender::for_route(&id, size, 2 * CHUNK_BYTES_WIFI as u64, RouteMethod::Bluetooth).unwrap();
    sender.handle_progress(&resume).unwrap();
    assert_eq!(sender.next_chunk(), Some((2 * CHUNK_BYTES_WIFI as u64, CHUNK_BYTES_BLUETOOTH)));
}

#[test]
fn the_receiver_refuses_gaps_overlaps_oversize_and_early_done() {
    let id = [4u8; 16];
    let mut receiver = ChunkReceiver::new(&id, 100, 0, 40, SEND_WINDOW_WIFI).unwrap();
    let chunk = |offset: u64, length: usize| {
        Frame::new(FrameType::Chunk)
            .with(tag::ID, id)
            .with(tag::OFFSET, offset.to_be_bytes())
            .with(tag::DATA, vec![1; length])
    };
    assert_eq!(receiver.accept_chunk(&chunk(10, 10)), Err(FlowError::NotContiguous));
    assert_eq!(receiver.accept_chunk(&chunk(0, 41)), Err(FlowError::TooLarge));
    assert_eq!(receiver.accept_chunk(&chunk(0, 40)).map(<[u8]>::len), Ok(40));
    let done = Frame::new(FrameType::Done).with(tag::ID, id).with(tag::DIGEST, [0; 32]);
    assert_eq!(receiver.accept_done(&done), Err(FlowError::EarlyDone));
    receiver.accept_chunk(&chunk(40, 40)).unwrap();
    assert_eq!(receiver.accept_chunk(&chunk(80, 40)), Err(FlowError::TooLarge));
    receiver.accept_chunk(&chunk(80, 20)).unwrap();
    assert_eq!(receiver.accept_done(&done), Ok([0; 32]));
    assert!(receiver.progress_frame(101).is_none());
    assert!(receiver.progress_frame(100).is_some() && receiver.progress_frame(99).is_none());
    let mut small = ChunkReceiver::new(&id, 100, 0, 40, 40).unwrap();
    small.accept_chunk(&chunk(0, 40)).unwrap();
    assert_eq!(small.accept_chunk(&chunk(40, 1)), Err(FlowError::BeyondWindow));
    assert!(ChunkSender::new(&id, 10, 11, 4, 8).is_none() && ChunkSender::new(&id, 10, 0, 9, 8).is_none());
}

fn progress_at(id: &[u8; 16], offset: u64) -> Frame {
    Frame::new(FrameType::Progress).with(tag::ID, *id).with(tag::OFFSET, offset.to_be_bytes())
}

#[test]
fn a_close_from_the_peer_carries_its_reason() {
    let mut pipe = configured(ChannelConfig::default());
    let now = pipe.now;
    pipe.responder.close_with_reason(szfriends_core::wire::CloseReason::Superseded, now);
    pipe.run();
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(Some(SessionError::PeerClosed(2))));
    assert!(matches!(pipe.responder_events.last(), Some(Event::Closed(None))));
}
