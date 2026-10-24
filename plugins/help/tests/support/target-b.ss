#lang :tuna/prelude
(export probe)

(def (probe (n : :fixnum)) => :fixnum
  (fx+ n 2))
