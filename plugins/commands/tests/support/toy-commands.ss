;;; A deliberately small Commands double: one entry table per name,
;;; linear lookup, with command hooks and thread-scoped identity. Advice
;;; is composed on every call instead of cached.
prelude: :gerbil/core
(import :std/interface :tuna/kernel :tuna/lib/advice :tuna/plugins/commands/contract)
(export toy-commands)

(defclass toy-command-registry ((tables : :list) (targets : :list) (previous :? :symbol)) final: #t)
(def toy-activation (make-parameter #f))

(def (toy-entry (self : toy-command-registry) (name : :symbol)) => (Maybe entry)
  (let (row (assq name self.tables))
    (and row (entry-table-ref (cdr row) name))))

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
              ((compose-advice (command-procedure (entry-value e))
                               (advice-target-records (toy-target self name))))
              (run-hook post-command-hook)))
          (begin
            (set! self.previous (vector-ref frame 2))
            (when parent
              (vector-set! parent 2 self.previous)
              (vector-set! parent 1 self.previous))))))))

(def (toy-target (self : toy-command-registry) (name : :symbol)) => advice-target
  (let (row (assq name self.targets))
    (if row (cdr row)
      (let (target (new-advice-target 'command name #f void))
        (set! self.targets (cons (cons name target) self.targets))
        target))))

(implement Commands toy-command-registry
  (define-command! (lambda (self ctx c source)
                     (let* ((name (command-name c))
                            (row (assq name self.tables))
                            (table (if row (cdr row) (new-entry-table))))
                       (unless row (set! self.tables (cons (cons name table) self.tables)))
                       (context-add-entry! ctx table name c doc: (command-doc c) source: source)
                       (void))))
  (advice-target (lambda (self name) (toy-target self name)))
  (command-entry (lambda (self name) (toy-entry self name)))
  (command-names (lambda (self)
                   (filter (lambda (name) (toy-entry self name)) (map car self.tables))))
  (call-command (lambda (self name) (toy-call self name)))
  (call-special-command (lambda (self name)
                          (let (e (toy-entry self name))
                            (unless e (error "Undefined command" name))
                            ((compose-advice (command-procedure (entry-value e))
                                             (advice-target-records (toy-target self name)))))))
  (this-command (lambda (self)
                  (let (frame (toy-activation)) (and frame (vector-ref frame 0)))))
  (last-command (lambda (self)
                  (let (frame (toy-activation))
                    (if frame (vector-ref frame 1) self.previous)))))

(defplugin (toy-commands ctx)
  "Commands without a Keys dependency, using linear registry lookup."
  provides: [commands-service]
  (context-provide! ctx commands-service (Commands (toy-command-registry tables: [] targets: [] previous: #f))))
