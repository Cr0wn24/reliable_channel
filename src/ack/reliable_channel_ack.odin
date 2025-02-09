package reliable_channel_ack_tests

import "base:runtime"

import "core:log"
import "core:time"
import "core:mem"
import "core:os"

FRAGMENT_SIZE :: 1024
MAX_FRAGMENT_COUNT :: 256
MAX_PACKET_SIZE :: MAX_FRAGMENT_COUNT * FRAGMENT_SIZE

@(require_results)
sequence_greater_than :: proc(s1, s2: u16) -> bool {
  result := ((s1 > s2) && (s1 - s2 <= 32768)) || ((s1 < s2) && (s2 - s1 > 32768))
  return result
}

@(require_results)
sequence_less_than :: proc(s1, s2: u16) -> bool {
  result := sequence_greater_than(s2, s1)
  return result
}

Send_Data_Callback :: #type proc(ep: ^Endpoint, packet_data: []u8)
Receive_Data_Callback :: #type proc(ep: ^Endpoint, sequence: u16, data: []u8) -> bool

Received_Packet :: struct {
  sequence: u16,
}

Sent_Packet :: struct {
  sequence: u16,
  send_time: time.Time,
  acked: bool,
}

Fragment_Packet_Reassembly_Buffer_Entry :: struct {
  num_fragments: int,
  num_fragments_received: int,
  data_size: int,
  sequence: u16,
  fragment_received: [MAX_FRAGMENT_COUNT]bool,
  packet_data: []u8,
}

Endpoint :: struct {
  sequence: u16,
  send_callback: Send_Data_Callback,
  receive_callback: Receive_Data_Callback,

  received_packets_buffer_sequence: u16,
  received_packets_buffer: [4096]Maybe(Received_Packet),

  sent_packets_buffer: [4096]Maybe(Sent_Packet),

  packet_fragment_reassembly_buffer_sequence: u16,
  packet_fragment_reassembly_buffer: [4096]Maybe(Fragment_Packet_Reassembly_Buffer_Entry),

  acks: [dynamic]u16,

  start_measure_time: time.Time,

  estimated_packet_loss: f32,
  estimated_rtt_ms: f32,
  estimated_sent_bandwidth: f32,
  estimated_received_bandwidth: f32,

  rtt_accumulator_ms: f32,

  num_sent_packets: int,
  num_acked_packets: int,
  num_bytes_sent: int,
  num_bytes_received: int,

  user_data: rawptr,

  allocator: mem.Allocator,
}

Packet_Kind :: enum {
  Normal,
  Fragment,
}

Packet :: struct {
  kind: Packet_Kind,
  sequence: u16,
  ack: u16,
  ack_bits: u32,
}

Fragment_Packet :: struct {
  using base: Packet,
  fragment_id: u8,
  num_fragments: u16,
}

General_Error :: enum {
  Invalid_Send_Callback,
  Invalid_Receive_Callback,
  Empty_Data,
}

Error :: union #shared_nil {
  General_Error,
  mem.Allocator_Error,
}

@require_results
error_string :: proc(err: Error) -> string {
  if err == nil {
    return ""
  }

  switch e in err {
    case mem.Allocator_Error: return os.error_string(e)

    case General_Error:
    switch e {
      case .Invalid_Send_Callback: return "invalid send callback"
      case .Invalid_Receive_Callback: return "invalid receive callback"
      case .Empty_Data: return "tried to send empty_data"
    }
  }

  return "unknown error"
}

@require_results
endpoint_open :: proc(send_callback: Send_Data_Callback, receive_callback: Receive_Data_Callback) -> (result: ^Endpoint, err: Error) {
  if send_callback == nil {
    return nil, .Invalid_Send_Callback
  }
  if receive_callback == nil {
    return nil, .Invalid_Receive_Callback
  }

  result = new(Endpoint, context.allocator) or_return
  result.allocator = context.allocator
  result.acks = make([dynamic]u16, 0, 1024, result.allocator) or_return
  result.send_callback = send_callback
  result.receive_callback = receive_callback
  result.estimated_rtt_ms = 1000

  return
}

