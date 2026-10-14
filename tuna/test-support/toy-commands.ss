;;; A deliberately small Commands double: one entry table per name,
;;; linear lookup, with command hooks and thread-scoped identity.
prelude: :gerbil/core
(import :std/interface :tuna/kernel :tuna/services/commands)
(export toy-commands-plugin)

(defclass toy-commands ((tables : :list) (previous :? :symbol)) final: #t)
(def toy-activation (make-parameter #f))

(def (toy-entry (self : toy-commands) (name : :symbol)) => (Maybe entry)
  (let (row (assq name self.tables))
    (and row (entry-table-ref (cdr row) name))))

(def (toy-call (self : toy-commands) (name : :symbol)) => :t
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

(implement Commands toy-commands
  (define-command! (lambda (self ctx c source)
                     (let* ((name (command-name c))
                            (row (assq name self.tables))
                            (table (if row (cdr row) (new-entry-table))))
                       (unless row (set! self.tables (cons (cons name table) self.tables)))
                       (context-add-entry! ctx table name c doc: (command-doc c) source: source)
                       (void))))
  (command-entry (lambda (self name) (toy-entry self name)))
  (command-names (lambda (self)
                   (filter (lambda (name) (toy-entry self name)) (map car self.tables))))
  (call-command (lambda (self name) (toy-call self name)))
  (this-command (lambda (self)
                  (let (frame (toy-activation)) (and frame (vector-ref frame 0)))))
  (last-command (lambda (self)
                  (let (frame (toy-activation))
                    (if frame (vector-ref frame 1) self.previous)))))

(defplugin (toy-commands-plugin ctx)
  "Commands without a Keys dependency, using linear registry lookup."
  provides: [commands-service]
  (context-provide! ctx commands-service (Commands (toy-commands tables: [] previous: #f))))
