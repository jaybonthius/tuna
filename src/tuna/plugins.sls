(library (tuna plugins)
  (export
    use-plugin
    plugin
    when-installed
    install-plugin!
    update-plugin!
    remove-plugin!
    remove-unused-plugins!
    installed-plugins
    plugin-commit)
  (import (chezscheme)
          (only (tuna plugin-manager) plugin-line? index-module? install-plugin!
                update-plugin! remove-plugin! remove-unused-plugins! installed-plugins plugin-commit)
          (only (tuna core definitions) site-module)
          (only (tuna core modules) module-exists? load-module!))

  (meta define line-shape
    "expected an id and clauses (git url), (commit hex), (branch name), (dir path) or (local folder)")

  (meta define (line-syntax? id clauses)
    (and (identifier? id) (plugin-line? (syntax->datum #`(use-plugin #,id #,@clauses)))))

  ;; The plugin's main module is named by the line's own id, so its names
  ;; are visible where the line stands.
  (define-syntax use-plugin
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id clause ...)
           (line-syntax? #'id #'(clause ...))
           (if (site-module #'id lookup)
               (syntax-violation 'use-plugin "a use-plugin line in a module" x)
               #'(import (id)))]
          [_ (syntax-violation 'use-plugin line-shape x)]))))

  (define-syntax plugin
    (lambda (x)
      (lambda (lookup)
        (syntax-case x ()
          [(_ id clause ...)
           (line-syntax? #'id #'(clause ...))
           (let ([module (site-module #'id lookup)])
             (if (and module (index-module? module))
                 #'(begin)
                 (syntax-violation 'plugin "a plugin line outside an index's main module" x)))]
          [_ (syntax-violation 'plugin line-shape x)]))))

  ;; Chez runs a library's body only when code refers to one of its
  ;; variables; Tuna runs every imported module's body.
  (define-syntax when-installed
    (lambda (x)
      (syntax-case x ()
        [(_ (part ...) body1 body2 ...)
         (for-all identifier? #'(part ...))
         (if (module-exists? (syntax->datum #'(part ...)))
             #'(let ()
                 (import (part ...))
                 (load-module! '(part ...))
                 (let () body1 body2 ...))
             #'(void))]
        [_ (syntax-violation 'when-installed "expected (when-installed (module-name ...) body ...)" x)]))))
