;;; Configuration's activation gate. Imports describe author dependencies;
;;; contexts and receipts describe ownership. Neither requires per-call checks.
prelude: :gerbil/core

(import (only-in :gerbil/expander
                 import-module __module-registry module-context module-context? module-context-id module-context-path
                 module-context-import module-context-export import-set? import-set-source
                 module-import? module-import-source module-export-context module-export-phi
                 core-resolve-module-export module-binding? binding-id)
        (rename-in (only-in :tuna/kernel/plugins activate-plugin!)
                   (activate-plugin! activate-kernel-plugin!))
        :tuna/kernel)
(export activate-checked-plugin!
        check-plugin-declarations!)

;; Read resolved imports, including only-in, rename-in and relative imports.
;; Do not follow a contract's imports: its own provider declares those uses.
(def (module-imports (module : module-context)) => :list
  (filter-map
   (lambda (import)
     (cond
      ((module-context? import) import)
      ((import-set? import) (import-set-source import))
      ((module-import? import) (module-export-context (module-import-source import)))
      (else #f)))
   (module-context-import module)))

;; Only bindings defined here count. In particular, the kernel facade's
;; re-exports of its consumed seams do not make it a service contract.
(def (module-values (module : :t)) => :list
  (filter-map
   (lambda (export)
     (and (fx= (module-export-phi export) 0)
          (let (binding (core-resolve-module-export export))
            (and (module-binding? binding)
                 ;; The registry also contains macro-only imports whose
                 ;; runtime globals have not been initialized.
                 (with-catch (lambda (_) #f) (lambda () (eval (binding-id binding))))))))
   (module-context-export module)))

;; Modules are already evaluated by init.ss's imports. Identity finds the
;; defining module even through renamed imports and re-exporting aggregators.
(def (plugin-module (p : plugin)) => (Maybe module-context)
  (let (found #f)
    (hash-for-each
     (lambda (_ module)
       (when (and (not found) (module-context? module)
                  (memq p (module-values module)))
         (set! found module)))
     __module-registry)
    (or found
        ;; Factories can return a plugin without exporting that particular
        ;; value. Inspect its defining source without evaluating it again.
        (let (source (plugin-source-path p))
          (and source (file-exists? source)
               (not (equal? (call-with-input-file source read-line) "#lang :tuna/config"))
               (import-module source))))))

;; Source locations have a final :LINE. Compiled plugins retain this location.
(def (plugin-source-path (p : plugin)) => (Maybe :string)
  (let (source (plugin-source p))
    (and source
         (let (colon (string-rindex source #\:))
           (and colon (substring source 0 colon))))))

;; Gerbil's source package root, not the repository or a Tuna-specific path.
;; The package: value supplies the module-id prefix, also for compiled imports.
(def (source-package (path : :string)) => (Maybe :string)
  (let walk ((directory (path-directory path)))
    (let (metadata (path-expand "gerbil.pkg" directory))
      (if (file-exists? metadata)
        (let* ((properties (call-with-input-file metadata read))
               (prefix (pgetq package: properties)))
          (and prefix (if (symbol? prefix) (symbol->string prefix) prefix)))
        (let (parent (path-directory (path-strip-trailing-directory-separator directory)))
          (and (not (equal? parent directory)) (walk parent)))))))

(def (same-package? (module : :t) (root : module-context) (prefix :? :string)) => :boolean
  (if prefix
    (let (id (symbol->string (module-context-id module)))
      (string-prefix? (string-append prefix "/") id))
    ;; Unpackaged user modules: siblings and descendants, not every module
    ;; on the load path. init.ss itself is never traversed.
    (let ((path (module-context-path module)) (home (module-context-path root)))
      (and (string? path) (string? home)
           (string-prefix? (path-directory home) path)))))

;; A contract is any imported module defining and exporting service values,
;; irrespective of its filename or package prefix. All its services count,
;; including for filtered vocabulary-only imports; this is deliberately an
;; import rule, not an attempt to infer which execution paths call a method.
(def (check-plugin-declarations! (p : plugin)) => :void
  (let ((root (plugin-module p)) (source (plugin-source-path p)))
    ;; Source-less distributions lack the original gerbil.pkg root: .ssi
    ;; records only a module directory. Refuse rather than miss siblings.
    (when (and source (not (file-exists? source)))
      (error (string-append "no source package found for plugin "
                            (symbol->string (plugin-name p))
                            "; Tuna checks a plugin's declared services against its source")))
    ;; Locally defined init/config/evaluation plugins are user code.
    ;; Their registrations still have receipts.
    ;; The start-up program owns the session evaluator and block follower;
    ;; neither is a package declared by init.ss. Both run the user's code.
    (when (and root (not (memq (module-context-id root) '(tuna/boot tuna/config-blocks))))
      (let* ((prefix (and source (source-package source)))
             (declared (append (plugin-requires p) (plugin-optional p) (plugin-provides p)))
             (problems []))
        (let walk ((pending [root]) (seen []))
          (unless (null? pending)
            (let ((module (car pending)) (rest (cdr pending)))
              (if (memq module seen)
                (walk rest seen)
                (let ((private []) (visited (cons module seen)))
                  (for-each
                   (lambda (imported)
                     (let (services (filter service? (module-values imported)))
                       (for-each
                        (lambda ((svc : service))
                          (unless (ormap (lambda ((use : service))
                                           (eq? (service-name use) (service-name svc))) declared)
                            (let (problem
                                  (string-append (symbol->string (plugin-name p)) " imports "
                                    (symbol->string (module-context-id imported))
                                    " but does not declare " (symbol->string (service-name svc))
                                    "-service"))
                              (unless (member problem problems)
                                (set! problems (cons problem problems)))))) services)
                       (when (and (null? services) (same-package? imported root prefix))
                         (set! private (cons imported private)))))
                   (module-imports module))
                  (walk (append private rest) visited))))))
        (unless (null? problems) (error (string-join (reverse problems) "\n")))))))

;; Every configuration/user activation enters here, including swaps and
;; interactive evaluation. The raw runtime operation is private to Tuna.
(def (activate-checked-plugin! (p : plugin) order: (rank :? :fixnum := #f)) => :void
  (check-plugin-declarations! p)
  (activate-kernel-plugin! p order: rank))
