;;; Input and Messages providers for kernel, library, and plugin tests. The
;;; Input provider takes plain strings, which shows that the kernel never
;;; looks inside an input item. test-messages provides only
;;; Messages, for tests whose input comes from another plugin, such as keys.
(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel)
(export test-input
        test-messages
        test-bindings
        make-string-input
        current-message)

;; Resolves an item through its bindings (item -> (task name . thunk)) and
;; classifies the item "quit" as an interrupt.
(defstruct string-input ((bindings : HashTable))
  final: #t)

(defmethod {resolve! string-input}
  (lambda (self item)
    (hash-get (string-input-bindings self) item)))

(defmethod {arrival string-input}
  (lambda (self item)
    (if (equal? item "quit") 'interrupt 'queue)))

;; The bindings of every test-input's provider.
(def test-bindings (make-hash-table))

(defstruct message-recorder ((text : :string))
  final: #t)

(defmethod {message! message-recorder}
  (lambda (self text) (set! (message-recorder-text self) text)))

;; The last message, or "" without a test-input or test-messages.
(def (current-message) => :string
  (let (provider (service-provider messages-service))
    (if provider (message-recorder-text provider) "")))

(defplugin (test-input ctx)
  "Resolves test input items through test-bindings and keeps the last message."
  provides: [messages-service input-service]
  (context-provide! ctx messages-service (make-message-recorder ""))
  (context-provide! ctx input-service (make-string-input test-bindings)))

(defplugin (test-messages ctx)
  "Keeps the last message."
  provides: [messages-service]
  (context-provide! ctx messages-service (make-message-recorder "")))
