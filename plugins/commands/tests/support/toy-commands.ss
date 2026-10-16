;;; A deliberately small Commands double: one entry table per name,
;;; linear lookup, with command hooks and thread-scoped identity.
prelude: :gerbil/core
(import :std/interface :tuna/kernel :tuna/lib/advice :tuna/plugins/commands/contract)
(export toy-commands)

(defclass toy-command-registry ((targets : :list) (previous :? :symbol)) final: #t)
(def toy-activation (make-parameter #f))

(defclass toy-target ((state : advice-state) (definitions : :list) (table : entry-table)) final: #t)
(defclass toy-definition ((ctx : context) (base : command) (installed-entry :? entry)
                              (retiring-task : :box)) final: #t)

(def (toy-prune! (self : toy-command-registry) (name : :symbol) (target : toy-target)) => :void
  (when (and (null? target.definitions) (not (advice-state-has-owners? target.state))
             (eq? (cond ((assq name self.targets) => cdr) (else #f)) target))
    (set! self.targets (filter (lambda (row) (not (eq? (cdr row) target))) self.targets))))

(def (toy-rebuild! (definition : toy-definition) (records : :list)) => :void
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

(def (toy-ensure! (self : toy-command-registry) (name : :symbol)) => toy-target
  (or (cond ((assq name self.targets) => cdr) (else #f))
      (letrec ((target
                (toy-target
                 state: (new-advice-state 'command name #f
                          (lambda (records)
                            (for-each (lambda ((definition : toy-definition))
                                        (toy-rebuild! definition records))
                                      (toy-target-definitions target))
                            (toy-prune! self name target)))
                 definitions: [] table: (new-entry-table))))
        (set! self.targets (cons (cons name target) self.targets))
        target)))

(def (toy-install! (self : toy-command-registry) (ctx : context)
                       (base : command) (source :? :string)) => :void
  (let* ((name base.name)
         (target (: (toy-ensure! self name) toy-target))
         (owner (context-plugin-name ctx))
         (definition
          (or (find (lambda ((d : toy-definition))
                      (eq? (context-plugin-name d.ctx) owner)) (toy-target-definitions target))
              (let (new (toy-definition ctx: ctx base: base installed-entry: #f retiring-task: (box #f)))
                ;; One inverse per owner/name, not per redefinition/recomposition.
                (context-defer! ctx
                  (lambda ()
                    (set-box! (toy-definition-retiring-task new) (current-task-id))
                    (set! (toy-target-definitions target)
                      (remq new (toy-target-definitions target)))
                    (toy-prune! self name target)))
                (set! (toy-target-definitions target) (cons new (toy-target-definitions target)))
                new))))
    (set! (toy-definition-base definition) base)
    (set! (toy-definition-installed-entry definition)
      (context-add-entry! ctx (toy-target-table target) name
        (make-command name: base.name procedure: base.procedure doc: base.doc
                      visible?: base.visible? modes: base.modes arguments: base.arguments)
        doc: base.doc source: source))
    (toy-rebuild! definition (advice-state-records (toy-target-state target)))))
(def (toy-entry (self : toy-command-registry) (name : :symbol)) => (Maybe entry)
  (let (row (assq name self.targets))
    (and row (entry-table-ref (toy-target-table (cdr row)) name))))

(def (toy-call (self : toy-command-registry) (name : :symbol)) => :t
  (let (e (toy-entry self name))
    (unless e (error "Undefined command" name))
    (let* ((parent (toy-activation))
          (frame (vector name (if parent (vector-ref parent 1) self.previous) name)))
      (parameterize ((toy-activation frame))
        (unwind-protect
          (begin
            (run-hook pre-command-hook)
            (unwind-protect
              ((command-procedure (entry-value e)))
              (run-hook post-command-hook)))
          (begin
            (set! self.previous (vector-ref frame 2))
            (when parent
              (vector-set! parent 2 self.previous)
              (vector-set! parent 1 self.previous))))))))

(implement Commands toy-command-registry
  (define-command! (lambda (self ctx c source) (toy-install! self ctx c source)))
  (add-advice! (lambda (self ctx name advice-name kind callback source: source depth: depth)
                 (let (target (toy-ensure! self name))
                   (with-catch
                    (lambda (e) (toy-prune! self name target) (raise e))
                    (lambda ()
                      (register-advice! ctx (toy-target-state target)
                                        advice-name kind callback source: source depth: depth))))))
  (remove-advice! (lambda (self ctx name advice-name)
                    (let (row (assq name self.targets))
                      (when row (remove-advice! ctx (toy-target-state (cdr row)) advice-name)))))
  (inspect-advice (lambda (self name)
                    (let (row (assq name self.targets))
                      (inspect-advice (if row (toy-target-state (cdr row))
                                         (new-advice-state 'command name #f void))))))
  (advised-commands (lambda (self)
                      (filter-map (lambda (row)
                                    (let (state (toy-target-state (cdr row)))
                                      (and (pair? (advice-state-records state)) (inspect-advice state))))
                                  self.targets)))
  (command-entry (lambda (self name) (toy-entry self name)))
  (command-names (lambda (self)
                   (filter (lambda (name) (toy-entry self name)) (map car self.targets))))
  (call-command (lambda (self name) (toy-call self name)))
  (this-command (lambda (self)
                  (let (frame (toy-activation)) (and frame (vector-ref frame 0)))))
  (last-command (lambda (self)
                  (let (frame (toy-activation))
                    (if frame (vector-ref frame 1) self.previous)))))

(defplugin (toy-commands ctx)
  "Commands without a Keys dependency, using linear registry lookup."
  provides: [commands-service]
  (context-provide! ctx commands-service (Commands (toy-command-registry targets: [] previous: #f)) view: Commands-service-view))
