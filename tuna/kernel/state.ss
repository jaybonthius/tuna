;;; The kernel's state.
;;; Everything here is confined to the editor baton (ADR 3, ADR 4).
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        ./entries)
(export kernel
        kernel?
        new-kernel
        current-kernel
        the-kernel
        kernel-plugins
        kernel-services
        kernel-providers
        kernel-commands
        kernel-adapters
        kernel-hooks
        kernel-jobs
        kernel-live?
        kernel-loop
        exception-summary)

(defclass kernel
  ((plugins   : HashTable)       ; plugin name -> plugin record
   (services  : HashTable)       ; service name -> service
   (providers : entry-table)     ; service name -> provider entries
   (commands  : entry-table)     ; command name -> command entries
   (adapters  : entry-table)     ; service name -> adapter entries
   (hooks     : HashTable)       ; hook name -> callbacks, in calling order
   (jobs      : :t)              ; the job registry, owned by ./jobs
   (live?     : :boolean)        ; the editor loop is running
   (loop      : :t))             ; the editor loop object, owned by ./loop
  final: #t)

(def (new-kernel) => kernel
  (kernel plugins: (make-hash-table)
          services: (make-hash-table)
          providers: (new-entry-table)
          commands: (new-entry-table)
          adapters: (new-entry-table)
          hooks: (make-hash-table-eq)
          jobs: #f
          live?: #f
          loop: #f))

;; Tests run each scenario in a fresh kernel by parameterizing this.
(def current-kernel (make-parameter (new-kernel)))

(def (the-kernel) => kernel
  (: (current-kernel) kernel))

;; One line describing an exception, for the echo area.
(def (exception-summary (e : :t)) => :string
  (if (Error? e)
    (call-with-output-string ""
      (lambda (port)
        (display (Error-message e) port)
        (for-each (lambda (irritant) (display " " port) (write irritant port))
                  (Error-irritants e))))
    (let (lines (filter (lambda ((line : :string)) (not (string-empty? line)))
                        (string-split (exception->string e) #\newline)))
      (if (pair? lines) (car lines) ""))))
