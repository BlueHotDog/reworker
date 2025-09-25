/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type originalHandler
type wrapperHandler
type t = WeakMap.t<originalHandler, wrapperHandler>
let toOriginalHandler: 'a => originalHandler = Obj.magic
let toWrappedHandler: 'b => wrapperHandler = Obj.magic
let toListener: wrapperHandler => 'c = Obj.magic

