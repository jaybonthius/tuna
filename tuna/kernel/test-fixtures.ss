;;; Test fixtures for the kernel, included by test files (not a module).

;; Input provider that resolves an event's key string through BINDINGS
;; (key -> command name) and treats the key "quit" as the quit key.
(defstruct test-input ((bindings : HashTable))
  final: #t)

(defmethod {resolve-event! test-input}
  (lambda (self event)
    (let (name (hash-get (test-input-bindings self) (key-event-key event)))
      (and name (command-ref name)))))

(defmethod {quit-event? test-input}
  (lambda (self event)
    (equal? (key-event-key event) "quit")))

(def test-bindings (make-hash-table))

(defstruct test-messages ((text : :string))
  final: #t)

(defmethod {message! test-messages}
  (lambda (self text) (set! (test-messages-text self) text)))

(def (current-message)
  (let (provider (service-provider messages-service))
    (if provider (test-messages-text provider) "")))

(defplugin (test-input-plugin ctx)
  "Resolves test events through test-bindings and keeps the last message."
  (context-provide! ctx messages-service (make-test-messages ""))
  (context-provide! ctx input-service (make-test-input test-bindings)))

(def test-sequence 0)

(def (test-event key)
  (set! test-sequence (fx1+ test-sequence))
  (make-key-event "test-client" test-sequence key "" 0 #f #f #f #f #f #f))

;; Run THUNK in a fresh kernel, then stop its loop and plugins.
(def (call-with-test-kernel thunk)
  (parameterize ((current-kernel (new-kernel)))
    (try
     (thunk)
     (finally
      (stop-editor-loop!)
      (deactivate-all-plugins!)))))

;; Wait up to two seconds for (READY?) to become true.
(def (wait-until ready?)
  (let lp ((tries 200))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))
