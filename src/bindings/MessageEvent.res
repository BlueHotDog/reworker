/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

@get external data: t => Obj.t = "data"
@get external origin: t => string = "origin"
@get external source: t => BrowserWindow.t = "source"
@get external ports: t => array<MessagePort.t> = "ports"
