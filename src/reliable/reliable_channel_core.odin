package hampuslib_reliable

import "core:mem"
import "core:log"
import "core:slice"
import "core:time"
import "core:hash"
import "core:bytes"

import "../ack"

FRAGMENT_CRITICAL_SIZE :: ack.FRAGMENT_SIZE - size_of(Reliable_Message)
FRAGMENT_SIZE :: ack.FRAGMENT_SIZE - size_of(Fragment_Message)
MAX_FRAGMENT_COUNT :: 256
MAX_CHUNK_SIZE :: MAX_FRAGMENT_COUNT * ack.FRAGMENT_SIZE

AVAILABLE_BANDWIDTH_KBPS :: 256

Error :: union #shared_nil {
  ack.Error,
}

Send_Data_Callback :: #type proc(channel: ^Channel, data: []u8)

Message_Kind :: enum {
  Unreliable,
  Reliable,
  Fragment,
  Ack,
}

Message_Base :: struct #packed {
  kind: Message_Kind,
}

Reliable_Message :: struct #packed {
  using base: Message_Base,
}

Fragment_Message :: struct #packed {
  using base: Message_Base,
  message_id: u16,
  fragment_id: u8,
  num_fragments: u8,
  fragment_size: u16,
}

Ack_Message :: struct #packed {
  using base: Message_Base,
  message_id: u16,
  acked: [2]u128,
}

Unreliable_Message :: struct #packed {
  using base: Message_Base,
}

Message_Queue_Entry :: struct {
  message_id: u16,
  data: []u8,
  last_send_time: time.Time,
  has_been_pushed_to_chunk_sender: bool,
}

Sent_Message :: struct {
  sequence: u16,
  message_ids: []u16,
}

Received_Message :: struct {
  msg_id: u16,
  data: []u8,
}

Chunk_Sender_Status :: enum {
  Ready_To_Send_New_Chunk,
  Sending,
}

Chunk_Sender :: struct {
  status: Chunk_Sender_Status,
  message_queue_entry: ^Message_Queue_Entry,
  num_fragments: int,
  num_acked_fragments: int,
  current_fragment_id: int,
  acked: [MAX_FRAGMENT_COUNT]bool,
  time_last_sent: [MAX_FRAGMENT_COUNT]time.Time,
}

Chunk_Receiver_Status :: enum {
  Ready_To_Receive_New_Chunk,
  Receiving,
}

Chunk_Receiver :: struct {
  status: Chunk_Receiver_Status,
  message_id: u16,
  chunk_size: int,
  num_fragments: int,
  num_received_fragments: int,
  received: [MAX_FRAGMENT_COUNT]bool,
  chunk_data: [MAX_CHUNK_SIZE]u8,
}

Channel :: struct {
  allocator: mem.Allocator,
  endpoint: ^ack.Endpoint,

  next_remote_sequence: u16,
  next_sequence_of_message: u16,

  send_callback: Send_Data_Callback,

  next_unacked_message_id: u16,
  next_message_id: u16,
  message_queue_buffer: [4096]Maybe(Message_Queue_Entry),

  unacked_sent_messages: [512]Maybe(Sent_Message),

  next_message_id_to_receive: u16,
  received_messages: [512]Maybe(Received_Message),

  chunk_sender_message_queue_write_pos: u64,
  chunk_sender_message_queue_read_pos: u64,
  chunk_sender_message_queue: [512]u16,
  chunk_sender_budget_bytes: f64,
  chunk_sender: Chunk_Sender,

  chunk_receiver: Chunk_Receiver,

  received_data: [dynamic][]u8,

  user_data: rawptr,
}

@(require_results)
channel_open :: proc(send_callback: Send_Data_Callback) -> ^Channel {
  channel := new(Channel, context.allocator)
  channel.allocator = context.allocator
  channel.send_callback = send_callback

  err: Error
  channel.endpoint, err = ack.endpoint_open(channel_on_send_callback, channel_on_receive_callback)
  channel.endpoint.user_data = rawptr(channel)
  assert(err == nil)

  return channel
}

