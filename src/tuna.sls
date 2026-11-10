(library (tuna)
  (export spawn-task suspend current-task task-done? join-task signal-task task?)
  (import (only (chezscheme) export) (tuna core main-thread))
  (export (import (tuna base))))
