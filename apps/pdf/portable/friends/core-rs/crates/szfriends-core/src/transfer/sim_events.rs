//! The simulator's event loop: what the scheduler's actions do on the emulated lanes, and what each lane's events do
//! to the scheduler (sim.rs).

use super::*;

impl Sim {
    pub(super) fn at(&mut self, t: Duration, ev: Ev) {
        self.seq += 1;
        self.queue.insert((t, self.seq), ev);
    }

    pub(super) fn start(&mut self) {
        self.lanes[0].state = State::Up;
        self.at(Duration::from_secs(1), Ev::Ping(0));
        for i in 1..self.lanes.len() {
            if let Some(t) = self.lanes[i].profile.up_at {
                self.at(t, Ev::Up(i));
            }
        }
        for i in 0..self.lanes.len() {
            if let Some(t) = self.lanes[i].profile.cut_at {
                self.at(t, Ev::Cut(i));
            }
        }
        self.feed_group();
        self.scheduler.add_transfer(KEY, self.geometry);
        self.scheduler.want(KEY, &[(0, self.geometry.blocks)], self.now).expect("in range");
        self.act();
    }

    pub(super) fn feed_group(&mut self) {
        for event in self.group.take_events() {
            self.scheduler.lane_event(event, self.now);
        }
    }

    pub(super) fn arm_timer(&mut self) {
        if let Some(t) = self.scheduler.next_timer() {
            let t = t.max(self.now);
            if self.timer_at.is_none_or(|armed| t < armed) {
                self.timer_at = Some(t);
                self.at(t, Ev::Timer);
            }
        }
    }

    pub(super) fn check_limits(&mut self) {
        let (blocks, bytes) = self.scheduler.open(KEY);
        self.out.max_open_blocks = self.out.max_open_blocks.max(blocks);
        self.out.max_open_bytes = self.out.max_open_bytes.max(bytes);
    }

    pub(super) fn lane_of(&self, id: LaneId) -> Option<usize> {
        self.lanes.iter().position(|l| l.id == id)
    }

    pub(super) fn act(&mut self) {
        loop {
            let actions = self.scheduler.take_actions();
            if actions.is_empty() {
                return;
            }
            self.act_on(actions);
        }
    }

    pub(super) fn act_on(&mut self, actions: Vec<Action>) {
        for action in actions {
            match action {
                Action::Send { lane, block, .. } => {
                    let Some(i) = self.lane_of(lane) else { continue };
                    let stats = self.scheduler.lane_stats(lane).expect("a lane it chose");
                    let (_, length) = self.geometry.span(block);
                    let cap = self.scheduler.lane_cap(lane, self.geometry.block_bytes());
                    if stats.in_flight > cap.max(length as u64) {
                        self.out.lane_cap_exceeded = true;
                    }
                    if self.lanes[i].state != State::Up {
                        continue;
                    }
                    let (start, len) = self.geometry.span(block);
                    let mut flip = false;
                    if let Some(bytes) = &mut self.bytes {
                        // As the sender's driver does (BlockServe::load_block): the block read is checked first.
                        let data = &bytes.file[start as usize..start as usize + len];
                        assert_eq!(tree::leaf(block, data), bytes.leaves[block as usize], "the snapshot's block");
                        flip = bytes.damage.remove(&block);
                    }
                    let step = self.lanes[i].profile.part_bytes;
                    let mut from = start;
                    loop {
                        let to = (from + step).min(start + len as u64);
                        let last = to == start + len as u64;
                        self.lanes[i].queue.push_back(Part { block, from, to, last, flip: flip && from == start });
                        if to == start + len as u64 {
                            break;
                        }
                        from = to;
                    }
                    if self.lanes[i].current.is_none() || self.lanes[i].profile.buffer > 0 {
                        self.transmit(i);
                    }
                }
                Action::Cancel { lane, block, .. } => {
                    if let Some(i) = self.lane_of(lane) {
                        self.lanes[i].queue.retain(|p| p.block != block);
                    }
                }
                Action::Lane(request) => {
                    self.out.requests.push((self.now, request));
                    match request {
                        LaneRequest::Open { route } => {
                            let found = self.lanes.iter().position(|l| {
                                l.profile.route == route && l.profile.up_at.is_none() && l.state == State::Idle
                            });
                            if let Some(i) = found {
                                if self.group.reserve(self.lanes[i].id, route).is_some() {
                                    self.lanes[i].state = State::Dialing;
                                    let t = self.now + self.lanes[i].profile.dial;
                                    self.at(t, Ev::Up(i));
                                }
                            }
                        }
                        LaneRequest::Close { lane } => {
                            if let Some(i) = self.lane_of(lane) {
                                self.cut(i);
                                self.notice(i);
                            }
                        }
                    }
                }
            }
        }
    }

