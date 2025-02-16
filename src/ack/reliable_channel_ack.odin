package reliable_channel_ack_tests

import "base:runtime"

import "core:log"
import "core:time"
import "core:mem"
import "core:os"
import "core:math"
import "core:math/bits"

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
  size: int,
  receive_time: time.Time,
}

Sent_Packet :: struct {
  sequence: u16,
  send_time: time.Time,
  acked: bool,
  size: int,
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
  received_packets_buffer: [512]Maybe(Received_Packet),

  sent_packets_buffer: [512]Maybe(Sent_Packet),

  packet_fragment_reassembly_buffer_sequence: u16,
  packet_fragment_reassembly_buffer: [512]Maybe(Fragment_Packet_Reassembly_Buffer_Entry),

  acks: [dynamic]u16,

  rtt_history_buffer: [dynamic]f64,

  start_measure_time: time.Time,

  packet_loss: f64,
  rtt_avg: f64,
  rtt_min: f64,
  rtt_max: f64,
  jitter_avg_vs_min_rtt: f64,
  jitter_max_vs_min_rtt: f64,
  jitter_stddev_vs_avg_rtt: f64,
  incoming_bandwidth_kbps: f64,
  outgoing_bandwidth_kbps: f64,
  num_sent_packets: int,

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
      case .Empty_Data: return "tried to send empty data"
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

  result.rtt_history_buffer = make([dynamic]f64, 0, 4096)

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
  clear(&ep.rtt_history_buffer)

  ep.packet_loss = 0
  ep.rtt_avg = 0
  ep.rtt_min = 0
  ep.rtt_max = 0
  ep.jitter_avg_vs_min_rtt = 0
  ep.jitter_max_vs_min_rtt = 0
  ep.jitter_stddev_vs_avg_rtt = 0
  ep.incoming_bandwidth_kbps = 0
  ep.outgoing_bandwidth_kbps = 0
  ep.num_sent_packets = 0

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

    ep.sent_packets_buffer[sequence%len(ep.sent_packets_buffer)] = Sent_Packet {
      sequence = sequence,
      acked = false,
      send_time = time.now(),
    }
    sent_packet := &ep.sent_packets_buffer[sequence%len(ep.sent_packets_buffer)].?


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
      sent_packet.size += len(packet_data)
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

      sent_packet.size += len(packet_data)
      }
    }

    ep.sequence += 1
  } else {
    return .Empty_Data
  }

  return nil
}

