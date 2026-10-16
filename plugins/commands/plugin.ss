#lang :tuna/prelude
;;; Command registry and thread-scoped activations (ADR 8, ADR 14).
(import :std/interface (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel :tuna/lib/advice :tuna/plugins/commands/contract)
(export commands)

(defclass command-registry ((entries : entry-table) (targets : HashTable) (last :? :symbol)) final: #t)
;; Definitions retain their original records, even while shadowed. A name's
;; advice outlives its definitions, but an entirely empty name is not cached.
(defclass command-target ((state : advice-state) (definitions : :list)) final: #t)
(defclass command-definition ((ctx : context) (base : command) (installed-entry :? entry)
                              (retiring-task : :box)) final: #t)

(def (prune-target! (self : command-registry) (name : :symbol) (target : command-target)) => :void
  (when (and (null? target.definitions) (not (advice-state-has-owners? target.state))
             (eq? (hash-get self.targets name) target))
    (hash-remove! self.targets name)))

(def (rebuild-definition! (definition : command-definition) (records : :list)) => :void
  (using (base definition.base : command)
    (let ((ctx definition.ctx)
          (retiring-task definition.retiring-task)
          (combined (compose-advice base.procedure records)))
      (set! (command-procedure (entry-value (: definition.installed-entry entry)))
        ;; The entire combined command belongs to the command's owner;
        ;; advice restores its own registration context inside this scope.
        (lambda ()
          (with-catch
           (lambda (e)
             (unless (and (quit-condition? e) (unbox retiring-task)
                          (eqv? (unbox retiring-task) (current-task-id)))
               (raise e)))
           (lambda () (call-with-task-owner ctx combined))))))))

(def (ensure-target! (self : command-registry) (name : :symbol)) => command-target
  (or (hash-get self.targets name)
      (letrec ((target
                (command-target
                 state: (new-advice-state 'command name #f
                          (lambda (records)
                            (for-each (lambda ((definition : command-definition))
                                        (rebuild-definition! definition records))
                                      (command-target-definitions target))
                            (prune-target! self name target)))
                 definitions: [])))
        (hash-put! self.targets name target)
        target)))

(def (install-command! (self : command-registry) (ctx : context)
                       (base : command) (source :? :string)) => :void
  (let* ((name base.name)
         (target (: (ensure-target! self name) command-target))
         (owner (context-plugin-name ctx))
         (definition
          (or (find (lambda ((d : command-definition))
                      (eq? (context-plugin-name d.ctx) owner)) (command-target-definitions target))
              (let (new (command-definition ctx: ctx base: base installed-entry: #f retiring-task: (box #f)))
                ;; One inverse per owner/name, not per redefinition/recomposition.
                (context-defer! ctx
                  (lambda ()
                    (set-box! (command-definition-retiring-task new) (current-task-id))
                    (set! (command-target-definitions target)
                      (remq new (command-target-definitions target)))
                    (prune-target! self name target)))
                (set! (command-target-definitions target) (cons new (command-target-definitions target)))
                new))))
    (set! (command-definition-base definition) base)
    (set! (command-definition-installed-entry definition)
      (context-add-entry! ctx self.entries name
        (make-command name: base.name procedure: base.procedure doc: base.doc
                      visible?: base.visible? modes: base.modes arguments: base.arguments)
        doc: base.doc source: source))
    (rebuild-definition! definition (advice-state-records (command-target-state target)))))
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
  (define-command! (lambda (self ctx c source) (install-command! self ctx c source)))
  (add-advice! (lambda (self ctx name advice-name kind callback source: source depth: depth)
                 (let (target (ensure-target! self name))
                   (with-catch
                    (lambda (e) (prune-target! self name target) (raise e))
                    (lambda ()
                      (register-advice! ctx (command-target-state target)
                                        advice-name kind callback source: source depth: depth))))))
  (remove-advice! (lambda (self ctx name advice-name)
                    (let (target (hash-get self.targets name))
                      (when target (remove-advice! ctx (command-target-state target) advice-name)))))
  (inspect-advice (lambda (self name)
                    (let (target (hash-get self.targets name))
                      (inspect-advice (if target (command-target-state target)
                                         (new-advice-state 'command name #f void))))))
  (advised-commands (lambda (self)
                      (filter-map (lambda ((target : command-target))
                                    (and (pair? (advice-state-records target.state))
                                         (inspect-advice target.state)))
                                  (hash-values self.targets))))
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
                    (Commands (command-registry entries: (new-entry-table) targets: (make-hash-table) last: #f)) view: Commands-service-view))
