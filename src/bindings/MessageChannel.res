/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

@new external make: unit => t = "MessageChannel"
@get external port1: t => MessagePort.t = "port1"
@get external port2: t => MessagePort.t = "port2"
