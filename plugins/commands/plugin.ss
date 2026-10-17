#lang :tuna/prelude
;;; Command registry and thread-scoped activations (ADR 8, ADR 14).
(import :std/interface :tuna/kernel :tuna/plugins/commands/contract)
(export commands)

(defclass command-registry ((entries : entry-table) (last :? :symbol)) final: #t)
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
                            previous: (if parent (activation-previous parent) self.last)
                            completed-name: name)))
        (parameterize ((current-activation a))
          (unwind-protect
            (begin
              (run-hook pre-command-hook)
              (unwind-protect (c.procedure) (run-hook post-command-hook)))
            ;; A nested programmatic invocation replaces the wrapper for
            ;; repetition (e.g. M-x). Prompt keystrokes run in other tasks.
            (begin
              (set! self.last (activation-completed-name a))
              (when parent
                (set! (activation-completed-name parent) self.last)
                (set! (activation-previous parent) self.last)))))))))

(implement Commands command-registry
  (define-command! (lambda (self ctx c source)
                     (context-add-entry! ctx self.entries (command-name c) c
                                         doc: (command-doc c) source: source)
                     (void)))
  (command-entry (lambda (self name) (entry-table-ref self.entries name)))
  (command-names (lambda (self) (entry-table-names self.entries)))
  (call-command (lambda (self name) (invoke! self name)))
  (this-command (lambda (self)
                  (let (a (registry-activation self)) (and a (activation-name a)))))
  (last-command (lambda (self)
                  (let (a (registry-activation self))
                    (if a (activation-previous a) self.last)))))

(defplugin (commands ctx)
  "Defines, lists and invokes commands, independently of key bindings."
  provides: [commands-service]
  (context-provide! ctx commands-service
                    (Commands (command-registry entries: (new-entry-table) last: #f))))