    pub(super) fn transmit(&mut self, i: usize) {
        if self.lanes[i].profile.buffer > 0 {
            return self.transmit_buffered(i);
        }
        let Some(part) = self.lanes[i].queue.pop_front() else {
            self.lanes[i].current = None;
            return;
        };
        let profile = &self.lanes[i].profile;
        let mut seconds = (part.to - part.from) as f64 / profile.rate;
        if profile.loss > 0.0 && self.random.next() < profile.loss {
            seconds += profile.rtt.as_secs_f64();
        }
        let done = profile.advance(self.now, Duration::from_secs_f64(seconds));
        self.lanes[i].current = Some(part);
        let epoch = self.lanes[i].epoch;
        self.at(done, Ev::TxDone(i, epoch));
    }

    /// With a socket buffer: parts go into it while it has room, each a completed write, and cross one by one.
    pub(super) fn transmit_buffered(&mut self, i: usize) {
        let id = self.lanes[i].id;
        loop {
            let lane = &mut self.lanes[i];
            let Some(next) = lane.queue.front() else { break };
            let bytes = next.to - next.from;
            if lane.buffered_bytes > 0 && lane.buffered_bytes + bytes > lane.profile.buffer {
                break;
            }
            let part = lane.queue.pop_front().expect("a front");
            lane.buffered_bytes += bytes;
            lane.buffered.push_back(part);
            self.scheduler.written(id, self.now);
            if part.last {
                self.scheduler.sent(id, KEY, part.block, self.now);
            }
        }
        if self.lanes[i].current.is_some() {
            return;
        }
        let Some(&part) = self.lanes[i].buffered.front() else { return };
        let profile = &self.lanes[i].profile;
        let mut seconds = (part.to - part.from) as f64 / profile.rate;
        if profile.loss > 0.0 && self.random.next() < profile.loss {
            seconds += profile.rtt.as_secs_f64();
        }
        let done = profile.advance(self.now, Duration::from_secs_f64(seconds));
        self.lanes[i].current = Some(part);
        let epoch = self.lanes[i].epoch;
        self.at(done, Ev::TxDone(i, epoch));
    }

    pub(super) fn cut(&mut self, i: usize) {
        let lane = &mut self.lanes[i];
        if lane.state != State::Up {
            return;
        }
        lane.state = State::Gone;
        lane.epoch += 1;
        lane.queue.clear();
        lane.current = None;
        lane.buffered.clear();
        lane.buffered_bytes = 0;
    }

    pub(super) fn notice(&mut self, i: usize) {
        self.group.lane_down(self.lanes[i].id);
        self.feed_group();
        self.act();
    }

    pub(super) fn send_back(&mut self, mut i: usize, block: u32, want: bool) {
        if self.lanes[i].state != State::Up {
            let quickest = (0..self.lanes.len())
                .filter(|&j| self.lanes[j].state == State::Up)
                .min_by_key(|&j| self.lanes[j].profile.rtt);
            let Some(j) = quickest else { return };
            i = j;
        }
        let lane = &self.lanes[i];
        let t = lane.profile.advance(self.now + Duration::from_micros(300), lane.profile.rtt / 2);
        let epoch = lane.epoch;
        self.at(t, Ev::Back { lane: i, epoch, block, want });
    }

    /// The receiver with real bytes: WP1's assembly decides, and a block that fails its leaf is wanted again.
    pub(super) fn arrive_bytes(&mut self, lane: usize, block: u32, from: u64, to: u64, flip: bool) {
        let bytes = self.bytes.as_mut().expect("real bytes");
        let mut data = bytes.file[from as usize..to as usize].to_vec();
        if flip {
            data[0] ^= 0x80;
        }
        match bytes.assembly.accept_part(from, &data).expect("parts only for wanted blocks, within § 3") {
            PartOutcome::Pending => {}
            PartOutcome::Complete { block, data } => {
                let (offset, _) = self.geometry.span(block);
                bytes.received[offset as usize..offset as usize + data.len()].copy_from_slice(&data);
                self.complete[block as usize] = true;
                self.out.lanes[lane].completed += 1;
                self.out.last_route = self.lanes[lane].profile.route;
                self.send_back(lane, block, false);
            }
            PartOutcome::Corrupt { block } => {
                self.out.corrupt_blocks += 1;
                self.send_back(lane, block, true);
            }
            PartOutcome::Late => {
                self.out.wasted_bytes += to - from;
                if self.answered.insert((lane, block)) {
                    self.send_back(lane, block, false);
                }
            }
        }
    }

