;;; Input and Messages providers for kernel, library, and plugin tests. The
;;; Input provider takes plain strings, which shows that the kernel never
;;; looks inside an input item. test-messages-plugin provides only
;;; Messages, for tests whose input comes from another plugin, such as keys.
(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel)
(export test-input-plugin
        test-messages-plugin
        test-bindings
        make-test-input
        current-message)

;; Resolves an item through its bindings (item -> (task name . thunk)) and
;; classifies the item "quit" as an interrupt.
(defstruct test-input ((bindings : HashTable))
  final: #t)

(defmethod {resolve! test-input}
  (lambda (self item)
    (hash-get (test-input-bindings self) item)))

(defmethod {arrival test-input}
  (lambda (self item)
    (if (equal? item "quit") 'interrupt 'queue)))

;; The bindings of every test-input-plugin's provider.
(def test-bindings (make-hash-table))

(defstruct test-messages ((text : :string))
  final: #t)

(defmethod {message! test-messages}
  (lambda (self text) (set! (test-messages-text self) text)))

;; The last message, or "" without a test-input-plugin or test-messages-plugin.
(def (current-message) => :string
  (let (provider (service-provider messages-service))
    (if provider (test-messages-text provider) "")))

(defplugin (test-input-plugin ctx)
  "Resolves test input items through test-bindings and keeps the last message."
  provides: [messages-service input-service]
  (context-provide! ctx messages-service (make-test-messages ""))
  (context-provide! ctx input-service (make-test-input test-bindings)))

(defplugin (test-messages-plugin ctx)
  "Keeps the last message."
  provides: [messages-service]
  (context-provide! ctx messages-service (make-test-messages "")))