channel_close :: proc(channel: ^Channel) {

  for maybe_sent_packet in channel.unacked_sent_messages {
    sent_packet, ok := maybe_sent_packet.?
    if ok {
      delete(sent_packet.message_ids)
    }
  }

  for maybe_message_queue_entry in channel.message_queue_buffer {
    message, ok := maybe_message_queue_entry.?
    if ok {
      delete(message.data)
    }
  }

  err := ack.endpoint_close(channel.endpoint)
  assert(err == nil)

  free(channel, channel.allocator)
}

channel_update :: proc(channel: ^Channel, dt: f32) {
  ack.endpoint_update(channel.endpoint)

  channel.received_data = make([dynamic][]u8, 0, 1024, context.temp_allocator)

  ids := make([dynamic]u16, 0, 128, channel.allocator)
  defer(delete(ids))

  buffer: bytes.Buffer
  bytes.buffer_init_allocator(&buffer, 0, FRAGMENT_CRITICAL_SIZE+size_of(Reliable_Message), context.temp_allocator)
  bytes.buffer_write(&buffer, mem.any_to_bytes(Message_Kind.Reliable))

  for message_id := channel.next_unacked_message_id; channel_can_send_message_id(channel, message_id); {
    for ; channel_can_send_message_id(channel, message_id); message_id += 1 {
      entry := channel_get_message_queue_entry(channel, message_id)
      if entry == nil {
        continue
      }

      if len(entry.data) > FRAGMENT_CRITICAL_SIZE && !entry.has_been_pushed_to_chunk_sender {
        assert(abs(channel.chunk_sender_message_queue_write_pos - channel.chunk_sender_message_queue_read_pos) < len(channel.chunk_sender_message_queue), "chunk queue is full!")
        channel.chunk_sender_message_queue[channel.chunk_sender_message_queue_write_pos%len(channel.chunk_sender_message_queue)] = message_id
        channel.chunk_sender_message_queue_write_pos += 1
        entry.has_been_pushed_to_chunk_sender = true
        continue
      }

      if (len(entry.data)+size_of(u16)*2) > (bytes.buffer_capacity(&buffer) - bytes.buffer_length(&buffer)) {
        continue
      }

      if f32(time.duration_milliseconds(time.since(entry.last_send_time))) >= channel.endpoint.estimated_rtt_ms*1.25 {
        bytes.buffer_write(&buffer, mem.any_to_bytes(message_id))
        bytes.buffer_write(&buffer, mem.any_to_bytes(u16(len(entry.data))))
        bytes.buffer_write(&buffer, entry.data)
        append(&ids, message_id)
      }
    }

    if len(ids) > 0 {
      sequence := ack.endpoint_get_next_sequence(channel.endpoint)

      for i in channel.next_sequence_of_message..=sequence {
        channel_clear_sent_message_slot(channel, i)
      }

      message: Sent_Message
      message.sequence = sequence
      message.message_ids = slice.clone(ids[:], channel.allocator)
      channel.unacked_sent_messages[sequence % len(channel.unacked_sent_messages)] = message

      now_time := time.now()
      for id in ids {
        entry := channel_get_message_queue_entry(channel, id)
        entry.last_send_time = now_time
      }

      err := ack.endpoint_send_data(channel.endpoint, bytes.buffer_to_bytes(&buffer))
      assert(err == nil)

      channel.next_sequence_of_message = sequence+1
    }
  }

  // update chunk sender

  {
    chunk_sender := &channel.chunk_sender
    switch chunk_sender.status {
      case .Ready_To_Send_New_Chunk:
      message_queue_entry := get_next_chunk_message_in_queue(channel)
      if message_queue_entry != nil {
        chunk_sender.num_fragments = (len(message_queue_entry.data) / FRAGMENT_SIZE) + (((len(message_queue_entry.data) % FRAGMENT_SIZE) != 0) ? 1 : 0)
        chunk_sender.num_acked_fragments = 0
        chunk_sender.current_fragment_id = 0
        chunk_sender.acked = {}
        chunk_sender.time_last_sent = {}
        chunk_sender.message_queue_entry = message_queue_entry
        chunk_sender.status = .Sending

        for fragment_id in 0..<chunk_sender.num_fragments {
          packet_data := chunk_sender_make_fragment_packet(chunk_sender, u8(fragment_id))
          chunk_sender.time_last_sent[fragment_id] = time.now()
          err := ack.endpoint_send_data(channel.endpoint, packet_data)
          assert(err == nil)
        }
      }

      case .Sending:
      channel.chunk_sender_budget_bytes += f64(dt * AVAILABLE_BANDWIDTH_KBPS * 1024 / 8)
      for idx in 0..<chunk_sender.num_fragments {
        fragment_id := (chunk_sender.current_fragment_id + idx) % chunk_sender.num_fragments
        if !chunk_sender.acked[fragment_id] {
          if channel.chunk_sender_budget_bytes >= FRAGMENT_SIZE {
            channel.chunk_sender_budget_bytes -= FRAGMENT_SIZE
          } else {
            chunk_sender.current_fragment_id = fragment_id
            break
          }
          if f32(time.duration_milliseconds(time.since(chunk_sender.time_last_sent[fragment_id]))) >= (channel.endpoint.estimated_rtt_ms*1.25) {
            packet_data := chunk_sender_make_fragment_packet(chunk_sender, u8(fragment_id), allocator = context.temp_allocator)
            chunk_sender.time_last_sent[fragment_id] = time.now()
            err := ack.endpoint_send_data(channel.endpoint, packet_data)
            assert(err == nil)
          }
        }
      }
    }
  }

  acks := ack.endpoint_get_acks(channel.endpoint)

  for ack in acks {
    sent_message := channel_get_unacked_sent_message(channel, ack)
    if sent_message != nil {
      for message_id in sent_message.message_ids {
        channel_clear_message_queue_entry(channel, message_id)
      }

      channel_clear_sent_message(channel, ack)
    }
  }

  ack.endpoint_clear_acks(channel.endpoint)

  for message_id := channel.next_unacked_message_id; ack.sequence_less_than(message_id, channel.next_message_id); message_id += 1 {
    entry := channel_get_message_queue_entry(channel, message_id)
    if entry == nil {
      channel.next_unacked_message_id = message_id+1
    } else {
      break
    }
  }
}

