/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type rec channelMessage<_> = ..
type channelId

let makeChannelId: Id.t => channelId
type channelState<'port> = {
  channelName: channelId,
  port: 'port,
  isConnected: ref<bool>,
}
