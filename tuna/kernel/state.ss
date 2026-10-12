;;; The kernel's state and its output to the user.
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
        kernel-live?
        kernel-loop
        message
        current-message
        (struct-out help-output)
        show-help
        current-help
        exception-summary)

;; Help output shown in a panel until buffers exist (stage 2).
(defstruct help-output ((title : :string)
                        (lines : :list))
  final: #t)

(defclass kernel
  ((plugins   : HashTable)       ; plugin name -> plugin record
   (services  : HashTable)       ; service name -> service
   (providers : entry-table)     ; service name -> provider entries
   (commands  : entry-table)     ; command name -> command entries
   (live?     : :boolean)        ; the editor loop is running
   (echo      : :string)         ; the echo area
   (help      :? help-output)
   (loop      : :t))             ; the editor loop object, owned by ./loop
  final: #t)

(def (new-kernel) => kernel
  (kernel plugins: (make-hash-table)
          services: (make-hash-table)
          providers: (new-entry-table)
          commands: (new-entry-table)
          live?: #f
          echo: ""
          help: #f
          loop: #f))

;; Tests run each scenario in a fresh kernel by parameterizing this.
(def current-kernel (make-parameter (new-kernel)))

(def (the-kernel) => kernel
  (: (current-kernel) kernel))

;; Show TEXT in the echo area.
(def (message (text : :string)) => :void
  (using (k (the-kernel) : kernel)
    (set! k.echo text)))

(def (current-message) => :string
  (using (k (the-kernel) : kernel)
    k.echo))

(def (show-help (title : :string) (lines : :list)) => :void
  (using (k (the-kernel) : kernel)
    (set! k.help (make-help-output title lines))))

(def (current-help) => (Maybe help-output)
  (using (k (the-kernel) : kernel)
    k.help))

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
