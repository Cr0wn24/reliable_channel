package hampuslib_reliable

import "core:mem"
import "core:log"
import "core:slice"
import "core:time"
import "core:hash"

import "../ack"

PROTOCOL_ID : u32 : 1
AVAILABLE_BANDWIDTH_KBPS :: 256

Reliable_ID :: distinct u16

@(private, require_results)
reliable_id_greater_than :: proc(s1, s2: Reliable_ID) -> bool {
  result := ((s1 > s2) && (s1 - s2 <= 32768)) || ((s1 < s2) && (s2 - s1 > 32768))
  return result
}

@(private, require_results)
reliable_id_less_than :: proc(s1, s2: Reliable_ID) -> bool {
  result := reliable_id_greater_than(s2, s1)
  return result
}

@(private, require_results)
reliable_id_match :: proc(s1, s2: Reliable_ID) -> bool {
  result := s1 == s2
  return result
}

SLICE_SIZE_CRITICAL_VALUE :: ack.FRAGMENT_SIZE - size_of(Normal_Packet) - size_of(u32)
SLICE_SIZE :: ack.FRAGMENT_SIZE - size_of(Slice_Packet) - size_of(u32)
MAX_SLICES_PER_CHUNK :: 256
MAX_CHUNK_SIZE :: SLICE_SIZE * MAX_SLICES_PER_CHUNK

Packet_Kind :: enum {
  Normal,
  Slice,
  Slice_Ack,
  Keep_Alive,
}

Base_Packet :: struct {
  crc32: u32,
  kind: Packet_Kind,
}

Keep_Alive_Packet :: struct {
  using base: Base_Packet,
}

Normal_Packet :: struct {
  using base: Base_Packet,
  is_reliable: bool,
  id: Reliable_ID,
}

Slice_Packet :: struct {
  using base: Base_Packet,
  id: Reliable_ID,
  slice_id: u8,
  num_slices: u16,
  slice_size: u16,
}

Slice_Ack_Packet :: struct {
  using base: Base_Packet,
  id: Reliable_ID,
  acked: [2]u128,
}

@(private)
add_crc32_to_packet :: proc(packet_data: []u8) {
  packet_base := cast(^Base_Packet)raw_data(packet_data)
  packet_base.crc32 = hash.crc32(packet_data[size_of(u32):len(packet_data)-size_of(u32)], seed = PROTOCOL_ID)
  last_crc32 := cast(^u32)raw_data(packet_data[len(packet_data)-size_of(u32):])
  last_crc32^ = packet_base.crc32
}

@(private, require_results)
make_packet :: proc(kind: Packet_Kind, data: []u8 = {}, allocator := context.temp_allocator, loc := #caller_location) -> []u8 {

  packet_size := 0

  switch kind {
    case .Normal: packet_size = size_of(Normal_Packet)
    case .Slice: packet_size = size_of(Slice_Packet)
    case .Slice_Ack: packet_size = size_of(Slice_Ack_Packet)
    case .Keep_Alive: packet_size = size_of(Keep_Alive_Packet)
  }

  packet_data := make([]u8, packet_size + len(data) + size_of(u32), allocator = allocator)

  base_packet := cast(^Base_Packet)raw_data(packet_data)
  base_packet.kind = kind
  copy(packet_data[packet_size:len(packet_data)-size_of(u32)], data)
  return packet_data
}

@(private, require_results)
get_packet_payload :: proc(kind: Packet_Kind, packet_data: []u8) -> []u8 {

  packet_size := 0

  switch kind {
    case .Normal: packet_size = size_of(Normal_Packet)
    case .Slice: packet_size = size_of(Slice_Packet)
    case .Slice_Ack: packet_size = size_of(Slice_Ack_Packet)
    case .Keep_Alive: packet_size = size_of(Keep_Alive_Packet)
  }

  return packet_data[packet_size:len(packet_data)-size_of(u32)]
}

Reliable_Packet_Buffer_Entry :: struct {
  id: Reliable_ID,
  sequence: u16,
  data: []u8,
  last_send_time: time.Time,
  waiting_for_ack: bool,
  past_sequences: map[u16]struct{},
}

Chunk_Sender :: struct {
  entry: ^Reliable_Packet_Buffer_Entry,
  sending: bool,
  chunk_size: u32,
  num_slices: u16,
  num_acked_slices: u16,
  current_slice_id: u16,
  acked: [MAX_SLICES_PER_CHUNK]bool,
  time_last_sent: [MAX_SLICES_PER_CHUNK]time.Time,
  chunk_data: [MAX_CHUNK_SIZE]u8,
}

