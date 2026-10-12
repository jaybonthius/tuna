;;; Test fixtures for the kernel, included by test files (not a module).

;; Input provider over plain strings, which shows that the kernel never
;; looks inside an input item: it resolves an item through BINDINGS (item
;; -> (task name . thunk)) and classifies the item "quit" as an interrupt.
(defstruct test-input ((bindings : HashTable))
  final: #t)

(defmethod {resolve! test-input}
  (lambda (self item)
    (hash-get (test-input-bindings self) item)))

(defmethod {arrival test-input}
  (lambda (self item)
    (if (equal? item "quit") 'interrupt 'queue)))

(def test-bindings (make-hash-table))

(defstruct test-messages ((text : :string))
  final: #t)

(defmethod {message! test-messages}
  (lambda (self text) (set! (test-messages-text self) text)))

(def (current-message)
  (let (provider (service-provider messages-service))
    (if provider (test-messages-text provider) "")))

(defplugin (test-input-plugin ctx)
  "Resolves test input items through test-bindings and keeps the last message."
  (context-provide! ctx messages-service (make-test-messages ""))
  (context-provide! ctx input-service (make-test-input test-bindings)))

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
