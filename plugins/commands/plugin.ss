#lang :tuna/prelude
;;; Command registry and thread-scoped activations (ADR 8, ADR 14).
;;;
;;; last-command is per client (ADR 16; Emacs keeps it per kboard): each
;;; command completes as the last command of the client it ran for
;;; (`current-client`). Work with no client, such as a timer, has a last
;;; command of its own, shared by all such work.
(import :std/interface (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel :tuna/lib/advice :tuna/plugins/commands/contract
        :tuna/plugins/clients/contract)
(export commands)

(defclass command-registry ((entries : entry-table)
                            (advice : HashTable)
                            (last-by-client : HashTable) ; client -> its last command
                            (last :? :symbol))           ; the last command of work with no client
  final: #t)

;; The last command of CLIENT (#f for none).
(def (client-last-command (self : command-registry) (c :? client)) => (Maybe :symbol)
  (if c (hash-get self.last-by-client c) self.last))

(def (set-client-last-command! (self : command-registry) (c :? client) (name : :symbol)) => :void
  (if c (hash-put! self.last-by-client c name) (set! self.last name)))
;; A command's advice and its composition, cached for the definition it was
;; built from: redefining the command or changing the advice rebuilds it.
(defclass command-advice ((target : advice-target) (base :? :procedure) (effective :? :procedure))
  final: #t)

(def (command-advice-for (self : command-registry) (name : :symbol)) => command-advice
  (or (hash-get self.advice name)
      (letrec ((state (command-advice
                       target: (new-advice-target 'command name #f
                                 (lambda (records)
                                   (set! (command-advice-base state) #f)
                                   (set! (command-advice-effective state) #f)))
                       base: #f effective: #f)))
        (hash-put! self.advice name state)
        state)))

;; BASE itself while NAME has no advice, so unadvised commands pay nothing.
(def (advised-procedure (self : command-registry) (name : :symbol) (base : :procedure)) => :procedure
  (let (found (hash-get self.advice name))
    (if (not found) base
      (using (state found : command-advice)
        (let (records (advice-target-records state.target))
          (cond
           ((null? records) base)
           ((eq? state.base base) (:- state.effective :procedure))
           (else
            (let (effective (compose-advice base records))
              (set! state.base base)
              (set! state.effective effective)
              effective))))))))
(defclass activation ((registry : command-registry)
                      (name : :symbol)
                      (previous :? :symbol)
                      (completed-name : :symbol))
  final: #t)
(def current-activation (make-parameter #f))

(def (registry-activation (self : command-registry)) => (Maybe activation)
  (let (a (current-activation))
    (and a (eq? (activation-registry a) self) a)))

(def (invoke! (self : command-registry) (name : :symbol)) => :t
  (let (e (entry-table-ref self.entries name))
    (unless e (error "Undefined command" name))
    (using (c (entry-value e) : command)
      (let* ((parent (registry-activation self))
             (a (activation registry: self name: name
                            previous: (if parent
                                        (activation-previous parent)
                                        (client-last-command self (current-client)))
                            completed-name: name)))
        (parameterize ((current-activation a))
          (unwind-protect
            (begin
              (run-hook pre-command-hook)
              (unwind-protect ((advised-procedure self name c.procedure))
                (run-hook post-command-hook)))
            ;; A nested programmatic invocation replaces the wrapper for
            ;; repetition (e.g. M-x). Prompt keystrokes run in other tasks.
            (let (completed (activation-completed-name a))
              (set-client-last-command! self (current-client) completed)
              (when parent
                (set! (activation-completed-name parent) completed)
                (set! (activation-previous parent) completed)))))))))

(implement Commands command-registry
  (define-command! (lambda (self ctx c source)
                     (context-add-entry! ctx self.entries (command-name c) c
                                         doc: (command-doc c) source: source)
                     (void)))
  (advice-target (lambda (self name)
                   (using (state (command-advice-for self name) : command-advice) state.target)))
  (command-entry (lambda (self name) (entry-table-ref self.entries name)))
  (command-names (lambda (self) (entry-table-names self.entries)))
  (call-command (lambda (self name) (invoke! self name)))
  (call-special-command (lambda (self name)
                          (let (e (entry-table-ref self.entries name))
                            (unless e (error "Undefined command" name))
                            (using (c (entry-value e) : command)
                              ((advised-procedure self name c.procedure))))))
  (this-command (lambda (self)
                  (let (a (registry-activation self)) (and a (activation-name a)))))
  (last-command (lambda (self)
                  (let (a (registry-activation self))
                    (if a (activation-previous a) (client-last-command self (current-client)))))))

(defplugin (commands ctx)
  "Defines, lists and invokes commands, independently of key bindings."
  provides: [commands-service]
  (using (self (command-registry entries: (new-entry-table) advice: (make-hash-table-eq)
                                 last-by-client: (make-hash-table-eq) last: #f)
               : command-registry)
    (context-add-hook! ctx client-gone-hook 'commands
                       (lambda ((c : client)) (hash-remove! self.last-by-client c)))
    (context-provide! ctx commands-service (Commands self))))
