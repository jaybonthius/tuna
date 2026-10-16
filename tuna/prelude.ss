;;; Package procedures are open; the kernel and local definitions stay closed.
prelude: :gerbil/core

(import :gerbil/core
        :tuna/kernel
        :tuna/lib/advice)
;; Keep the core re-export last: a prelude imports exports weakly, in reverse
;; order, so the package definitions must win over the core's def and def*.
(export (rename: def/open def)
        (rename: def def/closed)
        (rename: def*/open def*)
        redefine
        install-open! open-definition open-function-cell
        advise! unadvise! advice-for advised-functions
        advice-info advice-info-owner advice-info-name advice-info-kind
        advice-info-depth advice-info-source
        advice-target-info advice-target-info-kind advice-target-info-name
        advice-target-info-source advice-target-info-identity advice-target-info-advice advice-error?
        defplugin
        (phi: +1 read-module-body)
        (import: :gerbil/core))

(begin-syntax
  ;; Gerbil documents setq-macro mixins (guide/intro.md), set! targets
  ;; (prelude/macros.md), and syntax-local-value (expander/README.md).
  ;; Like src/gerbil/core/match.ss, keep metadata on the macro object itself.
  (defclass (open-binding setq-macro)
    ((facade : :t) (cell : :t)))

  (def (new-open-binding (facade : :t) (cell : :t) (installer : :t)) => open-binding
    (make-open-binding
      facade: facade cell: cell
      macro:
      (with-syntax ((facade facade) (cell cell) (installer installer))
        (identifier-rules (set!)
          ((set! reference replacement) (installer cell replacement))
          ((_ argument ...) (facade argument ...))
          (reference (identifier? #'reference) facade)))))

  (def (open-binding-cell-for (name : :t)) => :t
    (let (binding (syntax-local-value name (lambda (_) #f)))
      (unless (open-binding? binding)
        (raise-syntax-error #f "Expected an open function" name))
      (open-binding-cell binding)))

  ;; Retain the full signature on both facades and implementations. Only the
  ;; forwarding call drops contracts/defaults, referring to bound arguments.
  (def (forward-arguments (signature : :t)) => :values
    (let loop ((rest signature) (out []))
      (cond
       ((stx-null? rest) (values (reverse out) #f))
       ((identifier? rest) (values (reverse out) rest))
       ((stx-pair? rest)
        (let (arg (stx-car rest))
          (loop (stx-cdr rest)
                (cons (if (stx-pair? arg) (stx-car arg) arg) out))))
       (else (raise-syntax-error #f "Unsupported open function arguments" signature)))))
  (def (return-prefix (body : :t)) => :t
    (syntax-case body (=>)
      ((=> type rest ...) #'(=> type))
      (_ #'())))
  (def (assert-return (expression : :t) (body : :t)) => :t
    (syntax-case body (=> Maybe)
      ;; The ordinary nullable facade contract checks the dynamic result.
      ;; No unchecked nullable assertion is needed.
      ((=> (Maybe type) rest ...) expression)
      ((=> type rest ...)
       (with-syntax ((expression expression)) #'(:- expression type)))
      (_ expression))))

(defsyntax (def/open stx)
  (if (not (module-context? (current-expander-context)))
    (syntax-case stx () ((_ . rest) (syntax/loc stx (def . rest))))
    (syntax-case stx (lambda case-lambda => Maybe)
      ((_ name (case-lambda clause ...))
       (identifier? #'name)
       (syntax/loc stx (def*/open name clause ...)))
      ((_ name (lambda args body ...))
       (identifier? #'name)
       (syntax/loc stx (def/open (name . args) body ...)))
      ((_ ((head . outer) . inner) body ...)
       (syntax/loc stx (def/open (head . outer) (lambda inner body ...))))
      ((_ (name . args) body ...)
       (identifier? #'name)
       (let-values (((out tail) (forward-arguments #'args)))
         (with-syntax ((cell (stx-identifier #'name (syntax-e #'name) "::open-cell"))
                       (implementation (stx-identifier #'name (syntax-e #'name) "::open-body"))
                       (facade (stx-identifier #'name (syntax-e #'name) "::open-entry"))
                       (source (stx-source-string stx))
                       ((return ...) (return-prefix #'(body ...)))
                       ((out ...) out))
           (with-syntax ((forward
                          (if tail
                            (with-syntax ((tail tail))
                              #'(apply (open-function-effective cell) out ... tail))
                            #'((open-function-effective cell) out ...))))
             (with-syntax ((result (assert-return #'forward #'(body ...))))
               (syntax/loc stx
                 (begin
                   ;; Keep the original top-level typed-def expansion: a typed
                   ;; lambda cannot infer every named loop that def can infer.
                   (def (implementation . args) body ...)
                   (def cell (new-open-function implementation 'name source))
                   ;; Non-nullable results use :- to preserve proper tail calls.
                   ;; Nullable results use the ordinary checked return contract.
                   (def (facade . args) return ... result)
                   ;; Only NAME is visible to consumers. Calls expand to the
                   ;; typed facade; values denote that same stable facade.
                   (defsyntax name
                     (new-open-binding (quote-syntax facade) (quote-syntax cell)
                                       (quote-syntax replace-open-function!))))))))))
      ((_ . rest) (syntax/loc stx (def . rest))))))

(defsyntax (def*/open stx)
  (if (not (module-context? (current-expander-context)))
    (syntax-case stx () ((_ . rest) (syntax/loc stx (def* . rest))))
    (syntax-case stx ()
      ((_ name (args body ...) ...)
       (identifier? #'name)
       (with-syntax ((cell (stx-identifier #'name (syntax-e #'name) "::open-cell"))
                     (implementation (stx-identifier #'name (syntax-e #'name) "::open-body"))
                     (facade (stx-identifier #'name (syntax-e #'name) "::open-entry"))
                     (source (stx-source-string stx)))
         (with-syntax (((clause ...)
                        (map
                          (lambda (clause)
                            (syntax-case clause ()
                              ((signature body ...)
                               (let-values (((out tail) (forward-arguments #'signature)))
                                 (with-syntax (((out ...) out)
                                               ((return ...) (return-prefix #'(body ...))))
                                   (with-syntax ((forward
                                                  (if tail
                                                    (with-syntax ((tail tail))
                                                      #'(apply (open-function-effective cell) out ... tail))
                                                    #'((open-function-effective cell) out ...))))
                                     (with-syntax ((result (assert-return #'forward #'(body ...))))
                                       #'(signature return ... result))))))))
                          #'((args body ...) ...))))
           (syntax/loc stx
             (begin
               (def* implementation (args body ...) ...)
               (def cell (new-open-function implementation 'name source))
               (def* facade clause ...)
               (defsyntax name
                 (new-open-binding (quote-syntax facade) (quote-syntax cell)
                                   (quote-syntax replace-open-function!)))))))))))

(defsyntax (open-definition stx)
  (syntax-case stx ()
    ((_ name)
     (with-syntax ((cell (open-binding-cell-for #'name)))
       #'(open-function-base cell)))))

(defsyntax (install-open! stx)
  (syntax-case stx ()
    ((_ name replacement)
     (with-syntax ((cell (open-binding-cell-for #'name)))
       #'(replace-open-function! cell replacement)))))

(defrule (redefine (name . args) body ...)
  (install-open! name (lambda args body ...)))

;; This syntax seam also works inside a private target's module context.
(defsyntax (open-function-cell stx)
  (syntax-case stx ()
    ((_ name) (open-binding-cell-for #'name))))

(begin-syntax
  (def (function-target (target : :t)) => :t
    (syntax-case target ()
      ((tag module name)
       (and (eq? (syntax-e #'tag) 'function) (identifier? #'name))
       #'(resolve-open-function 'module 'name))
      (name (identifier? #'name) (open-binding-cell-for #'name))
      (_ (raise-syntax-error #f "Expected an open function or (function module name)" target))))

  ;; Concept contracts provide the router in the target head's use-site context.
  ;; The prelude owns normalization, never imports a concept or discovers it at runtime.
  (def (route-advice (target : :t) (action : :symbol) (arguments : :t)) => :t
    (syntax-case target ()
      ((tag name)
       (and (eq? (syntax-e #'tag) 'command) (identifier? #'name))
       (let (router (stx-identifier #'tag "command-advice-target"))
         (unless (syntax-local-value router (lambda (_) #f))
           (raise-syntax-error #f
             "Command advice requires importing command-advice-target from the commands contract" target))
         (with-syntax ((router router) (route-action (datum->syntax #'tag action)))
           (if (eq? action 'inspect)
             #'(router route-action 'name)
             (syntax-case arguments ()
               ((ctx argument ...)
                #'(router route-action ctx 'name argument ...)))))))
      (_
       (with-syntax ((cell (function-target target)))
         (case action
           ((inspect) #'(inspect-advice (open-function-state cell)))
           (else
            (with-syntax ((operation (if (eq? action 'add) #'register-advice! #'remove-advice!)))
              (syntax-case arguments ()
                ((ctx argument ...)
                 #'(operation ctx (open-function-state cell) argument ...)))))))))))

(defsyntax (advise! stx)
  (syntax-case stx ()
    ((_ ctx target name kind callback option ...)
     (let (kind-name
            (case (syntax-e #'kind)
              ((before:) 'before) ((after:) 'after) ((around:) 'around)
              ((override:) 'override) ((filter-args:) 'filter-args)
              ((filter-return:) 'filter-return) ((before-while:) 'before-while)
              ((before-until:) 'before-until) ((after-while:) 'after-while)
              ((after-until:) 'after-until)
              (else (raise-syntax-error #f "Unknown advice kind" stx #'kind))))
       (with-syntax ((kind-name kind-name)
                     (source (stx-source-string stx))
                     ;; Open callbacks already denote a stable, live facade. Only
                     ;; ordinary bindings need an extra late-lookup forwarding layer.
                     (procedure (if (and (identifier? #'callback)
                                         (not (open-binding?
                                               (syntax-local-value #'callback (lambda (_) #f)))))
                                  #'(lambda args (apply callback args)) #'callback)))
         (route-advice #'target 'add
           #'(ctx name 'kind-name procedure source: source option ...)))))))

(defsyntax (unadvise! stx)
  (syntax-case stx ()
    ((_ ctx target name)
     (route-advice #'target 'remove #'(ctx name)))))

(defsyntax (advice-for stx)
  (syntax-case stx ()
    ((_ target)
     (route-advice #'target 'inspect #'()))))

(begin-syntax
  (def (read-module-body (port :~ input-port?)) => :list
    (let lp ((body []))
      (let (next (read-syntax port))
        (if (eof-object? next)
          (cons '(declare (separate)) (reverse body))
          (lp (cons next body)))))))
