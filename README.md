# reliable_channel
reliable_channel is a networking protocol library based on [these](https://gafferongames.com/categories/building-a-game-network-protocol/) amazing articles (except the client-server one) by Glenn Fiedler. The library is independent of the medium through which data is passed, allowing the user to define how to send and receive data. I developed this intending to use it for game networking.

What it does:
- Handles out-of-order packets
- Handles duplicated packets
- Sends data reliably
- Sends data unreliably if the data is time-critical
- Supports packet fragmentation & reassembly
- Estimates RTT, packet loss, and incoming/outgoing bandwidth

What it does NOT do:
- Connections
- Security
- Congestion avoidance

## Usage
The library is based on channels. You can see a channel as an edge between two nodes in a network. You can choose to send reliable (or unreliable) packets over the channel. You define callbacks for how to send data, which the channels will call when they need to transmit something.

Typically, this would be through sockets, but it doesn't have to be. When data is received is also up to you, but upon receiving it, you can decide whether it should go through the channel.

See [example.odin](example.odin) for more details on how to use this library.