channel_send :: proc(channel: ^Channel, data: []u8, is_reliable := false) {
  if is_reliable {
    existing_entry, exists := &channel.message_queue_buffer[channel.next_message_id%len(channel.message_queue_buffer)].?
    assert(!exists, "the message queue is full!")
    channel.message_queue_buffer[channel.next_message_id%len(channel.message_queue_buffer)] = Message_Queue_Entry {
      data = slice.clone(data, allocator = channel.allocator),
      message_id = channel.next_message_id
    }
    channel.next_message_id += 1
  } else {
    buffer: bytes.Buffer
    bytes.buffer_init_allocator(&buffer, 0, len(data)+size_of(Unreliable_Message), context.temp_allocator)
    bytes.buffer_write(&buffer, mem.any_to_bytes(Message_Kind.Unreliable))
    bytes.buffer_write(&buffer, data)
    err := ack.endpoint_send_data(channel.endpoint, bytes.buffer_to_bytes(&buffer))
    assert(err == nil)
  }
}

channel_receive :: proc(channel: ^Channel, data: []u8) {
  err := ack.endpoint_receive_data(channel.endpoint, data)
  assert(err == nil)
}

@(require_results)
channel_get_received_data :: proc(channel: ^Channel) -> [][]u8 {
  return channel.received_data[:]
}

