;;; Hooks: named, ordered lists of named callbacks (ADR 2, ADR 12). Each
;;; hook object holds its own callbacks; the kernel keeps no table of hooks.
;;; Callbacks run by depth, then owner declaration order, then owner name
;;; (plugins not declared in init.ss share rank 0); callbacks within one
;;; owner retain their registration order.
;;; Plugins add callbacks with context-add-hook! and call them with run-hook,
;;; both in ./plugins, which reports failing callbacks.
;;;
;;; A hook is usually a module-level value, so every kernel in the process
;;; shares it. Each callback therefore records the kernel whose plugin added
;;; it, and only the current kernel's callbacks are called or listed: a
;;; kernel dropped without deactivating its plugins cannot reach another.
;;;
;;; The callback list is replaced, never changed in place, under the hook's
;;; mutex. Callers iterate the list they read, so adding or removing a
;;; callback while the hook runs, or from another thread, affects only later
;;; runs.
prelude: :gerbil/core

(import ./ids
        ./entries
        ./state)
(export hook
        hook-name
        new-hook
        hook-callback-names
        hook-callback
        hook-callback-name
        hook-callback-owner
        hook-callback-procedure
        hook-callback-undo
        hook-callback-undo-set!
        add-hook-callback!
        remove-hook-callback!
        current-hook-callbacks)

(defclass hook ((name      : :symbol)
                (doc       : :string)
                (lock      : :mutex)
                (callbacks : :list))       ; membership across kernels; reads order a snapshot
  final: #t)

(defclass hook-callback ((name      : :symbol)
                         (owner     : :symbol)       ; plugin name
                         (home      : kernel)        ; the kernel whose plugin added it
                         (order     : owner-order)   ; shared with its retained owner's entries
                         (depth     : :fixnum)
                         (serial    : :fixnum)
                         (procedure : :procedure)
                         (undo      :? :procedure)) ; its context's receipt inverse
  final: #t)

(def (new-hook (name : :symbol) doc: (doc : :string := "")) => hook
  (hook name: name doc: doc lock: (make-mutex name) callbacks: []))

(def (runs-before? (a : hook-callback) (b : hook-callback)) => :boolean
  (or (fx< a.depth b.depth)
      (and (fx= a.depth b.depth)
           (let ((a-rank (owner-order-rank a.order))
                 (b-rank (owner-order-rank b.order)))
             (or (fx< a-rank b-rank)
                 (and (fx= a-rank b-rank)
                      (if (eq? a.owner b.owner)
                        (fx< a.serial b.serial)
                        (string<? (symbol->string a.owner) (symbol->string b.owner)))))))))

;; Add PROCEDURE to H under NAME for the current kernel's plugin OWNER, and
;; return the new callback.
(def (add-hook-callback! (h : hook) (name : :symbol) (owner : :symbol)
                         (order : owner-order) (depth : :fixnum) (procedure : :procedure))
  => hook-callback
  (with-lock h.lock
    (lambda ()
      (let* ((same (find (lambda ((old : hook-callback))
                           (and (eq? old.home (the-kernel))
                                (eq? old.owner owner) (eq? old.name name)))
                         h.callbacks))
             (new (hook-callback name: name owner: owner home: (the-kernel) order: order depth: depth
                                 serial: (if same (hook-callback-serial same) (next-id!))
                                 procedure: procedure undo: #f)))
        (set! h.callbacks (cons new (if same (remq same h.callbacks) h.callbacks)))
        new))))

(def (remove-hook-callback! (h : hook) (old : hook-callback)) => :void
  (with-lock h.lock
    (lambda () (set! h.callbacks (remq old h.callbacks)))))

;; Read current ranks so retained owners can be reordered without a hook registry.
(def (current-hook-callbacks (h : hook)) => :list
  (let (k (the-kernel))
    (list-sort runs-before?
      (filter (lambda ((callback : hook-callback)) (eq? callback.home k))
              h.callbacks))))

;; The names of H's callbacks in the current kernel, in calling order.
(def (hook-callback-names (h : hook)) => :list
  (map hook-callback-name (current-hook-callbacks h)))
