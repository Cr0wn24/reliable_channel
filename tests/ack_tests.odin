package reliable_channel_tests

import "core:testing"
import "core:log"
import "core:fmt"
import "core:math/rand"

import "reliable_channel:ack"

Test_Context :: struct {
  endpoint: ^ack.Endpoint,
  t: ^testing.T,
  expected_acks: [dynamic]u16,
  packet_loss: u32,
}

on_send_data :: proc(endpoint: ^ack.Endpoint, packet_data: []u8) {
  // simulate 50% packet loss
  test_context := cast(^Test_Context)endpoint.user_data
  if rand.uint32() % 100 >= test_context.packet_loss  {
    err := ack.endpoint_receive_data(test_context.endpoint, packet_data)
    assert(err == nil)
  }
}

@(test)
sending_small_packets :: proc(t: ^testing.T) {

  test_context := new(Test_Context, context.allocator)
  defer(free(test_context))

  test_context.t = t
  test_context.packet_loss = 40

  DATA_LEN :: 1024

  on_receive_data :: proc(endpoint: ^ack.Endpoint, sequence: u16, data: []u8) {
    test_context := cast(^Test_Context)endpoint.user_data
    testing.expect(test_context.t, len(data) == DATA_LEN, "Didn't receive all the data")
    append(&test_context.expected_acks, sequence)
    for elem, idx in data {
      testing.expect(test_context.t, elem == u8(idx), "Got a wrong value")
    }
  }

  err: ack.Error

  test_context.endpoint, err = ack.endpoint_open(on_send_data, on_receive_data)
  assert(err == nil)
  defer{
    err = ack.endpoint_close(test_context.endpoint)
    assert(err == nil)
  }
  test_context.endpoint.user_data = test_context

  data: [DATA_LEN]u8
  for &elem, idx in data {
    elem = u8(idx)
  }

  for i in 0..<0xffff {
    err = ack.endpoint_send_data(test_context.endpoint, data[:])
    assert(err == nil)
  }
  err = ack.endpoint_receive_data(test_context.endpoint, data[:])
  assert(err == nil)


  acks := ack.endpoint_get_acks(test_context.endpoint)
  if len(test_context.expected_acks) == 0 {
    testing.expect(t, len(acks) == 0, "Didn't receive all the acks")
  } else {
    testing.expect(t, len(acks) == (len(test_context.expected_acks)-1), "Didn't receive all the acks")
  }

  for elem, idx in acks {
    testing.expect(t, elem == test_context.expected_acks[idx], "Received wrong ack")
  }

  delete(test_context.expected_acks)
}

@(test)
sending_large_packets :: proc(t: ^testing.T) {

  test_context := new(Test_Context, context.allocator)
  defer(free(test_context))

  test_context.t = t
  test_context.packet_loss = 1

  DATA_LEN :: 1024*16

  on_receive_data :: proc(endpoint: ^ack.Endpoint, sequence: u16, data: []u8) {
    test_context := cast(^Test_Context)endpoint.user_data
    testing.expect(test_context.t, len(data) == DATA_LEN, "Didn't receive all the data")
    append(&test_context.expected_acks, sequence)
    for elem, idx in data {
      testing.expect(test_context.t, elem == u8(idx), "Got a wrong value")
    }
  }

  err: ack.Error

  test_context.endpoint, err = ack.endpoint_open(on_send_data, on_receive_data)
    assert(err == nil)
  defer {
    err = ack.endpoint_close(test_context.endpoint)
  }
  test_context.endpoint.user_data = test_context

  data: [DATA_LEN]u8
  for &elem, idx in data {
    elem = u8(idx)
  }

  for i in 0..<0xffff {
    err = ack.endpoint_send_data(test_context.endpoint, data[:])
    assert(err == nil)
  }
  log.info("sending last")
  err = ack.endpoint_receive_data(test_context.endpoint, data[:])
  assert(err == nil)

  acks := ack.endpoint_get_acks(test_context.endpoint)
  if len(test_context.expected_acks) == 0 {
    testing.expect(t, len(acks) == 0, "Didn't receive all the acks")
  } else {
    testing.expect(t, len(acks) >= (len(test_context.expected_acks)-1), "Didn't receive all the acks")
  }

  for elem, idx in acks {
    testing.expect(t, elem == test_context.expected_acks[idx], "Received wrong ack")
  }
  delete(test_context.expected_acks)
}