@(private, require_results)
channel_get_message_queue_entry :: proc(channel: ^Channel, id: u16) -> ^Message_Queue_Entry {
  result, ok := &channel.message_queue_buffer[id%len(channel.message_queue_buffer)].?
  if ok {
    if result.message_id != id {
      result = nil
    }
  }
  return result
}

@(private)
channel_clear_message_queue_entry :: proc(channel: ^Channel, id: u16) {
  result, ok := channel.message_queue_buffer[id%len(channel.message_queue_buffer)].?
  if ok {
    if result.message_id == id {
      delete(result.data)
      channel.message_queue_buffer[id%len(channel.message_queue_buffer)] = nil
    }
  }
}

@(private, require_results)
channel_get_unacked_sent_message :: proc(channel: ^Channel, sequence: u16) -> ^Sent_Message {
  sent_message, ok := &channel.unacked_sent_messages[sequence % len(channel.unacked_sent_messages)].?
  if ok {
    if sent_message.sequence == sequence do return sent_message
  }
  return nil
}

@(private)
channel_clear_sent_message :: proc(channel: ^Channel, sequence: u16) {
  sent_message, ok := &channel.unacked_sent_messages[sequence % len(channel.unacked_sent_messages)].?
  if ok {
    if sent_message.sequence == sequence {
      delete(sent_message.message_ids)
      channel.unacked_sent_messages[sequence % len(channel.unacked_sent_messages)] = nil
    }
  }
}

@(private)
channel_clear_sent_message_slot :: proc(channel: ^Channel, slot: u16) {
  sent_message, ok := &channel.unacked_sent_messages[slot % len(channel.unacked_sent_messages)].?
  if ok {
    delete(sent_message.message_ids)
    channel.unacked_sent_messages[slot % len(channel.unacked_sent_messages)] = nil
  }
}

