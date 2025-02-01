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

See [example.odin](example.odin) on how to use this library.
