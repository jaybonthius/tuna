;;; The kernel's state.
;;; Everything here is confined to the editor baton (ADR 3, ADR 4).
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
        kernel-cached-services
        kernel-cached-services-set!
        kernel-loop
        exception-summary)

(defclass kernel
  ((plugins   : HashTable)       ; plugin name -> plugin record
   (services  : HashTable)       ; service name -> private service slot
   (providers : entry-table)     ; service name -> provider entries
   (cached-services : :list)     ; service objects whose dispatch cells were read
   (loop      : :t))             ; the editor loop object, owned by ./loop
  final: #t)

(def (new-kernel) => kernel
  (kernel plugins: (make-hash-table)
          services: (make-hash-table)
          providers: (new-entry-table)
          cached-services: []
          loop: #f))

;; The kernel facade does not export this; tests select a fresh kernel
;; through call-with-fresh-kernel in tuna/test-support/kernel.ss.
(def current-kernel (make-parameter (new-kernel)))

(def (the-kernel) => kernel
  (: (current-kernel) kernel))

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