@(private, require_results)
chunk_sender_make_slice_packet :: proc(chunk_sender: ^Chunk_Sender, slice_id: u8, reliable_id: Reliable_ID, allocator := context.temp_allocator, loc := #caller_location) -> []u8 {
  slice_size := 0
  if (chunk_sender.chunk_size - (u32(slice_id) * SLICE_SIZE)) < SLICE_SIZE {
    slice_size = int(chunk_sender.chunk_size % SLICE_SIZE)
  } else {
    slice_size = SLICE_SIZE
  }

  packet_data := make_packet(.Slice, chunk_sender.chunk_data[int(slice_id)*SLICE_SIZE:(int(slice_id)+1)*SLICE_SIZE], allocator = allocator, loc = loc)
  slice_packet := cast(^Slice_Packet)raw_data(packet_data)
  slice_packet.id = reliable_id
  slice_packet.slice_id = u8(slice_id)
  slice_packet.num_slices = chunk_sender.num_slices
  slice_packet.slice_size = u16(slice_size)

  add_crc32_to_packet(packet_data)
  return packet_data
}

Chunk_Receiver_Status :: enum {
  Ready_To_Receive_New_Chunk,
  Receiving,
}

Chunk_Receiver :: struct {
  status: Chunk_Receiver_Status,
  chunk_size: u32,
  num_slices: u16,
  num_received_slices: u16,
  received: [MAX_SLICES_PER_CHUNK]bool,
  chunk_data: [MAX_CHUNK_SIZE]u8,
}

@(private, require_results)
chunk_receiver_make_ack_packet :: proc(chunk_receiver: ^Chunk_Receiver, reliable_id: Reliable_ID) -> []u8 {

  packet_data := make_packet(.Slice_Ack, allocator = context.temp_allocator)
  packet := cast(^Slice_Ack_Packet)raw_data(packet_data)
  packet.id = reliable_id

  for slice_id in 0..<min(128, chunk_receiver.num_slices) {
    if chunk_receiver.received[slice_id] {
      packet.acked[0] |= 1 << slice_id
    }
  }

  for slice_id in 128..<chunk_receiver.num_slices {
    if chunk_receiver.received[slice_id] {
      packet.acked[1] |= 1 << (slice_id - 128)
    }
  }

  add_crc32_to_packet(packet_data)
  return packet_data
}

Send_Data_Callback :: #type proc(channel: ^Channel, packet_data: []u8)

Channel :: struct {
  endpoint: ^ack.Endpoint,
  received_data: [dynamic][]u8,
  allocator: mem.Allocator,

  remote_sequence: u16,

  reliable_packet_buffer_write_pos: int,
  reliable_packet_buffer_read_pos: int,
  reliable_packet_buffer: [4096]Reliable_Packet_Buffer_Entry,

  next_reliable_id_to_push: Reliable_ID,
  next_reliable_id_to_receive: Reliable_ID,

  chunk_sending_budget_bytes: f64,

  chunk_sender: Chunk_Sender,
  chunk_receiver: Chunk_Receiver,

  last_keep_alive_send_time: time.Time,

  user_data: rawptr,

  send_callback: Send_Data_Callback,
}

@(private)
channel_on_send_data :: proc(endpoint: ^ack.Endpoint, packet_data: []u8) {
  channel := cast(^Channel)endpoint.user_data
  channel.send_callback(channel, packet_data)
}

