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
  | DelayedReverse(string): Types.message<string>
  | AskDelayedReverse(string): Types.message<string>
  | Cancellable: Types.message<string>
  | GetCancellationCount: Types.message<int>
  | GetCancellationStartCount: Types.message<int>
  | Uncloneable(Obj.t): Types.message<string>