    pub(super) fn handle(&mut self, ev: Ev) {
        match ev {
            Ev::Up(i) => {
                let id = self.lanes[i].id;
                if self.lanes[i].state == State::Idle && self.group.reserve(id, self.lanes[i].profile.route).is_none() {
                    return;
                }
                self.lanes[i].state = State::Up;
                self.out.lanes[i].up_at.get_or_insert(self.now);
                self.group.lane_up(id);
                self.at(self.now + Duration::from_secs(1), Ev::Ping(i));
                self.feed_group();
                self.act();
            }
            Ev::Cut(i) => {
                if self.lanes[i].state == State::Up {
                    self.cut(i);
                    self.at(self.now + self.lanes[i].profile.detect, Ev::Notice(i));
                }
            }
            Ev::Notice(i) => self.notice(i),
            Ev::TxDone(i, epoch) => {
                if self.lanes[i].epoch != epoch {
                    return;
                }
                let Some(part) = self.lanes[i].current.take() else { return };
                let id = self.lanes[i].id;
                let direct_works = self.lanes.iter().any(|l| {
                    l.profile.route != RouteMethod::Relay && l.state == State::Up && !l.profile.silent_at(self.now)
                });
                if self.lanes[i].profile.route == RouteMethod::Relay && direct_works {
                    self.out.relay_beside_direct_bytes += part.to - part.from;
                }
                let o = &mut self.out.lanes[i];
                o.sent_bytes += part.to - part.from;
                o.last_write = self.now;
                o.first_write.get_or_insert(self.now);
                self.out.sent_bytes += part.to - part.from;
                let arrive = self.lanes[i].profile.advance(self.now, self.lanes[i].profile.rtt / 2);
                let (block, from, to, flip) = (part.block, part.from, part.to, part.flip);
                self.at(arrive, Ev::Arrive { lane: i, epoch, block, from, to, flip });
                if self.lanes[i].profile.buffer > 0 {
                    // Written when it went into the buffer.
                    self.lanes[i].buffered.pop_front();
                    self.lanes[i].buffered_bytes -= to - from;
                } else {
                    self.scheduler.written(id, self.now);
                    if part.last {
                        self.scheduler.sent(id, KEY, part.block, self.now);
                    }
                }
                self.transmit(i);
                self.act();
            }
            Ev::Arrive { lane, epoch, block, from, to, flip } => {
                if self.lanes[lane].epoch != epoch {
                    return;
                }
                if self.bytes.is_some() {
                    return self.arrive_bytes(lane, block, from, to, flip);
                }
                if self.complete[block as usize] {
                    // A late copy: dropped, and answered with a HAVE for that block once per lane, as the HAVE that
                    // said so may have gone with a lane that fell silent.
                    self.out.wasted_bytes += to - from;
                    if self.answered.insert((lane, block)) {
                        self.send_back(lane, block, false);
                    }
                    return;
                }
                let (start, len) = self.geometry.span(block);
                let bits = &mut self.covered[block as usize];
                let mut fresh = false;
                for g in (from - start) / GRANULE..(to - start).div_ceil(GRANULE) {
                    let (word, bit) = ((g / 64) as usize, g % 64);
                    fresh |= bits[word] & (1 << bit) == 0;
                    bits[word] |= 1 << bit;
                }
                if !fresh {
                    self.out.wasted_bytes += to - from;
                }
                let needed = (len as u64).div_ceil(GRANULE).max(1);
                let have: u64 = bits.iter().map(|w| u64::from(w.count_ones())).sum();
                if have >= needed {
                    self.complete[block as usize] = true;
                    self.out.lanes[lane].completed += 1;
                    self.out.last_route = self.lanes[lane].profile.route;
                    self.send_back(lane, block, false);
                }
            }
            Ev::Back { lane, epoch, block, want } => {
                if self.lanes[lane].epoch != epoch {
                    self.send_back(lane, block, want);
                    return;
                }
                let id = self.lanes[lane].id;
                self.scheduler.heard(id, self.now);
                if want {
                    self.scheduler.want(KEY, &[(block, 1)], self.now).expect("in range");
                    self.act();
                    return;
                }
                self.scheduler.have(KEY, &[(block, 1)], self.now).expect("in range");
                if self.scheduler.is_done(KEY) {
                    self.out.done_at = Some(self.now);
                    return;
                }
                self.act();
            }
            Ev::Ping(i) => {
                if self.lanes[i].state != State::Up {
                    return;
                }
                let t = self.lanes[i].profile.advance(self.now, self.lanes[i].profile.rtt / 2);
                let epoch = self.lanes[i].epoch;
                self.at(t, Ev::Heard(i, epoch));
                self.at(self.now + Duration::from_secs(1), Ev::Ping(i));
            }
            Ev::Heard(i, epoch) => {
                if self.lanes[i].epoch == epoch && self.lanes[i].state == State::Up {
                    self.scheduler.heard(self.lanes[i].id, self.now);
                }
            }
            Ev::Timer => {
                if self.timer_at == Some(self.now) {
                    self.timer_at = None;
                    self.scheduler.tick(self.now);
                    self.act();
                }
            }
        }
    }
}
