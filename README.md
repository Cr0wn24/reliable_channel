# reliable_channel

reliable_channel is a networking protocol library which is based on [these](https://gafferongames.com/categories/building-a-game-network-protocol/) amazing articles (except the client-server one) by Glenn Fiedler. The library is independent of what medium the data is passed through by letting the user 
define how to send data and how to receive. I developed this intending to use it for game networking. 

What it does:
- handle out-of-order packets
- handle duplicated packets
- send data reliably
- send data unreliably if the data is time-critical
- packet fragmentation & reassembly
- esimate RTT, packet loss and incoming/outgoing bandwidth

What it does _not_ do:
- connections
- security
- congestion avoidance

## Usage

The library is based on channels. You can see a channel as just an edge between two nodes in a network. You can choose to send reliable (or unreliable) packets over the channel. You define callbacks for how to send data which the channels will call into when they want to transmit something.
Typically, this would be through sockets but doesn't have to be. 

See [example.odin](example.odin) on how to further use this library.
