#!tuna
(import (keys) (keys-test completions))

(keys:bind! keys:global "C-c q" keys-test/completions:prefix-map)