@(private, require_results)
channel_on_receive_data :: proc(endpoint: ^ack.Endpoint, sequence: u16, packet_data: []u8) -> bool {
  channel := cast(^Channel)endpoint.user_data
  base_packet := cast(^Base_Packet)raw_data(packet_data)

  crc32 := hash.crc32(packet_data[size_of(u32):len(packet_data)-size_of(u32)], seed = PROTOCOL_ID)
  last_crc32 := cast(^u32)raw_data(packet_data[len(packet_data)-size_of(u32):])

  if base_packet.crc32 != crc32 || last_crc32^ != crc32 {
    log.error("Got packet with wrong crc32 with sequence:", sequence)
    return false
  }

  // NOTE(hampus): Two reliable packets can't get received out-of-order.
  // However, a reliable packet and an unreliable packet can get received
  // out-of-order. To ensure that we still receive the reliable packet,
  // we make an exception for it and still deliver it.

  should_accept_packet := false
  is_reliable := false
  if base_packet.kind == .Normal {
    packet := cast(^Normal_Packet)raw_data(packet_data)
    is_reliable = packet.is_reliable
    if is_reliable {
      if reliable_id_match(packet.id, channel.next_reliable_id_to_receive) {
        channel.next_reliable_id_to_receive += 1
        should_accept_packet = true
      }
    } else {
      should_accept_packet = ack.sequence_greater_than(sequence, channel.remote_sequence-1)
    }
  } else if base_packet.kind == .Slice || base_packet.kind == .Slice_Ack || base_packet.kind == .Keep_Alive {
    should_accept_packet = true
  }

  if should_accept_packet {
    if ack.sequence_greater_than(sequence, channel.remote_sequence-1) {
      channel.remote_sequence = sequence+1
    }
    switch base_packet.kind {
      case .Keep_Alive:

      case .Normal:
      packet := cast(^Normal_Packet)raw_data(packet_data)
      cloned_data := slice.clone(get_packet_payload(.Normal, packet_data), context.temp_allocator)
      append(&channel.received_data, cloned_data)

      case .Slice:
      chunk_receiver := &channel.chunk_receiver
      packet := cast(^Slice_Packet)raw_data(packet_data)
      switch chunk_receiver.status {
        case .Ready_To_Receive_New_Chunk:
        if reliable_id_match(packet.id, channel.next_reliable_id_to_receive) {
          chunk_receiver.chunk_size = 0
          chunk_receiver.num_received_slices = 0
          chunk_receiver.received = {}
          chunk_receiver.num_slices = packet.num_slices
          chunk_receiver.status = .Receiving
          channel.next_reliable_id_to_receive += 1
        } else if reliable_id_less_than(packet.id, channel.next_reliable_id_to_receive) {
          // We have received all the slices but all our acks has
          // not gone through
          ack_packet := chunk_receiver_make_ack_packet(chunk_receiver, packet.id)
          err := ack.endpoint_send_data(endpoint, ack_packet)
          assert(err == nil)
          break
        }
        fallthrough

        case .Receiving:
        if reliable_id_match(packet.id, channel.next_reliable_id_to_receive-1) {
          is_duplicate_slice := chunk_receiver.received[packet.slice_id]
          if !is_duplicate_slice {
            chunk_receiver.num_received_slices += 1
            chunk_receiver.chunk_size += u32(packet.slice_size)
            chunk_receiver.received[packet.slice_id] = true
            copy(chunk_receiver.chunk_data[u32(packet.slice_id)*SLICE_SIZE:(u32(packet.slice_id)+1)*SLICE_SIZE], get_packet_payload(.Slice, packet_data))
          }

          ack_packet := chunk_receiver_make_ack_packet(chunk_receiver, channel.next_reliable_id_to_receive-1)
          err := ack.endpoint_send_data(channel.endpoint, ack_packet)
          assert(err == nil)

          if chunk_receiver.num_received_slices == chunk_receiver.num_slices {
            cloned_data := slice.clone(chunk_receiver.chunk_data[:chunk_receiver.chunk_size], context.temp_allocator)
            append(&channel.received_data, cloned_data)
            chunk_receiver.status = .Ready_To_Receive_New_Chunk
          }
        }

      }

      case .Slice_Ack:
      chunk_sender := &channel.chunk_sender
      if chunk_sender.sending {
        packet := cast(^Slice_Ack_Packet)raw_data(packet_data)
        if reliable_id_match(packet.id, chunk_sender.entry.id) {
          for bit: u32 = 0; bit < 128; bit += 1 {
            if (!chunk_sender.acked[bit] && (packet.acked[0] & (1 << bit)) != 0) {
              chunk_sender.acked[bit] = true
              chunk_sender.num_acked_slices += 1
            }
            if (!chunk_sender.acked[128+bit] && (packet.acked[1] & (1 << bit)) != 0) {
              chunk_sender.acked[128+bit] = true
              chunk_sender.num_acked_slices += 1
            }
          }
        }
        if chunk_sender.num_acked_slices == chunk_sender.num_slices {
          chunk_sender.entry.waiting_for_ack = false
          delete(chunk_sender.entry.data, channel.allocator)
          chunk_sender.entry.data = {}
          channel.reliable_packet_buffer_read_pos += 1
          chunk_sender.sending = false
        }
      }
    }
  } else {
    log.warn("Ignoring packet:", sequence, "expected sequence:", channel.remote_sequence, base_packet.kind, is_reliable)
  }

  return true
}

@(require_results)
channel_open :: proc(on_send_callback: Send_Data_Callback) -> ^Channel {
  result := new(Channel, context.allocator)
  result.allocator = context.allocator
  result.send_callback = on_send_callback
  err: ack.Error
  result.endpoint, err = ack.endpoint_open(channel_on_send_data, channel_on_receive_data)
  assert(err == nil)
  result.endpoint.user_data = rawptr(result)
  return result
}

