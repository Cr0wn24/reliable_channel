# reliable_channel

`reliable_channel` is a networking protocol library based on [these](https://gafferongames.com/categories/building-a-game-network-protocol/) amazing articles (except the client-server one) by Glenn Fiedler. The library is independent of the medium through which data is transmitted, allowing the user to define how to send and receive data. I developed this with the intention of using it for game networking.

I hope to one day actually use this library seriously. Please feel free to try it out and create issues if something does not work.

What it offers:
- Reliable and unreliable data transmission
- Packet fragmentation & reassembly
- Estimates for RTT, packet loss, and incoming/outgoing bandwidth

What it does NOT offer:
- Connections
- Security
- Congestion avoidance

Leaving out connections is a design choice. Instead, it is designed to work well with your own connection protocol. Leaving out security is also intentional, as I am not an expert in the field of security and would rather give that responsibility to the user of this library. Congestion avoidance is something that might be added at some point.

## Tests

The tests are considered successful when they pass under both perfect network conditions _and_ horrible network conditions. To test under poor network conditions, I recommend using something like [clumsy](https://jagt.github.io/clumsy/), which can simulate packet loss, lag, duplication, among other things.

## Usage

The library is based on channels. You can think of a channel as an edge between two nodes in a network. You can choose to send reliable (or unreliable) packets over the channel. You define callbacks for how to send data, which the channels will call when they need to transmit something.

Typically, this would be through sockets, but it doesn't have to be. When data is received is also up to you, but upon receiving it, you can decide whether it should go through the channel or not.

Here is a small example:
```odin
import "core:fmt"

import rc "reliable_channel:reliable"

client_to_server_channel: ^rc.Channel
server_to_client_channel: ^rc.Channel

on_send_data :: proc(channel: ^rc.Channel, packet_data: []u8) {
  if channel == client_to_server_channel {
    rc.channel_receive(server_to_client_channel, packet_data)
  } else {
    rc.channel_receive(client_to_server_channel, packet_data)
  }
}

main :: proc() {
  client_to_server_channel = rc.channel_open(on_send_data)
  server_to_client_channel = rc.channel_open(on_send_data)
  
  dt: f32 = 0.33
  rc.channel_update(client_to_server_channel, dt)
  rc.channel_update(server_to_client_channel, dt)
  
  str := "Hello, channel!"
  rc.channel_send(client_to_server_channel, transmute([]u8)str, is_reliable = true)
  
  data_from_client := rc.channel_get_received_data(server_to_client_channel)
  fmt.println("Server got:", data_from_client[0])
}
```

See [example.odin](example.odin) for more a more comprehensive example on how to use this library.
