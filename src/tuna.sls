(library (tuna)
  (export
    spawn-task suspend current-task task-done? join-task signal-task task?
    define-hook add-hook! add-local-hook! remove-hook! remove-local-hook! hook-entries hook?
    define-option with-options set-option! remove-option! set-option-local! remove-option-local!
    current-scope make-scope scope? option-default option-setting option-settings option?
    option-changed
    define-table table-set! table-remove! table-ref table-entries table-owner table?
    documentation)
  (import (only (chezscheme) export) (tuna core main-thread) (tuna scopes) (tuna hooks) (tuna options)
          (tuna tables) (tuna documentation))
  (export (import (tuna base))))