@require_results
endpoint_close :: proc(ep: ^Endpoint) -> Error {
  assert(ep != nil)

  delete(ep.acks) or_return

  for &elem in ep.packet_fragment_reassembly_buffer {
    if entry, ok := elem.?; ok {
      delete(entry.packet_data, context.allocator)
    }
  }

  free(ep, ep.allocator) or_return
  return nil
}

endpoint_reset :: proc(ep: ^Endpoint) {
  assert(ep != nil)

  ep.sequence = 0

  ep.received_packets_buffer_sequence = 0
  ep.received_packets_buffer = {}

  ep.sent_packets_buffer = {}

  ep.packet_fragment_reassembly_buffer_sequence = 0
  ep.packet_fragment_reassembly_buffer = {}

  clear(&ep.acks)

  ep.start_measure_time = {}
  ep.estimated_packet_loss = 0
  ep.estimated_rtt_ms = 0
  ep.rtt_accumulator_ms = 0
  ep.num_sent_packets = 0
  ep.num_acked_packets = 0

  for &elem in ep.received_packets_buffer {
    elem = nil
  }

  for &elem in ep.sent_packets_buffer {
    elem = nil
  }

  for &elem in ep.packet_fragment_reassembly_buffer {
    elem = nil
  }
}

@require_results
endpoint_get_next_sequence :: proc(ep: ^Endpoint) -> u16 {
  assert(ep != nil)
  return ep.sequence
}

@require_results
endpoint_send_data :: proc(ep: ^Endpoint, data: []u8) -> (err: Error) {
  assert(ep != nil)
  assert(len(data) <= MAX_PACKET_SIZE)

  if len(data) > 0 {
    fragment_count := (len(data) / FRAGMENT_SIZE) + (((len(data) % FRAGMENT_SIZE) != 0) ? 1 : 0)
    assert(fragment_count <= MAX_FRAGMENT_COUNT)

    sequence := ep.sequence

    // generate ack bits

    ack: u16
    ack_bits: u32
    {
      ack = ep.received_packets_buffer_sequence - 1

      for idx in 0..<32 {
        ack_sequence := int(ack) - idx
        if ack_sequence >= 0 {
          sequence_buffer_idx := ack_sequence%len(ep.received_packets_buffer)
          received_packet, ok := &ep.received_packets_buffer[sequence_buffer_idx].?
          if ok && received_packet.sequence == u16(ack_sequence) {
            ack_bits |= (1 << u32(idx))
          }
        }
      }
    }

    // insert a sent packet into sequence buffer, so we later can
    // see if it is acked or not

    sent_packet := Sent_Packet{
      sequence = sequence,
      acked = false,
      send_time = time.now(),
    }

    ep.sent_packets_buffer[sequence%len(ep.sent_packets_buffer)] = sent_packet

    if fragment_count == 1 {

      // normal packet

      packet_data: []u8
      packet_data = make([]u8, size_of(Packet) + len(data), context.temp_allocator) or_return
      packet := cast(^Packet)raw_data(packet_data)
      runtime.copy(packet_data[size_of(Packet):], data)
      packet.kind = .Normal
      packet.sequence = sequence
      packet.ack = ack
      packet.ack_bits = ack_bits
      ep.send_callback(ep, packet_data)
      ep.num_bytes_sent += len(packet_data)
    } else if fragment_count > 1 {

      // this packet requires multiple fragments, we have to do extra work

      for fragment_id in 0..<fragment_count {

        // calculate the size of this fragment

        fragment_size := 0
        if (len(data) - (fragment_id) * FRAGMENT_SIZE) < FRAGMENT_SIZE {
          fragment_size = len(data) % FRAGMENT_SIZE
        } else {
          fragment_size = FRAGMENT_SIZE
        }
        packet_data: []u8
        packet_data = make([]u8, size_of(Fragment_Packet) + fragment_size, allocator = context.temp_allocator) or_return

        // fill in fragment data

        packet := cast(^Fragment_Packet)raw_data(packet_data)
        packet.kind = .Fragment
        packet.sequence = sequence
        packet.fragment_id = u8(fragment_id)
        packet.num_fragments = u16(fragment_count)
        packet.ack = ack
        packet.ack_bits = ack_bits

        min_data_idx := fragment_id*FRAGMENT_SIZE
        max_data_idx := min_data_idx + fragment_size
        runtime.copy(packet_data[size_of(Fragment_Packet):], data[min_data_idx:max_data_idx])

        // send

        ep.send_callback(ep, packet_data)
        ep.num_bytes_sent += len(packet_data)
      }
    }

    ep.num_sent_packets += 1
    ep.sequence += 1
  } else {
    return .Empty_Data
  }

  return nil
}

