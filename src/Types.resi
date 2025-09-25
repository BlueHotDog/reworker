/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Extensible GADT for type-safe message passing
// Users extend this type with their own message variants:
// type Types.message<_> += | GetUser(string): Types.message<User.t>

type rec message<_> = ..