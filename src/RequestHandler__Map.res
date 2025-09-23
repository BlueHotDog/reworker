/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type originalHandler
type wrapperHandler
type t = WeakMap.t<originalHandler, wrapperHandler>
let make: unit => t = () => WeakMap.make()
let toOriginalHandler: 'a => originalHandler = Obj.magic
let toWrappedHandler: 'b => wrapperHandler = Obj.magic
let toListener: wrapperHandler => 'c = Obj.magic

let set = (t, k, v) => t->WeakMap.set(k->toOriginalHandler, v->toWrappedHandler)
let get = (t, k) => t->WeakMap.get(k->toOriginalHandler)->Option.map(toListener)