@(private)
channel_on_receive_callback :: proc(endpoint: ^ack.Endpoint, sequence: u16, message_data: []u8) -> bool {
  channel := cast(^Channel)endpoint.user_data

  buffer: bytes.Buffer
  bytes.buffer_init_allocator(&buffer, 0, len(message_data), context.temp_allocator)
  bytes.buffer_write(&buffer, message_data)

  message_kind: Message_Kind

  bytes.buffer_read(&buffer, mem.any_to_bytes(message_kind))

  switch message_kind {
    case .Ack:
    if ack.sequence_greater_than(sequence, channel.next_remote_sequence-1) {
      channel.next_remote_sequence = sequence+1
    }
    chunk_sender := &channel.chunk_sender
    if chunk_sender.status == .Sending {
      packet: Ack_Message
      message_id: u16
      acked: [2]u128
      n, err := bytes.buffer_read(&buffer, mem.any_to_bytes(packet.message_id))
      assert(err == nil && n == size_of(packet.message_id))
      n, err = bytes.buffer_read(&buffer, mem.any_to_bytes(packet.acked))
      assert(err == nil && n == size_of(packet.acked))
      if packet.message_id == chunk_sender.message_queue_entry.message_id  {
        for bit: u32 = 0; bit < 128; bit += 1 {
          if (!chunk_sender.acked[bit] && (packet.acked[0] & (1 << bit)) != 0) {
            chunk_sender.acked[bit] = true
            chunk_sender.num_acked_fragments += 1
          }
          if (!chunk_sender.acked[128+bit] && (packet.acked[1] & (1 << bit)) != 0) {
            chunk_sender.acked[128+bit] = true
            chunk_sender.num_acked_fragments += 1
          }
        }
      }
      if chunk_sender.num_acked_fragments == chunk_sender.num_fragments {
        channel_clear_message_queue_entry(channel, chunk_sender.message_queue_entry.message_id)
        channel.chunk_sender_message_queue_read_pos += 1
        chunk_sender.status = .Ready_To_Send_New_Chunk
      }
    }

    case .Fragment:
    if ack.sequence_greater_than(sequence, channel.next_remote_sequence-1) {
      channel.next_remote_sequence = sequence+1
    }
    chunk_receiver := &channel.chunk_receiver
    packet: Fragment_Message
    n, err := bytes.buffer_read(&buffer, mem.any_to_bytes(packet.message_id))
    assert(err == nil && n == size_of(packet.message_id))
    n, err = bytes.buffer_read(&buffer, mem.any_to_bytes(packet.fragment_id))
    assert(err == nil && n == size_of(packet.fragment_id))
    n, err = bytes.buffer_read(&buffer, mem.any_to_bytes(packet.num_fragments))
    assert(err == nil && n == size_of(packet.num_fragments))
    n, err = bytes.buffer_read(&buffer, mem.any_to_bytes(packet.fragment_size))
    assert(err == nil && n == size_of(packet.fragment_size))
    switch chunk_receiver.status {
      case .Ready_To_Receive_New_Chunk:
      if ack.sequence_less_than(packet.message_id, channel.next_message_id_to_receive) {
        // We have received all the slices but all our acks has
        // not gone through
        ack_packet := chunk_receiver_make_ack_packet(chunk_receiver, packet.message_id)
        err := ack.endpoint_send_data(endpoint, ack_packet)
        assert(err == nil)
        break
      }

      chunk_receiver.chunk_size = 0
      chunk_receiver.message_id = packet.message_id
      chunk_receiver.num_received_fragments = 0
      chunk_receiver.received = {}
      chunk_receiver.num_fragments = int(packet.num_fragments)
      chunk_receiver.status = .Receiving

      fallthrough

      case .Receiving:
      if packet.message_id == chunk_receiver.message_id {
        is_duplicate_fragment := chunk_receiver.received[packet.fragment_id]
        if !is_duplicate_fragment {
          chunk_receiver.num_received_fragments += 1
          chunk_receiver.chunk_size += int(packet.fragment_size)
          chunk_receiver.received[packet.fragment_id] = true

          n, err = bytes.buffer_read(&buffer, chunk_receiver.chunk_data[u32(packet.fragment_id)*FRAGMENT_SIZE:(u32(packet.fragment_id)+1)*FRAGMENT_SIZE])
          assert(err == nil)
        }

        ack_packet := chunk_receiver_make_ack_packet(chunk_receiver, chunk_receiver.message_id)
        err := ack.endpoint_send_data(channel.endpoint, ack_packet)
        assert(err == nil)

        if chunk_receiver.num_received_fragments == chunk_receiver.num_fragments {
          msg_data := slice.clone(chunk_receiver.chunk_data[:chunk_receiver.chunk_size], context.allocator)
          received_message: Received_Message
          received_message.data = msg_data
          received_message.msg_id = chunk_receiver.message_id
          channel.received_messages[chunk_receiver.message_id%len(channel.received_messages)] = received_message
          chunk_receiver.status = .Ready_To_Receive_New_Chunk
        }
      }
    }

    case .Reliable:
    if ack.sequence_greater_than(sequence, channel.next_remote_sequence-1) {
      channel.next_remote_sequence = sequence+1
    }

    for bytes.buffer_length(&buffer) > 0 {
      msg_id: u16
      bytes.buffer_read(&buffer, mem.any_to_bytes(msg_id))
      msg_size: u16
      bytes.buffer_read(&buffer, mem.any_to_bytes(msg_size))
      if ack.sequence_less_than(msg_id, channel.next_message_id_to_receive) {
        buffer.off += int(msg_size)
        continue
      }

      received_msg, ok := &channel.received_messages[msg_id%len(channel.received_messages)].?
      if ok {
        assert(received_msg.msg_id == msg_id)
      }
      if !ok {
        msg_data := make([]u8, msg_size, channel.allocator)
        bytes.buffer_read(&buffer, msg_data)
        received_message: Received_Message
        received_message.data = msg_data
        received_message.msg_id = msg_id
        channel.received_messages[msg_id%len(channel.received_messages)] = received_message
      } else {
        buffer.off += int(msg_size)
      }
    }

    case .Unreliable:
    if !ack.sequence_greater_than(sequence, channel.next_remote_sequence-1) {
      return false
    }
    channel.next_remote_sequence = sequence+1

    data := slice.clone(message_data[size_of(Unreliable_Message):], context.temp_allocator)
    append(&channel.received_data, data)
  }

  stop := false
  for !stop {
    received_msg, ok := &channel.received_messages[channel.next_message_id_to_receive%len(channel.received_messages)].?
    if ok {
      if received_msg.msg_id == channel.next_message_id_to_receive {
        channel.next_message_id_to_receive = received_msg.msg_id+1
        append(&channel.received_data, slice.clone(received_msg.data, context.temp_allocator))
        delete(received_msg.data, channel.allocator)
        channel.received_messages[received_msg.msg_id%len(channel.received_messages)] = nil
      } else {
        stop = true
      }
    } else {
      stop = true
    }
  }

  return true
}