@require_results
endpoint_receive_data :: proc(ep: ^Endpoint, packet_data: []u8) -> Error {
  assert(ep != nil)


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
              rtt := time.duration_seconds(time.diff(sent_packet.send_time, receive_time))
              assert(rtt >= 0)
              append(&ep.rtt_history_buffer, rtt)
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
    if sequence_less_than(packet.sequence, ep.received_packets_buffer_sequence - len(ep.received_packets_buffer)) {
      log.error("Ignoring stale packet:", packet.sequence)
      return nil
    }

    // process packet data

    if ep.receive_callback(ep, packet.sequence, packet_data[size_of(Packet):]) {

      if sequence_greater_than(packet.sequence+1, ep.received_packets_buffer_sequence) {
        min_idx := ep.received_packets_buffer_sequence
        max_idx := packet.sequence
        for idx in ep.received_packets_buffer_sequence..=packet.sequence {
          ep.received_packets_buffer[idx % len(ep.received_packets_buffer)] = nil
        }

        ep.received_packets_buffer_sequence = packet.sequence + 1
      }

      received_packet := Received_Packet {
        sequence = packet.sequence,
        size = len(packet_data),
        receive_time = receive_time,
      }

      ep.received_packets_buffer[packet.sequence%len(ep.received_packets_buffer)] = received_packet

    } else {
      log.info("Packet", packet.sequence, "was not valid. Ignoring it")
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

endpoint_num_packets_sent_during_last_rtt :: proc(ep: ^Endpoint) -> (result: int) {
  for i in 0..<len(ep.sent_packets_buffer) {
    sequence := ep.sequence - 1 - u16(i)
    sent_packet, ok := ep.sent_packets_buffer[sequence%len(ep.sent_packets_buffer)].?

    if ok {
      if sent_packet.sequence == sequence {
        time_since_send := time.duration_seconds(time.since(sent_packet.send_time))
        if time_since_send >= ep.rtt_avg {
          break
        }

        result += 1
      }
    }

  }
  return
}

endpoint_update :: proc(ep: ^Endpoint) {
  now_time := time.now()
  duration_seconds_since_last_measure_time := time.duration_seconds(time.diff(ep.start_measure_time, now_time))
  measure_period := 1.0
  smoothing_factor := 0.1
  if duration_seconds_since_last_measure_time >= measure_period {

    // calculate min and max rtt
    {
      rtt_min := math.INF_F64
      rtt_max: f64
      sum_rtt: f64

      for rtt in ep.rtt_history_buffer {
        rtt_min = min(rtt, rtt_min)
        rtt_max = max(rtt, rtt_max)

        sum_rtt += rtt
      }

      if rtt_min == math.INF_F64 do rtt_min = 0

      ep.rtt_min = rtt_min
      ep.rtt_max = rtt_max
      if len(ep.rtt_history_buffer) != 0 {
        ep.rtt_avg = sum_rtt / f64(len(ep.rtt_history_buffer))
      } else {
        ep.rtt_avg = 0
      }
    }

    // calculate avg vs min rtt jitter
    {
      sum: f64
      for rtt in ep.rtt_history_buffer {
        sum += rtt - ep.rtt_min
      }

      if len(ep.rtt_history_buffer) > 0 {
        ep.jitter_avg_vs_min_rtt = sum / f64(len(ep.rtt_history_buffer))
      } else {
        ep.jitter_avg_vs_min_rtt = 0
      }
    }

    // calculate max vs min rtt
    {
      v: f64
      for rtt in ep.rtt_history_buffer {
        difference := rtt - ep.rtt_min
        v = max(v, difference)
      }

      ep.jitter_max_vs_min_rtt = v
    }

    // calculate standard deviation for rtt vs avg rtt
    {
      sum: f64
      for rtt in ep.rtt_history_buffer {
        deviation := rtt - ep.rtt_avg
        sum += deviation*deviation
      }

      if len(ep.rtt_history_buffer) > 0 {
        ep.jitter_stddev_vs_avg_rtt = math.sqrt(sum / f64(len(ep.rtt_history_buffer)))
      } else {
        ep.jitter_stddev_vs_avg_rtt = 0
      }
    }

    // calculate packet loss
    {
      num_sent: int
      num_dropped: int

      for i in 0..<len(ep.sent_packets_buffer) {
        sequence := ep.sequence - 1 - u16(i)
        sent_packet, ok := &ep.sent_packets_buffer[sequence%len(ep.sent_packets_buffer)].?
        if ok {
          if time.duration_seconds(time.diff(sent_packet.send_time, now_time)) > measure_period {
              break
          }
          if sent_packet.sequence == sequence && time.duration_seconds(time.diff(sent_packet.send_time, now_time)) >= ep.rtt_avg {
            num_sent += 1
            if !sent_packet.acked {
              num_dropped += 1
            }
          }
        }
      }

      if num_sent > 0 {
        packet_loss := f64(num_dropped) / f64(num_sent) * 100
        if abs(packet_loss - ep.packet_loss) > 0.00001 {
          ep.packet_loss += (packet_loss - ep.packet_loss) * smoothing_factor
        } else {
          ep.packet_loss = packet_loss
        }
      } else {
        ep.packet_loss = 0
      }
    }

    // calculate outgoing bandwidth
    {
      bytes_sent: int
      start_time := time.Time{bits.I64_MAX}
      end_time: time.Time
      for i in 0..<len(ep.sent_packets_buffer) {
        sequence := ep.sequence - 1 - u16(i)
        sent_packet, ok := &ep.sent_packets_buffer[sequence%len(ep.sent_packets_buffer)].?
        if ok {
          if sent_packet.sequence == sequence {
            if time.duration_seconds(time.diff(sent_packet.send_time, now_time)) > measure_period {
              break
            }
            bytes_sent += sent_packet.size
            if time.diff(end_time, sent_packet.send_time) > 0 {
              end_time = sent_packet.send_time
            }
            if time.diff(start_time, sent_packet.send_time) < 0 {
              start_time = sent_packet.send_time
            }
          }
        }
      }

      if start_time != {bits.I64_MAX} && end_time != {0} {
        outgoing_bandwidth_kbps := f64(bytes_sent) / time.duration_seconds(time.diff(start_time, end_time)) * 8 / 1024
        if abs(outgoing_bandwidth_kbps - ep.outgoing_bandwidth_kbps) > 0.00001 {
          ep.outgoing_bandwidth_kbps += (outgoing_bandwidth_kbps - ep.outgoing_bandwidth_kbps) * smoothing_factor
        } else {
          ep.outgoing_bandwidth_kbps = outgoing_bandwidth_kbps
        }
      }
    }

    // calculate incoming bandwidth
    {
      bytes_received: int
      start_time := time.Time{bits.I64_MAX}
      end_time: time.Time
      for i in 0..<len(ep.received_packets_buffer) {
        sequence := ep.received_packets_buffer_sequence - 1 - u16(i)
        received_packet, ok := &ep.received_packets_buffer[sequence%len(ep.received_packets_buffer)].?
        if ok {
          if received_packet.sequence == sequence {
            if time.duration_seconds(time.diff(received_packet.receive_time, now_time)) > measure_period {
              break
            }
            bytes_received += received_packet.size
            if time.diff(end_time, received_packet.receive_time) > 0 {
              end_time = received_packet.receive_time
            }
            if time.diff(start_time, received_packet.receive_time) < 0 {
              start_time = received_packet.receive_time
            }
          }
        }
      }

      if start_time != {bits.I64_MAX} && end_time != {0} {
        incoming_bandwidth_kbps := f64(bytes_received) / time.duration_seconds(time.diff(start_time, end_time)) * 8 / 1024
        if abs(incoming_bandwidth_kbps - ep.incoming_bandwidth_kbps) > 0.00001 {
          ep.incoming_bandwidth_kbps += (incoming_bandwidth_kbps - ep.incoming_bandwidth_kbps) * smoothing_factor
        } else {
          ep.incoming_bandwidth_kbps = incoming_bandwidth_kbps
        }
      }
    }

    clear(&ep.rtt_history_buffer)
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