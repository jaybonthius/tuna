#!tuna
(import (spell) (files))

(advice-remove! files:save! spell:log-save)