@require_results
endpoint_receive_data :: proc(ep: ^Endpoint, packet_data: []u8) -> Error {
  assert(ep != nil)

  ep.num_bytes_received += len(packet_data)

  receive_time := time.now()

  // process acks

  {
    packet := cast(^Packet)raw_data(packet_data)
    for idx in 0..<32 {
      ack_sequence := int(packet.ack) - idx
      if ack_sequence >= 0 {
        if (packet.ack_bits & (1 << u32(idx))) != 0 {
          sequence_buffer_idx := ack_sequence%len(ep.sent_packets_buffer)
          if sent_packet, ok := &ep.sent_packets_buffer[sequence_buffer_idx].?; ok {
            if !sent_packet.acked && int(sent_packet.sequence) == ack_sequence {
              sent_packet.acked = true
              append(&ep.acks, u16(ack_sequence))
              ep.num_acked_packets += 1
              ep.rtt_accumulator_ms += f32(time.duration_milliseconds(time.diff(sent_packet.send_time, receive_time)))
            }
          }
        }
      }
    }
  }

  // process packet data

  packet_kind := (cast(^Packet_Kind)raw_data(packet_data))^

  if packet_kind == .Normal {

    // ignore very late packets so they don't override our more recent packets

    packet := cast(^Packet)raw_data(packet_data)
    if int(packet.sequence) < (int(ep.received_packets_buffer_sequence) - len(ep.received_packets_buffer)) {
      log.error("Ignoring stale packet:", packet.sequence)
      return nil
    }

    // process packet data

    if ep.receive_callback(ep, packet.sequence, packet_data[size_of(Packet):]) {

      if sequence_greater_than(packet.sequence+1, ep.received_packets_buffer_sequence) {
        min_idx := ep.received_packets_buffer_sequence
        max_idx := packet.sequence
        for idx in min_idx..=max_idx {
          ep.received_packets_buffer[idx % len(ep.received_packets_buffer)] = nil
        }

        ep.received_packets_buffer_sequence = packet.sequence + 1
      }

      received_packet := Received_Packet {
        sequence = packet.sequence,
      }

      ep.received_packets_buffer[packet.sequence%len(ep.received_packets_buffer)] = received_packet

    } else {
      log.info("Packet", packet.sequence, " was not valid. Ignoring it")
    }

  } else if packet_kind == .Fragment {
    packet := cast(^Fragment_Packet)raw_data(packet_data)
    if int(packet.sequence) < (int(ep.packet_fragment_reassembly_buffer_sequence) - len(ep.packet_fragment_reassembly_buffer)) {
      log.error("Ignoring stale packet:", packet.sequence)
      return nil
    }

    if sequence_greater_than(packet.sequence+1, ep.packet_fragment_reassembly_buffer_sequence) {
      min_idx := ep.packet_fragment_reassembly_buffer_sequence
      max_idx := packet.sequence
      for idx in min_idx..=max_idx {
        entry, ok := &ep.packet_fragment_reassembly_buffer[packet.sequence%len(ep.packet_fragment_reassembly_buffer)].?
        if ok {
          if entry.packet_data != nil {
            delete(entry.packet_data, ep.allocator)
            entry.packet_data = nil
          }
        }
        ep.packet_fragment_reassembly_buffer[idx % len(ep.packet_fragment_reassembly_buffer)] = nil
      }

      ep.packet_fragment_reassembly_buffer_sequence = packet.sequence + 1
    }

    entry, ok := &ep.packet_fragment_reassembly_buffer[packet.sequence%len(ep.packet_fragment_reassembly_buffer)].?
    create_new_entry := true
    if ok {
      create_new_entry = entry.sequence != packet.sequence
    }
    if create_new_entry {

      ep.packet_fragment_reassembly_buffer[packet.sequence%len(ep.packet_fragment_reassembly_buffer)] = Fragment_Packet_Reassembly_Buffer_Entry {}
      entry = &ep.packet_fragment_reassembly_buffer[packet.sequence%len(ep.packet_fragment_reassembly_buffer)].?

      entry.sequence = packet.sequence
      entry.num_fragments = int(packet.num_fragments)
      entry.packet_data = make([]u8, size_of(Packet)+int(entry.num_fragments)*FRAGMENT_SIZE, allocator = ep.allocator) or_return

      entry_packet := cast(^Packet)raw_data(entry.packet_data)
      entry_packet.kind = .Normal
      entry_packet.sequence = packet.sequence
      entry_packet.ack = packet.ack
      entry_packet.ack_bits = packet.ack_bits
    }

    is_duplicate_fragment := entry.fragment_received[packet.fragment_id]
    if !is_duplicate_fragment {
      data := packet_data[size_of(Fragment_Packet):]
      entry.data_size += len(data)
      entry_data := entry.packet_data[size_of(Packet):]
      runtime.copy(entry_data[int(packet.fragment_id)*FRAGMENT_SIZE:(int(packet.fragment_id)+1)*(FRAGMENT_SIZE)], data)
      entry.num_fragments_received += 1
      entry.fragment_received[packet.fragment_id] = true
      if entry.num_fragments_received == entry.num_fragments {
        err := endpoint_receive_data(ep, entry.packet_data[:entry.data_size+size_of(Packet)])
        assert(err == nil)
        delete(entry.packet_data, ep.allocator)
        entry.packet_data = nil
      }
    }
  }

  return nil
}

