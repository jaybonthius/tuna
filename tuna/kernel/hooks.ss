;;; Hooks: named, ordered lists of named callbacks, registered through
;;; plugin contexts (ADR 2). Callbacks run in depth order, then in the order
;;; they were added. A callback that fails is removed and reported; the
;;; others still run.
prelude: :gerbil/core

(import ./ids
        ./state
        ./plugins)
(export (struct-out hook)
        new-hook
        context-add-hook!
        hook-callback-names
        run-hook)

(defstruct hook ((name : :symbol)
                 (doc  : :string))
  final: #t)

(defclass hook-callback ((name      : :symbol)
                         (owner     : :symbol)       ; plugin name
                         (depth     : :fixnum)
                         (serial    : :fixnum)
                         (procedure : :procedure))
  final: #t)

(def (new-hook (name : :symbol) doc: (doc : :string := "")) => hook
  (make-hook name doc))

(def (callbacks (h : hook)) => :list
  (hash-ref (kernel-hooks (the-kernel)) (hook-name h) []))

(def (set-callbacks! (h : hook) (new : :list)) => :void
  (let (table (kernel-hooks (the-kernel)))
    (if (null? new)
      (hash-remove! table (hook-name h))
      (hash-put! table (hook-name h) new))))

(def (runs-before? (a : hook-callback) (b : hook-callback)) => :boolean
  (or (fx< a.depth b.depth)
      (and (fx= a.depth b.depth) (fx< a.serial b.serial))))

;; Add PROCEDURE to H under NAME for CTX's plugin; it is removed when the
;; plugin is deactivated.
(def (context-add-hook! (ctx : context)
                        (h : hook)
                        (name : :symbol)
                        (procedure : :procedure)
                        depth: (depth : :fixnum := 0))
  => :void
  (let (new (hook-callback name: name owner: (context-plugin-name ctx) depth: depth
                           serial: (next-id!) procedure: procedure))
    (set-callbacks! h (let insert ((rest (callbacks h)))
                        (match rest
                          ([] [new])
                          ([first . more]
                           (if (runs-before? new first)
                             (cons new rest)
                             (cons first (insert more)))))))
    (context-defer! ctx (lambda () (set-callbacks! h (remq new (callbacks h)))))))

;; The names of H's callbacks, in calling order.
(def (hook-callback-names (h : hook)) => :list
  (map hook-callback-name (callbacks h)))

;; Call each of H's callbacks with ARGS.
(def (run-hook (h : hook) . args) => :void
  (for-each
    (lambda ((callback : hook-callback))
      (with-catch
       (lambda (e)
         (set-callbacks! h (remq callback (callbacks h)))
         (message (string-append "Hook " (symbol->string (hook-name h)) " callback "
                                 (symbol->string callback.name) " (from "
                                 (symbol->string callback.owner) ") failed and was removed: "
                                 (exception-summary e))))
       (lambda () (apply callback.procedure args))))
    (callbacks h)))
