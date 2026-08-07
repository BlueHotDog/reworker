/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type Types.message<_> +=
  | Ping(string): Types.message<string>
  | Reverse(string): Types.message<string>
  | AskReverse(string): Types.message<string>
  | Notice(string): Types.message<unit>
  | GetNotice: Types.message<option<string>>
  | Fail: Types.message<string>
  | Never: Types.message<string>
  | Uncloneable(Obj.t): Types.message<string>