endpoint_update :: proc(ep: ^Endpoint) {
  if time.duration_seconds(time.since(ep.start_measure_time)) >= 1 {

    ep.estimated_received_bandwidth = 0
    ep.estimated_sent_bandwidth = 0

    if ep.num_sent_packets != 0 {
      ep.estimated_packet_loss = 1 - f32(ep.num_acked_packets) / f32(ep.num_sent_packets)
      ep.estimated_packet_loss = clamp(0, ep.estimated_packet_loss, 1)
    }

    if ep.num_acked_packets != 0 {
      ep.estimated_rtt_ms = ep.rtt_accumulator_ms / f32(ep.num_acked_packets)
    }

    if ep.num_bytes_sent != 0 {
      ep.estimated_sent_bandwidth = f32(ep.num_bytes_sent)
    }

    if ep.num_bytes_received != 0 {
      ep.estimated_received_bandwidth = f32(ep.num_bytes_received)
    }

    ep.num_bytes_sent = 0
    ep.num_bytes_received = 0
    ep.num_acked_packets = 0
    ep.num_sent_packets = 0
    ep.rtt_accumulator_ms = 0
    ep.start_measure_time = time.now()
  }
}

@require_results
endpoint_get_acks :: proc(ep: ^Endpoint) -> []u16 {
  result := ep.acks[:]
  return result
}

endpoint_clear_acks :: proc(ep: ^Endpoint) {
  clear(&ep.acks)
}
