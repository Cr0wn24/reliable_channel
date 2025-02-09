package hampuslib_reliable

import "core:mem"
import "core:log"
import "core:slice"
import "core:time"
import "core:hash"

import "../ack"

Channel :: struct {
}

channel_open :: proc() -> ^Channel {
  return nil
}

channel_close :: proc(channel: ^Channel) {
}

channel_update :: proc(channel: ^Channel, dt: f32) {
}

channel_send :: proc(channel: ^Channel, data: []u8) {
}