channel_close :: proc(channel: ^Channel) {
  assert(channel != nil)
  err := ack.endpoint_close(channel.endpoint)
  assert(err == nil)

  for idx := channel.reliable_packet_buffer_read_pos; idx < channel.reliable_packet_buffer_write_pos; idx += 1 {
    entry := &channel.reliable_packet_buffer[idx%len(channel.reliable_packet_buffer)]
    if entry.data != nil {
      delete(entry.data, channel.allocator)
    }
  }

  free(channel, channel.allocator)
}

@(private)
channel_send_reliable_packet_immediate :: proc(channel: ^Channel, packet: ^Reliable_Packet_Buffer_Entry) {
  assert(len(packet.data) <= MAX_CHUNK_SIZE)
  num_slices := (len(packet.data) / SLICE_SIZE_CRITICAL_VALUE) + (((len(packet.data) % SLICE_SIZE_CRITICAL_VALUE) != 0) ? 1 : 0)
  assert(num_slices > 0)
  if num_slices > 1 {

    packet.waiting_for_ack = true
    num_slices = (len(packet.data) / SLICE_SIZE) + (((len(packet.data) % SLICE_SIZE) != 0) ? 1 : 0)
    chunk_sender := &channel.chunk_sender
    assert(!chunk_sender.sending)
    chunk_sender.sending = true
    chunk_sender.entry = packet
    chunk_sender.chunk_size = u32(len(packet.data))
    chunk_sender.num_slices = u16(num_slices)
    chunk_sender.num_acked_slices = 0
    chunk_sender.current_slice_id = 0
    chunk_sender.acked = {}
    chunk_sender.time_last_sent = {}
    copy(chunk_sender.chunk_data[:], packet.data)

    for slice_id in 0..<num_slices {
      packet_data := chunk_sender_make_slice_packet(chunk_sender, u8(slice_id), reliable_id = packet.id, allocator = context.temp_allocator)
      chunk_sender.time_last_sent[slice_id] = time.now()
      err := ack.endpoint_send_data(channel.endpoint, packet_data)
      assert(err == nil)
    }
  } else {
    packet.waiting_for_ack = true
    packet.last_send_time = time.now()
    packet.sequence = ack.endpoint_get_next_sequence(channel.endpoint)
    packet.past_sequences[packet.sequence] = {}
    packet_data := make_packet(.Normal, packet.data, allocator = context.temp_allocator)
    normal_packet := cast(^Normal_Packet)raw_data(packet_data)
    normal_packet.is_reliable = true
    normal_packet.id = packet.id
    add_crc32_to_packet(packet_data)
    err := ack.endpoint_send_data(channel.endpoint, packet_data)
    assert(err == nil)
  }
}

@(private)
channel_push_reliable_data :: proc(channel: ^Channel, data: []u8) {
  // TODO(hampus): Make sure that the receiver actually has space
  // in their reliable message buffer to buffer this message
  entry := &channel.reliable_packet_buffer[channel.reliable_packet_buffer_write_pos%len(channel.reliable_packet_buffer)]
  assert(!entry.waiting_for_ack)
  entry.data = slice.clone(data, channel.allocator)
  entry.id = channel.next_reliable_id_to_push
  entry.waiting_for_ack = false
  channel.reliable_packet_buffer_write_pos += 1
  channel.next_reliable_id_to_push += 1
  if channel_can_send_next_reliable_packet(channel) do channel_send_next_reliable_packet(channel)
}

channel_send_bytes :: proc(channel: ^Channel, data: []u8, is_reliable := false) {
  if is_reliable {
    channel_push_reliable_data(channel, data)
  } else {
    packet_data := make_packet(.Normal, data, allocator = context.temp_allocator)
    add_crc32_to_packet(packet_data)
    err := ack.endpoint_send_data(channel.endpoint, packet_data)
    assert(err == nil)
  }
}

channel_send_string :: proc(channel: ^Channel, str: string, is_reliable := false) {
  channel_send_bytes(channel, transmute([]u8)str, is_reliable = is_reliable)
}

channel_send_any :: proc(channel: ^Channel, v: any, is_reliable := false) {
  channel_send_bytes(channel, mem.any_to_bytes(v), is_reliable = is_reliable)
}

channel_send :: proc{channel_send_bytes, channel_send_string}

channel_receive :: proc(channel: ^Channel, data: []u8) {
  err := ack.endpoint_receive_data(channel.endpoint, data)
  assert(err == nil)
}

