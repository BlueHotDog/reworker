/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t = string

let uuidv4 = () => {
  let pattern = /[xy]/g
  "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"->String.replaceRegExpBy0Unsafe(pattern, (
    ~match,
    ~offset as _,
    ~input as _,
  ) => {
    let r = (Math.random() *. 16.0)->Float.toInt
    let v = if match == "x" {
      r
    } else {
      Int.bitwiseOr(Int.bitwiseAnd(r, 0x3), 0x8)
    }
    v->Int.toString(~radix=16)
  })
}

let make = () => uuidv4()
let toString = v => v
