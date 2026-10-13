;;; The kernel's state, the quit condition, and the running task's binding.
;;; The kernel object is confined to the editor baton (ADR 3, ADR 4).
;;; ./plugins and ./loop both need the quit condition and the task binding:
;;; run-hook lets quits unwind the running task (ADR 3).
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        ./entries)
(export kernel
        new-kernel
        current-kernel
        the-kernel
        kernel-plugins
        kernel-services
        kernel-providers
        kernel-adapters
        kernel-live?
        kernel-loop
        quit-condition
        quit-condition?
        quit-condition-forced?
        current-task
        exception-summary)

(defclass kernel
  ((plugins   : HashTable)       ; plugin name -> plugin record
   (services  : HashTable)       ; service name -> service
   (providers : entry-table)     ; service name -> provider entries
   (adapters  : entry-table)     ; service name -> adapter entries
   (live?     : :boolean)        ; the editor loop is running
   (loop      : :t))             ; the editor loop object, owned by ./loop
  final: #t)

(def (new-kernel) => kernel
  (kernel plugins: (make-hash-table)
          services: (make-hash-table)
          providers: (new-entry-table)
          adapters: (new-entry-table)
          live?: #f
          loop: #f))

;; The kernel facade does not export this; tests select a fresh kernel
;; through call-with-fresh-kernel in tuna/test-support/kernel.ss.
(def current-kernel (make-parameter (new-kernel)))

(def (the-kernel) => kernel
  (: (current-kernel) kernel))

;; Raised in a task to quit it. Not an Error, so handlers for errors do not
;; swallow it.
(defclass quit-condition ((forced? : :boolean))
  final: #t)

;; The task running in this thread, or #f outside tasks. ./loop binds it
;; and owns the task class.
(def current-task (make-parameter #f))

;; One line describing an exception, for a message to the user.
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
