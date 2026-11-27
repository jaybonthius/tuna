(library (git state)
  (export %make-command %command? %command-repository %command-arguments %command-exit %command-exit-set!
          %command-parts %command-parts-set! %command-out-parts %command-out-parts-set! %command-canceled?
          %command-canceled?-set! %command-process %command-process-set! %command-stopped? %command-stopped?-set!
          make-state state-log state-log-set! state-queue state-queue-set! state-running state-running-set! states)
  (import (chezscheme))

  ;; Chez loads a library once per process, so a reload of git keeps each
  ;; repository's queue, its running command and its log: a command
  ;; called after the reload waits for one called before it, and the
  ;; commands logged before stay commands.
  (define-record-type (%command %make-command %command?)
    (sealed #t)
    (fields repository arguments (mutable exit) (mutable parts) (mutable out-parts) (mutable canceled?)
            (mutable process) (mutable stopped?)))

  ;; Each repository's commands run one at a time, in the order called,
  ;; since git's index admits one writer.
  (define-record-type state
    (fields (mutable log) (mutable queue) (mutable running)))

  (define states (make-hashtable string-hash string=?)))
