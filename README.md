# reliable_channel

`reliable_channel` is a networking protocol library based on [these](https://gafferongames.com/categories/building-a-game-network-protocol/) amazing articles (except the client-server one) by Glenn Fiedler. The library is independent of the medium through which data is transmitted, allowing the user to define how to send and receive data. I developed this with the intention of using it for game networking.

I hope to one day actually use this library seriously. Please feel free to try it out and create issues if something does not work.

What it offers:
- A way to send data reliably or unreliably
- Packet fragmentation & reassembly
- Estimates for RTT, packet loss, and incoming/outgoing bandwidth

What it does NOT offer:
- Connections
- Security
- Congestion avoidance

## Tests

The tests are considered successful when they pass under both perfect network conditions _and_ horrible network conditions. To test under poor network conditions, I recommend using something like [clumsy](https://jagt.github.io/clumsy/), which can simulate packet loss, lag, duplication, among other things.

## Usage

The library is based on channels. You can think of a channel as an edge between two nodes in a network. You can choose to send reliable (or unreliable) packets over the channel. You define callbacks for how to send data, which the channels will call when they need to transmit something.

Typically, this would be through sockets, but it doesn't have to be. When data is received is also up to you, but upon receiving it, you can decide whether it should go through the channel or not.

See [example.odin](example.odin) for more details on how to use this library.
