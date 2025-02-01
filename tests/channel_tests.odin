package hampuslib_reliable

import "core:testing"
import "core:mem"
import "core:log"
import "core:fmt"
import "core:net"
import "core:math/rand"
import "core:time"

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

@test
sending_small_reliable_packets :: proc(t: ^testing.T) {

  peer0_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 34331,
  }

  peer1_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 34531,
  }

  socket0 := socket_open(peer0_address)
  socket1 := socket_open(peer1_address)

  channel0 := channel_open(socket0, peer1_address)
  channel1 := channel_open(socket1, peer0_address)

  next_expected_idx0 := 0
  next_expected_idx1 := 0

  send_count := 5

  dt: f32 = 0.33
  start_time := time.now()
  idx := 0
  for {
    channel_update(channel0, dt)
    channel_update(channel1, dt)

    buf: [4096]u8
    bytes_read, address, _ := net.recv_udp(socket0, buf[:])
    if address == peer1_address do channel_receive(channel0, buf[:bytes_read])

    bytes_read, address, _ = net.recv_udp(socket1, buf[:])
    if address == peer0_address do channel_receive(channel1, buf[:bytes_read])

    if idx <= send_count do channel_send_any(channel0, idx, is_reliable = true)
    if idx <= send_count do channel_send_any(channel1, idx, is_reliable = true)

    channel0_data := channel_get_received_data(channel0)
    for data in channel0_data {
      x := cast(^int)raw_data(data)
      testing.expect(t, x^ == next_expected_idx0, "Got an unexpected counter value")
      next_expected_idx0 += 1
    }

    channel1_data := channel_get_received_data(channel1)
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

  channel_close(channel0)
  channel_close(channel1)
}

@test
sending_large_reliable_packets :: proc(t: ^testing.T) {

  peer0_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 34336,
  }

  peer1_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 34537,
  }

  socket0 := socket_open(peer0_address)
  socket1 := socket_open(peer1_address)

  channel0 := channel_open(socket0, peer1_address)
  channel1 := channel_open(socket1, peer0_address)

  next_expected_idx0 := 0
  next_expected_idx1 := 0

  send_count := 5

  idx := 0
  dt: f32 = 0.33
  start_time := time.now()
  for {
    channel_update(channel0, dt)
    channel_update(channel1, dt)

    buf: [4096]u8
    bytes_read, address, _ := net.recv_udp(socket0, buf[:])
    if address == peer1_address do channel_receive(channel0, buf[:bytes_read])

    bytes_read, address, _ = net.recv_udp(socket1, buf[:])
    if address == peer0_address do channel_receive(channel1, buf[:bytes_read])

    {
      send_buf: [5000]u8
      first_int := cast(^int)raw_data(send_buf[:])
      first_int^ = idx
      last_int := cast(^int)raw_data(send_buf[len(send_buf)-size_of(int):])
      last_int^ = idx

      if idx <= send_count do channel_send(channel0, send_buf[:], is_reliable = true)
      if idx <= send_count do channel_send(channel1, send_buf[:], is_reliable = true)
    }

    channel0_data := channel_get_received_data(channel0)
    for data in channel0_data {
      x := cast(^int)raw_data(data)
      first_int := cast(^int)raw_data(data)
      last_int := cast(^int)raw_data(data[len(data)-size_of(int):])
      testing.expect(t, last_int^ == next_expected_idx0, "Got an unexpected first counter value")
      testing.expect(t, first_int^ == next_expected_idx0, "Got an unexpected last counter value")
      next_expected_idx0 += 1
    }

    channel1_data := channel_get_received_data(channel1)
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

  channel_close(channel0)
  channel_close(channel1)
}

@test
sending_small_and_large_reliable_packets :: proc(t: ^testing.T) {

  peer0_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 35364,
  }

  peer1_address := net.Endpoint{
    address = net.IP4_Address{127, 0, 0, 1},
    port = 36555,
  }


  socket0 := socket_open(peer0_address)
  socket1 := socket_open(peer1_address)

  channel0 := channel_open(socket0, peer1_address)
  channel1 := channel_open(socket1, peer0_address)

  next_expected_idx0 := 0
  next_expected_idx1 := 0

  send_count := 5

  idx := 0
  dt: f32 = 0.33
  start_time := time.now()
  for {

    channel_update(channel0, dt)
    channel_update(channel1, dt)

    buf: [4096]u8
    bytes_read, address, _ := net.recv_udp(socket0, buf[:])
    if bytes_read > 0 {
      if address == peer1_address do channel_receive(channel0, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(socket0, buf[:])
    }

    bytes_read, address, _ = net.recv_udp(socket1, buf[:])
    if bytes_read > 0 {
      if address == peer0_address do channel_receive(channel1, buf[:bytes_read])
      bytes_read, address, _ = net.recv_udp(socket1, buf[:])
    }

    if idx <= send_count {
      if idx % 2 == 0 {
        send_buf: [5312]u8
        first_int := cast(^int)raw_data(send_buf[:])
        first_int^ = idx
        channel_send(channel0, send_buf[:], is_reliable = true)
        channel_send(channel1, send_buf[:], is_reliable = true)
      } else {
        send_buf: [8]u8
        first_int := cast(^int)raw_data(send_buf[:])
        first_int^ = idx
        channel_send(channel0, send_buf[:], is_reliable = true)
        channel_send(channel1, send_buf[:], is_reliable = true)
      }
    }

    channel0_data := channel_get_received_data(channel0)
    for data in channel0_data {
      x := cast(^int)raw_data(data)
      testing.expect(t, x^ == next_expected_idx0, "Got an unexpected counter value")
      next_expected_idx0 += 1
    }

    channel1_data := channel_get_received_data(channel1)
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

  channel_close(channel0)
  channel_close(channel1)
}
