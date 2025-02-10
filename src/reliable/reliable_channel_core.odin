package hampuslib_reliable

import "core:mem"
import "core:log"
import "core:slice"
import "core:time"
import "core:hash"
import "core:bytes"

import "../ack"

FRAGMENT_SIZE :: ack.FRAGMENT_SIZE - size_of(Reliable_Message)

Error :: union #shared_nil {
  ack.Error,
}

Send_Data_Callback :: #type proc(channel: ^Channel, data: []u8)

Message_Kind :: enum {
  Unreliable,
  Reliable,
}

Message_Base :: struct {
  kind: Message_Kind,
}

Reliable_Message :: struct {
  using base: Message_Base,
}

Unreliable_Message :: struct {
  using base: Message_Base,
}

Message_Queue_Entry :: struct {
  message_id: u16,
  data: []u8,
  last_send_time: time.Time,
}

Sent_Message :: struct {
  sequence: u16,
  message_ids: []u16,
}

Received_Message :: struct {
  msg_id: u16,
  data: []u8,
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
  bytes.buffer_init_allocator(&buffer, 0, FRAGMENT_SIZE+size_of(Reliable_Message), context.temp_allocator)
  bytes.buffer_write(&buffer, mem.any_to_bytes(Message_Kind.Reliable))

  for message_id := channel.next_unacked_message_id; channel_can_send_message_id(channel, message_id); {
    for ; channel_can_send_message_id(channel, message_id); message_id += 1 {
      entry := channel_get_message_queue_entry(channel, message_id)
      if entry == nil {
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