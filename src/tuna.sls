(library (tuna)
  (export
    spawn-task suspend current-task task-done? join-task signal-task task?
    sleep-for run-with-timer run-with-idle-timer cancel-timer! timers timer-procedure timer?
    set-idle! idle-seconds
    define-worker start-job stop-job! emit worker? job? plain-data?
    define-saved set-saved! remove-saved! saved?
    define-hook add-hook! add-local-hook! remove-hook! remove-local-hook! hook-entries hook?
    define-option with-options set-option! remove-option! set-option-local! remove-option-local!
    current-scope make-scope scope? option-default option-setting option-settings option?
    option-changed
    define-table table-set! table-remove! table-ref table-entries table-owner table?
    documentation)
  (import (only (chezscheme) export) (tuna core main-thread) (tuna scopes) (tuna hooks) (tuna options)
          (tuna tables) (tuna documentation) (tuna timers) (tuna workers) (tuna plain-data)
          (tuna saved))
  (export (import (tuna base))))
