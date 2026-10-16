;;; Explicit declarations for complete, typed service facades.
prelude: :gerbil/core

(import :std/interface)
(export service-interface service-interface-out
        service-view make-service-view service-view?
        service-view-operations service-view-build)

;; Operations and the builder are immutable by convention; no mutators escape.
(defstruct service-view ((operations : :list) (build : :procedure))
  final: #t)

(begin-syntax
  ;; Own declaration syntax, never Gerbil's interface metadata.
  (defclass (service-declaration macro-object) ((paths : :t)))

  (def (companion (name : :t)) => :t
    (stx-identifier name name "-service-signatures"))

  (def (parent-paths (parent : :t)) => :list
    (let (binding (syntax-local-value (companion parent) (lambda (_) #f)))
      (unless (service-declaration? binding)
        (raise-syntax-error #f "Parent requires a service-interface declaration and its exported signatures" parent))
      (syntax->list (syntax-local-introduce (service-declaration-paths binding)))))

  (def (parse-signatures (specs : :t)) => :list
    (syntax-case specs (=>)
      (((operation . arguments) => result . rest)
       (cons #'(operation arguments result) (parse-signatures #'rest)))
      (((operation . arguments) . rest)
       (cons #'(operation arguments :t) (parse-signatures #'rest)))
      (() [])
      (_ (raise-syntax-error #f "Invalid service operation signature" specs))))

  (def (unique-operations (signatures : :list)) => :list
    (let loop ((rest signatures) (seen []) (out []))
      (if (null? rest) (reverse out)
        (let* ((signature (car rest)) (name (stx-e (stx-car signature))))
          (if (memq name seen) (loop (cdr rest) seen out)
            (loop (cdr rest) (cons name seen) (cons signature out)))))))

  (def (unique-paths (paths : :list)) => :list
    (let loop ((rest paths) (seen []) (out []))
      (if (null? rest) (reverse out)
        (let* ((path (car rest)) (name (stx-car path)))
          (if (ormap (cut free-identifier=? name <>) seen)
            (loop (cdr rest) seen out)
            (loop (cdr rest) (cons name seen) (cons path out)))))))

  ;; The interface facade has already supplied defaults. Forward every bound
  ;; argument explicitly, so the additional layer never evaluates them again.
  (def (forward-arguments (arguments : :t)) => :values
    (let loop ((rest arguments) (out []))
      (cond
       ((stx-null? rest) (values (reverse out) #f))
       ((identifier? rest) (values (reverse out) rest))
       ((stx-pair? rest)
        (let (argument (stx-car rest))
          (loop (stx-cdr rest)
                (cons (if (stx-pair? argument) (stx-car argument) argument) out))))
       (else (raise-syntax-error #f "Invalid service operation arguments" arguments)))))

  (def (forward-call (procedure : :t) (arguments : :t)) => :t
    (let-values (((out tail) (forward-arguments arguments)))
      (with-syntax ((procedure procedure) ((out ...) out))
        (if tail
          (with-syntax ((tail tail)) #'(apply procedure out ... tail))
          #'(procedure out ...)))))

  (def (checked-result (expression : :t) (result : :t)) => :t
    (with-syntax ((call expression) (return-type result))
      (syntax-case result (Maybe)
        ((Maybe type) #'(:? call type))
        (_ #'(: call return-type)))))

  (def (operation-field (klass : :t) (operation : :t)) => :t
    (stx-identifier klass "chain-" operation))

  (def (operation-accessor (klass : :t) (operation : :t)) => :t
    (stx-identifier klass klass "-chain-" operation))

  (def (make-implementation (klass : :t) (signature : :t)) => :t
    (syntax-case signature ()
      ((operation arguments result)
       (let-values (((out tail) (forward-arguments #'arguments)))
         (with-syntax ((arguments (if tail
                                   (with-syntax (((out ...) out) (tail tail)) #'(out ... . tail))
                                   out))
                       (body (checked-result
                               (forward-call
                                 (with-syntax ((accessor (operation-accessor klass #'operation)))
                                   #'(accessor self))
                                 #'arguments)
                               #'result)))
           #'(operation (lambda (self . arguments) body)))))))

  (def (make-chain (interface : :t) (signature : :t)) => :t
    (syntax-case signature ()
      ((operation arguments result)
       (let-values (((out tail) (forward-arguments #'arguments)))
         (with-syntax ((dispatch (stx-identifier interface interface "-" #'operation))
                       ((out ...) out))
           (with-syntax ((call (if tail
                                (with-syntax ((tail tail)) #'(apply dispatch raw out ... tail))
                                #'(dispatch raw out ...))))
             #'(: (compose 'operation (lambda arguments => result call)) :procedure)))))))

  (def (expand-service-interface (stx : :t) (head : :t) (specs : :t)) => :t
    (let* ((name (if (identifier? head) head (stx-car head)))
           (parents (if (identifier? head) [] (syntax->list (stx-cdr head))))
           (inherited (unique-paths (apply append (map parent-paths parents))))
           (signatures (unique-operations
                         (append (parse-signatures specs)
                                 (apply append (map (lambda (path) (syntax->list (stx-cdr path)))
                                                    inherited)))))
           (klass (stx-identifier name name "::service-view"))
           (paths (cons (cons name signatures) inherited)))
      (with-syntax ((head head)
                    (name name)
                    ((spec ...) specs)
                    (description (stx-identifier name name "-service-view"))
                    (metadata (companion name))
                    (klass klass)
                    (builder (stx-identifier name "build-" name "-service-view"))
                    (constructor (stx-identifier klass "make-" klass))
                    ((paths ...) paths)
                    ((operation ...) (map stx-car signatures))
                    ((field ...) (map (cut operation-field klass <>) (map stx-car signatures)))
                    ((chain ...) (map (cut make-chain name <>) signatures))
                    ((init ...) (apply append
                                       (map (lambda (signature)
                                              (let (field (operation-field klass (stx-car signature)))
                                                [(make-keyword (stx-e field)) field]))
                                            signatures)))
                    ((implementation ...)
                     (map (lambda (path)
                            (with-syntax ((parent (stx-car path))
                                          (target klass)
                                          ((method ...) (map (cut make-implementation klass <>)
                                                             (syntax->list (stx-cdr path)))))
                              #'(implement parent target method ...)))
                          paths)))
        (syntax/loc stx
          (begin
            (interface head spec ...)
            (defsyntax metadata
              (make-service-declaration
                paths: (syntax (paths ...))
                macro: (lambda (use)
                         (raise-syntax-error #f "Service signatures are declaration metadata" use))))
            (defclass klass ((field : :procedure) ...) final: #t)
            implementation ...
            (def (builder (provider : :t) (compose : :procedure)) => name
              (let* ((raw (name provider)) (field chain) ...)
                (name (constructor init ...))))
            (def description (make-service-view '(operation ...) builder))))))))

(defsyntax (service-interface stx)
  (syntax-case stx ()
    ((_ head spec ...)
     (expand-service-interface stx #'head #'(spec ...)))))

(defsyntax-for-export (service-interface-out stx)
  (syntax-case stx ()
    ((_ name ...)
     (with-syntax (((description ...) (map (lambda (name) (stx-identifier name name "-service-view"))
                                         #'(name ...)))
                   ((metadata ...) (map companion #'(name ...))))
       #'(begin: (interface-out name ...) description ... metadata ...)))))
