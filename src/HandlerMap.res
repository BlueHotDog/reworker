/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Type-safe handler mapping for removeListener functionality
// Uses WeakMap with opaque types to handle generic handler storage

type originalHandler
type wrappedHandler
type t = WeakMap.t<originalHandler, wrappedHandler>

let make: unit => t = () => WeakMap.make()

let toOriginalHandler: 'a => originalHandler = Obj.magic
let toWrappedHandler: 'b => wrappedHandler = Obj.magic
let toListener: wrappedHandler => 'c = Obj.magic

let set = (t, k, v) => t->WeakMap.set(k->toOriginalHandler, v->toWrappedHandler)->ignore

let get = (t, k) => t->WeakMap.get(k->toOriginalHandler)->Option.map(toListener)

let delete = (t, k) => t->WeakMap.delete(k->toOriginalHandler)->ignore