@(private)
channel_on_send_callback :: proc(endpoint: ^ack.Endpoint, data: []u8) {
  channel := cast(^Channel)endpoint.user_data
  channel.send_callback(channel, data)
}

@(private)
channel_can_send_message_id :: proc(channel: ^Channel, message_id: u16) -> bool {
  result := ack.sequence_less_than(message_id, channel.next_message_id) && ack.sequence_less_than(message_id, channel.next_unacked_message_id + len(channel.received_messages))
  return result
}

@(private)
get_next_chunk_message_in_queue :: proc(channel: ^Channel) -> ^Message_Queue_Entry {
  result: ^Message_Queue_Entry
  if channel.chunk_sender_message_queue_read_pos < channel.chunk_sender_message_queue_write_pos {
    result = channel_get_message_queue_entry(channel, channel.chunk_sender_message_queue[channel.chunk_sender_message_queue_read_pos%len(channel.chunk_sender_message_queue)])
  }
  return result
}

@(private, require_results)
chunk_sender_make_fragment_packet :: proc(chunk_sender: ^Chunk_Sender, fragment_id: u8, allocator := context.temp_allocator, loc := #caller_location) -> []u8 {
  fragment_size := 0
  message_queue_entry := chunk_sender.message_queue_entry
  if (len(message_queue_entry.data) - (int(fragment_id) * FRAGMENT_SIZE)) < FRAGMENT_SIZE {
    fragment_size = int(len(message_queue_entry.data) % FRAGMENT_SIZE)
  } else {
    fragment_size = FRAGMENT_SIZE
  }

  packet_data := make([]u8, fragment_size + size_of(Fragment_Message), allocator, loc)
  fragment_packet := cast(^Fragment_Message)raw_data(packet_data)
  fragment_packet.kind = .Fragment
  fragment_packet.message_id = message_queue_entry.message_id
  fragment_packet.fragment_id = u8(fragment_id)
  fragment_packet.num_fragments = u8(chunk_sender.num_fragments)
  fragment_packet.fragment_size = u16(fragment_size)
  copy(packet_data[size_of(Fragment_Message):], message_queue_entry.data[int(fragment_id)*FRAGMENT_SIZE:int(fragment_id)*FRAGMENT_SIZE+fragment_size])

  return packet_data
}

@(private, require_results)
chunk_receiver_make_ack_packet :: proc(chunk_receiver: ^Chunk_Receiver, message_id: u16) -> []u8 {

  packet_data := make([]u8, size_of(Ack_Message), context.temp_allocator)
  packet := cast(^Ack_Message)raw_data(packet_data)
  packet.kind = .Ack
  packet.message_id = message_id

  for fragment_id in 0..<min(128, chunk_receiver.num_fragments) {
    if chunk_receiver.received[fragment_id] {
      packet.acked[0] |= 1 << u32(fragment_id)
    }
  }

  for fragment_id in 128..<chunk_receiver.num_fragments {
    if chunk_receiver.received[fragment_id] {
      packet.acked[1] |= 1 << (u32(fragment_id) - 128)
    }
  }

  return packet_data
}