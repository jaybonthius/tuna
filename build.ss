#!/usr/bin/env gxi

(import :std/build-script)

(defbuild-script
  '("tuna/version"
    (exe: "tuna/main" bin: "tuna")))
