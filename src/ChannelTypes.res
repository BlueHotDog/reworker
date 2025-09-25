/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Base type for channel-specific message GADTs
// Each channel functor will define its own message<_> type
type rec channelMessage<_> = ..

// Channel identity and state
type channelId = Id.t

let makeChannelId = (id: Id.t): channelId => id

type channelState<'port> = {
  channelName: channelId,
  port: 'port,
  isConnected: ref<bool>,
}
