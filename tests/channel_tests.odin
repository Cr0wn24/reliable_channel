package reliable_channel_tests

import "core:testing"
import "core:mem"
import "core:log"
import "core:fmt"
import "core:net"
import "core:math/rand"
import "core:time"

import rc "reliable_channel:reliable"

socket_open :: proc(address: net.Endpoint) -> net.UDP_Socket {
  create_socket_res, err := net.create_socket(.IP4, .UDP)
  assert(err == nil)
  socket := create_socket_res.(net.UDP_Socket)
  err = net.bind(socket, address)
  assert(err == nil)
  err = net.set_blocking(socket, false)
  assert(err == nil)
  return socket
}

Channel_Data :: struct {
  socket: net.UDP_Socket,
  remote_address: net.Endpoint,
}

@test
sending_small_reliable_packets :: proc(t: ^testing.T) {

  on_send_data :: proc(channel: ^rc.Channel, packet_data: []u8) {
    channel_data := cast(^Channel_Data)channel.user_data
    net.send_udp(channel_data.socket, packet_data, channel_data.remote_address)
  }

  peer0_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 34331,
  }

  peer1_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 34531,
  }

  channel0_data := Channel_Data {
    socket = socket_open(peer0_address),
    remote_address = peer1_address,
  }

  channel1_data := Channel_Data {
    socket = socket_open(peer1_address),
    remote_address = peer0_address,
  }

  channel0 := rc.channel_open(on_send_data)
  defer(rc.channel_close(channel0))
  channel0.user_data = cast(rawptr)&channel0_data

  channel1 := rc.channel_open(on_send_data)
  defer(rc.channel_close(channel1))
  channel1.user_data = cast(rawptr)&channel1_data

  next_expected_idx0 := 0
  next_expected_idx1 := 0

  send_count := 5

  dt: f32 = 0.33
  start_time := time.now()
  idx := 0
  for {
    rc.channel_update(channel0, dt)
    rc.channel_update(channel1, dt)

    buf: [4096]u8
    bytes_read, address, _ := net.recv_udp(channel0_data.socket, buf[:])
    for bytes_read > 0 {
      if address == peer1_address do rc.channel_receive(channel0, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(channel0_data.socket, buf[:])
    }

    bytes_read, address, _ = net.recv_udp(channel1_data.socket, buf[:])
    for bytes_read > 0 {
      if address == peer0_address do rc.channel_receive(channel1, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(channel1_data.socket, buf[:])
    }

    if idx <= send_count do rc.channel_send_any(channel0, idx, is_reliable = true)
    if idx <= send_count do rc.channel_send_any(channel1, idx, is_reliable = true)

    channel0_data := rc.channel_get_received_data(channel0)
    for data in channel0_data {
      x := cast(^int)raw_data(data)
      testing.expect(t, x^ == next_expected_idx0, "Got an unexpected counter value")
      next_expected_idx0 += 1
    }

    channel1_data := rc.channel_get_received_data(channel1)
    for data in channel1_data {
      x := cast(^int)raw_data(data)
      testing.expect(t, x^ == next_expected_idx1, "Got an unexpected counter value")
      next_expected_idx1 += 1
    }

    if next_expected_idx0 == (send_count+1) && next_expected_idx1 == (send_count+1) {
      break
    }

    time.sleep(time.Millisecond * 5)

    free_all(context.temp_allocator)

    idx += 1

    dt = f32(time.duration_seconds(time.since(start_time)))
    start_time = time.now()
  }
}

@test
sending_large_reliable_packets :: proc(t: ^testing.T) {

  on_send_data :: proc(channel: ^rc.Channel, packet_data: []u8) {
    channel_data := cast(^Channel_Data)channel.user_data
    net.send_udp(channel_data.socket, packet_data, channel_data.remote_address)
  }

  peer0_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 33331,
  }

  peer1_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 33531,
  }

  channel0_data := Channel_Data {
    socket = socket_open(peer0_address),
    remote_address = peer1_address,
  }

  channel1_data := Channel_Data {
    socket = socket_open(peer1_address),
    remote_address = peer0_address,
  }

  channel0 := rc.channel_open(on_send_data)
  defer(rc.channel_close(channel0))
  channel0.user_data = cast(rawptr)&channel0_data

  channel1 := rc.channel_open(on_send_data)
  defer(rc.channel_close(channel1))
  channel1.user_data = cast(rawptr)&channel1_data

  next_expected_idx0 := 0
  next_expected_idx1 := 0

  send_count := 5

  idx := 0
  dt: f32 = 0.33
  start_time := time.now()
  for {
    rc.channel_update(channel0, dt)
    rc.channel_update(channel1, dt)

    buf: [4096]u8
    bytes_read, address, _ := net.recv_udp(channel0_data.socket, buf[:])
    for bytes_read > 0 {
      if address == peer1_address do rc.channel_receive(channel0, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(channel0_data.socket, buf[:])
    }

    bytes_read, address, _ = net.recv_udp(channel1_data.socket, buf[:])
    for bytes_read > 0 {
      if address == peer0_address do rc.channel_receive(channel1, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(channel1_data.socket, buf[:])
    }

    {
      send_buf: [5000]u8
      first_int := cast(^int)raw_data(send_buf[:])
      first_int^ = idx
      last_int := cast(^int)raw_data(send_buf[len(send_buf)-size_of(int):])
      last_int^ = idx

      if idx <= send_count do rc.channel_send(channel0, send_buf[:], is_reliable = true)
      if idx <= send_count do rc.channel_send(channel1, send_buf[:], is_reliable = true)
    }

    channel0_data := rc.channel_get_received_data(channel0)
    for data in channel0_data {
      x := cast(^int)raw_data(data)
      first_int := cast(^int)raw_data(data)
      last_int := cast(^int)raw_data(data[len(data)-size_of(int):])
      testing.expect(t, last_int^ == next_expected_idx0, "Got an unexpected first counter value")
      testing.expect(t, first_int^ == next_expected_idx0, "Got an unexpected last counter value")
      next_expected_idx0 += 1
    }

    channel1_data := rc.channel_get_received_data(channel1)
    for data in channel1_data {
      x := cast(^int)raw_data(data)
      first_int := cast(^int)raw_data(data)
      last_int := cast(^int)raw_data(data[len(data)-size_of(int):])
      testing.expect(t, last_int^ == next_expected_idx1, "Got an unexpected first counter value")
      testing.expect(t, first_int^ == next_expected_idx1, "Got an unexpected last counter value")
      next_expected_idx1 += 1
    }

    if next_expected_idx0 == (send_count+1) && next_expected_idx1 == (send_count+1) {
      break
    }

    time.sleep(time.Millisecond * 5)

    free_all(context.temp_allocator)

    idx += 1

    dt = f32(time.duration_seconds(time.since(start_time)))
    start_time = time.now()
  }
}

@test
sending_small_and_large_reliable_packets :: proc(t: ^testing.T) {

  on_send_data :: proc(channel: ^rc.Channel, packet_data: []u8) {
    channel_data := cast(^Channel_Data)channel.user_data
    net.send_udp(channel_data.socket, packet_data, channel_data.remote_address)
  }

  peer0_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 32331,
  }

  peer1_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 32531,
  }

  channel0_data := Channel_Data {
    socket = socket_open(peer0_address),
    remote_address = peer1_address,
  }

  channel1_data := Channel_Data {
    socket = socket_open(peer1_address),
    remote_address = peer0_address,
  }

  channel0 := rc.channel_open(on_send_data)
  defer(rc.channel_close(channel0))
  channel0.user_data = cast(rawptr)&channel0_data

  channel1 := rc.channel_open(on_send_data)
  defer(rc.channel_close(channel1))
  channel1.user_data = cast(rawptr)&channel1_data

  next_expected_idx0 := 0
  next_expected_idx1 := 0

  send_count := 5

  idx := 0
  dt: f32 = 0.33
  start_time := time.now()
  for {

    rc.channel_update(channel0, dt)
    rc.channel_update(channel1, dt)

    buf: [4096]u8
    bytes_read, address, _ := net.recv_udp(channel0_data.socket, buf[:])
    for bytes_read > 0 {
      if address == peer1_address do rc.channel_receive(channel0, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(channel0_data.socket, buf[:])
    }

    bytes_read, address, _ = net.recv_udp(channel1_data.socket, buf[:])
    for bytes_read > 0 {
      if address == peer0_address do rc.channel_receive(channel1, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(channel1_data.socket, buf[:])
    }

    if idx <= send_count {
      if idx % 2 == 0 {
        send_buf: [5312]u8
        first_int := cast(^int)raw_data(send_buf[:])
        first_int^ = idx
        rc.channel_send(channel0, send_buf[:], is_reliable = true)
        rc.channel_send(channel1, send_buf[:], is_reliable = true)
      } else {
        send_buf: [8]u8
        first_int := cast(^int)raw_data(send_buf[:])
        first_int^ = idx
        rc.channel_send(channel0, send_buf[:], is_reliable = true)
        rc.channel_send(channel1, send_buf[:], is_reliable = true)
      }
    }

    channel0_data := rc.channel_get_received_data(channel0)
    for data in channel0_data {
      x := cast(^int)raw_data(data)
      testing.expect(t, x^ == next_expected_idx0, "Got an unexpected counter value")
      next_expected_idx0 += 1
    }

    channel1_data := rc.channel_get_received_data(channel1)
    for data in channel1_data {
      x := cast(^int)raw_data(data)
      testing.expect(t, x^ == next_expected_idx1, "Got an unexpected counter value")
      next_expected_idx1 += 1
    }

    if next_expected_idx0 == (send_count+1) && next_expected_idx1 == (send_count+1) {
      break
    }

    time.sleep(time.Millisecond * 5)

    free_all(context.temp_allocator)

    idx += 1

    dt = f32(time.duration_seconds(time.since(start_time)))
    start_time = time.now()
  }
}
