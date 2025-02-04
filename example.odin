package reliable_channel_example

import "core:fmt"
import "core:net"
import "core:time"

import rc "reliable_channel:reliable"

server_address := net.Endpoint {
  address = net.IP4_Address{127, 0, 0, 1},
  port = 34331,
}

client_address := net.Endpoint {
  address = net.IP4_Address{127, 0, 0, 1},
  port = 34531,
}

client_socket: net.UDP_Socket
// The name of the channel is who we want to send to or receive from.
// This is the client's state hence we want to send to the server and thus
// the channel name is `server_channel`
server_channel: ^rc.Channel

server_socket: net.UDP_Socket
client_channel: ^rc.Channel

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

on_send_data :: proc(channel: ^rc.Channel, packet_data: []u8) {
  if channel == server_channel {
    net.send_udp(client_socket, packet_data, server_address)
  } else {
    net.send_udp(server_socket, packet_data, client_address)
  }
}

main :: proc() {

  client_socket = socket_open(client_address)
  server_socket = socket_open(server_address)

  server_channel = rc.channel_open(on_send_data)
  client_channel = rc.channel_open(on_send_data)

  start_time := time.now()
  dt: f32 = 0.33
  for {
    rc.channel_update(server_channel, dt)
    rc.channel_update(client_channel, dt)

    { // Receive from server
      buf: [4096]u8
      bytes_read, address, _ := net.recv_udp(client_socket, buf[:])
      for bytes_read > 0 {
        if address == server_address do rc.channel_receive(server_channel, buf[:bytes_read])
        bytes_read, address, _ = net.recv_udp(client_socket, buf[:])
      }
    }

    { // Receive from client
      buf: [4096]u8
      bytes_read, address, _ := net.recv_udp(server_socket, buf[:])
      for bytes_read > 0 {
        if address == client_address do rc.channel_receive(client_channel, buf[:bytes_read])
        bytes_read, address, _ = net.recv_udp(server_socket, buf[:])
      }
    }

    // send unreliably

    str := "hello, world!"
    rc.channel_send(client_channel, transmute([]u8)str)

    // send reliably

    rc.channel_send(client_channel, transmute([]u8)str, is_reliable = true)

    server_channel_data := rc.channel_get_received_data(server_channel)
    for data in server_channel_data {
      fmt.println("Client received from server:", data[:])
    }

    time.sleep(time.Millisecond * 50)

    free_all(context.temp_allocator)

    dt = f32(time.duration_seconds(time.since(start_time)))
    start_time = time.now()

  }
}