channel_update :: proc(channel: ^Channel, dt: f32) {
  ack.endpoint_update(channel.endpoint)

  assert(channel != nil)
  channel.received_data = make([dynamic][]u8, 0, 1024, context.temp_allocator)

  chunk_sender := &channel.chunk_sender
  if chunk_sender.sending {
    channel.chunk_sending_budget_bytes += f64(dt * AVAILABLE_BANDWIDTH_KBPS * 1024 / 8)
    for idx in 0..<chunk_sender.num_slices {
      slice_id := (chunk_sender.current_slice_id + idx) % chunk_sender.num_slices
      if !chunk_sender.acked[slice_id] {
        if channel.chunk_sending_budget_bytes >= SLICE_SIZE {
          channel.chunk_sending_budget_bytes -= SLICE_SIZE
        } else {
          chunk_sender.current_slice_id = slice_id
          break
        }
        if f32(time.duration_milliseconds(time.since(chunk_sender.time_last_sent[slice_id]))) >= (channel.endpoint.estimated_rtt_ms*1.25) {
          packet_data := chunk_sender_make_slice_packet(chunk_sender, u8(slice_id), reliable_id = chunk_sender.entry.id, allocator = context.temp_allocator)
          chunk_sender.time_last_sent[slice_id] = time.now()
          err := ack.endpoint_send_data(channel.endpoint, packet_data)
          assert(err == nil)
        }
      }
    }
  } else {
    if channel_can_send_next_reliable_packet(channel) do channel_send_next_reliable_packet(channel)

    if channel.reliable_packet_buffer_read_pos < channel.reliable_packet_buffer_write_pos {
      entry := &channel.reliable_packet_buffer[channel.reliable_packet_buffer_read_pos%len(channel.reliable_packet_buffer)]

      if !chunk_sender.sending {
        acks := ack.endpoint_get_acks(channel.endpoint)
        if entry.waiting_for_ack{
          for ack in acks {
            _, ack_for_this_packet := entry.past_sequences[ack]
            if ack_for_this_packet {
              entry.waiting_for_ack = false
              delete(entry.data, channel.allocator)
              clear(&entry.past_sequences)
              entry.data = nil
              channel.reliable_packet_buffer_read_pos += 1
            }
          }

          if entry.waiting_for_ack && f32(time.duration_milliseconds(time.since(entry.last_send_time))) >= (channel.endpoint.estimated_rtt_ms*1.5) {
            channel_send_reliable_packet_immediate(channel, entry)
          }
        }

      }
    }
  }

  ack.endpoint_clear_acks(channel.endpoint)

  if f32(time.duration_milliseconds(time.since(channel.last_keep_alive_send_time))) >= 100 {
    packet_data := make_packet(.Keep_Alive, allocator = context.temp_allocator)
    packet := cast(^Keep_Alive_Packet)raw_data(packet_data)
    add_crc32_to_packet(packet_data)
    err := ack.endpoint_send_data(channel.endpoint, packet_data)
    assert(err == nil)
    channel.last_keep_alive_send_time = time.now()
  }
}

@(require_results)
channel_get_received_data :: proc(channel: ^Channel) -> [][]u8 {
  result := channel.received_data[:]
  return result
}

@(private, require_results)
channel_can_send_next_reliable_packet :: proc(channel: ^Channel) -> bool {
  result := false
  if channel.reliable_packet_buffer_read_pos < channel.reliable_packet_buffer_write_pos {
    entry := &channel.reliable_packet_buffer[channel.reliable_packet_buffer_read_pos%len(channel.reliable_packet_buffer)]
    if !entry.waiting_for_ack {
      result = true
    }
  }
  return result
}

@(private)
channel_send_next_reliable_packet :: proc(channel: ^Channel) {
  entry := &channel.reliable_packet_buffer[channel.reliable_packet_buffer_read_pos%len(channel.reliable_packet_buffer)]
  channel_send_reliable_packet_immediate(channel, entry)
}

Perf_Stats :: struct {
  estimated_packet_loss: f32,
  estimated_rtt_ms: f32,
  estimated_sent_bandwidth: f32,
  estimated_received_bandwidth: f32,
}

@(require_results)
channel_get_perf_stats :: proc(channel: ^Channel) -> Perf_Stats {
  result := Perf_Stats {
    estimated_packet_loss = channel.endpoint.estimated_packet_loss,
    estimated_rtt_ms = channel.endpoint.estimated_rtt_ms,
    estimated_sent_bandwidth = channel.endpoint.estimated_sent_bandwidth,
    estimated_received_bandwidth = channel.endpoint.estimated_received_bandwidth,
  }
  return result
}
