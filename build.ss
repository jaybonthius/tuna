#!/usr/bin/env gxi

(import :std/build-script)

(defbuild-script
  `("tuna/version"
    "tuna/kernel/ids"
    "tuna/kernel/entries"
    "tuna/kernel/state"
    "tuna/kernel/plugins"
    "tuna/kernel/loop"
    "tuna/kernel"
    (exe: "tuna/main" bin: "tuna")))
