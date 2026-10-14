;;; Commands and key bindings: the key and pointer events a transport
;;; submits as input items, the part of the input service that plugins
;;; define commands and bind keys through, and the input-target stack
;;; (ADR 3, ADR 8). Plugins that define commands or bind keys require
;;; `input-service`.
;;;
;;; Keymaps are entry tables (`new-keymap`): every binding is an entry
;;; owned by the plugin that made it and goes when that plugin is turned
;;; off. Besides the global keymap, buffer nodes carry keymaps (the buffers
;;; contract's `node-keymap`; a buffer's root node's keymap is the buffer's
;;; own, Emacs's local map), and input targets do. The input service
;;; resolves a key in this order, the first keymap holding a binding or a
;;; longer sequence starting with the keys typed winning:
;;;   1. the keymap of the node that has focus (the selected view's
;;;      focused text node, or its buffer's root without one), then of
;;;      each node above it, up to the buffer's root;
;;;   2. the innermost input target's keymap;
;;;   3. the global keymap.
;;;
;;; Clicks are looked up like keys, by their Emacs event names (`mouse-1`,
;;; `C-mouse-1`, `double-mouse-1`), first with the kind of part clicked as
;;; a prefix key ("<tab-line> <mouse-1>", as Emacs's "<mode-line> <mouse-1>"),
;;; then without it; a double or triple click falls back to the single
;;; one. The keymaps are those of the same order, starting at the node
;;; clicked (or, with none, at the root of the clicked view's buffer); each
;;; keymap is searched under every one of those names before the next, so
;;; a node's `<mouse-1>` shadows the global `<view> <mouse-1>`. A command
;;; reads its click with `last-command-event` and `event-start`; the layout
;;; contract finds the view and node a posn names (`posn-view`,
;;; `posn-node`).
;;;
;;; The keymap generation (`keymap-generation`) changes whenever any
;;; binding is added or removed, so renderers that reuse HTML marked from
;;; bindings (`data-clickable`) know to draw it again.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (struct-out key-event posn pointer-event)
        pointer-event-names
        event-start
        part-clickable?
        keymap-clickable?
        keymap-generation
        report-stale-click
        (interface-out Keys)
        (struct-out command)
        context-define-command!
        define-command
        defcommand
        command-entry
        command-ref
        keymap-set
        keymap-set!
        keymap-set-in
        keymap-set-in!
        new-keymap
        (struct-out input-target)
        push-input-target!
        remove-input-target!
        key-binding
        printing-char-key
        last-command
        last-command-event)

;; One keydown from a client, with the client's id and sequence number
;; (ADR 7, ADR 10). The web transport submits it as an input item; the
;; input service resolves it.
(defstruct key-event ((client     : :string)
                      (sequence   : :fixnum)
                      (key        : :string)
                      (code       : :string)
                      (location   : :fixnum)
                      (repeat?    : :boolean)
                      (composing? : :boolean)
                      (alt?       : :boolean)
                      (ctrl?      : :boolean)
                      (meta?      : :boolean)
                      (shift?     : :boolean))
  final: #t)

;; Where a click happened (Emacs's position, `posn`): on the part of the
;; screen with kind AREA (tab-line, view, status-line; Emacs's `posn-area`) and
;; id PART, over the node with id NODE-ID if any, on the screen with
;; revision REVISION. Parts are named by stable id, never by position: a
;; view or its status line by the view's id, a tab of a tab line by the id
;; of the part it shows.
(defstruct posn ((area     : :symbol)
                 (part     : :fixnum)
                 (node-id  :? :fixnum)
                 (revision : :fixnum))
  final: #t)

;; One click from a client, with the client's id and sequence number
;; (ADR 7, ADR 10): BUTTON 1, 2 or 3 (left, middle, right, numbered as
;; Emacs does), released after CLICKS presses in a row, at START.
(defstruct pointer-event ((client   : :string)
                          (sequence : :fixnum)
                          (button   : :fixnum)
                          (clicks   : :fixnum)
                          (alt?     : :boolean)
                          (ctrl?    : :boolean)
                          (meta?    : :boolean)
                          (shift?   : :boolean)
                          (start    : posn))
  final: #t)

;; The names EVENT is looked up under, most specific first: modifiers,
;; then `double-` or `triple-`, then `mouse-BUTTON`; a triple click falls
;; back to the double one and a double to the single one, as in Emacs:
;; ("C-double-mouse-1" "C-mouse-1").
(def (pointer-event-names (event : pointer-event)) => :list
  (using (event : pointer-event)
    (let ((modifiers (string-append (if event.ctrl? "C-" "")
                                    (if event.alt? "M-" "")
                                    (if event.shift? "S-" "")
                                    (if event.meta? "s-" "")))
          (base (string-append "mouse-" (number->string event.button))))
      (map (lambda ((repeat : :string)) (string-append modifiers repeat base))
           (cond
            ((fx>= event.clicks 3) ["triple-" "double-" ""])
            ((fx= event.clicks 2) ["double-" ""])
            (else [""]))))))

;; Where EVENT happened: a pointer event's posn, or #f for a key event,
;; which has no position (Emacs gives point in the selected window).
(def (event-start (event : :t)) => (Maybe posn)
  (and (pointer-event? event) (pointer-event-start event)))

;; Report in the echo area that the part P names is gone, naming the
;; screen it was clicked on; the click does nothing else. WHAT names the
;; part ("tab"); by default, its kind.
(def (report-stale-click (p : posn) what: (what :? :string := #f)) => :void
  (message (string-append "Stale click: the "
                          (or what
                              (string-map (lambda (c) (if (char=? c #\-) #\space c))
                                          (symbol->string (posn-area p))))
                          " is gone (clicked on screen "
                          (number->string (posn-revision p)) ")")))

;; A named action that runs as a task, usually bound to keys.
(defstruct command ((name      : :symbol)
                    (procedure : :procedure)          ; thunk, run as a task
                    (doc       : :string))
  final: #t)

;; Binds every printing character that has no binding of its own.
(def printing-char-key "<printing-char>")

;; A keymap pushed on the input-target stack: while it is the innermost
;; target, keys resolve in KEYMAP before the global keymap.
(defstruct input-target ((name   : :symbol)
                         (keymap : entry-table))
  final: #t)

;; A keymap other than the global one: key sequence -> command name entries.
(def (new-keymap) => entry-table
  (new-entry-table))

(interface (Keys Input)
  ;; Define the command NAME, which runs PROCEDURE, owned by CTX's plugin
  ;; and defined at SOURCE.
  (define-command! (ctx : context) (name : :symbol) (procedure : :procedure) (doc : :string)
                   (source : :t))
  => :void
  ;; The effective entry for the command named NAME, or #f.
  (command-entry (name : :symbol)) => :t
  ;; Bind KEYS, in `keymap-set` syntax ("C-c l"), to the command named
  ;; COMMAND, owned by CTX's plugin and defined at SOURCE.
  (keymap-set! (ctx : context) (keys : :string) (command : :symbol) (source : :t)) => :void
  ;; The same, in KEYMAP instead of the global keymap.
  (keymap-set-in! (ctx : context) (keymap : entry-table) (keys : :string) (command : :symbol)
                  (source : :t))
  => :void
  ;; Make TARGET the innermost input target.
  (push-input-target! (target : input-target)) => :void
  ;; Remove TARGET, wherever it is in the stack.
  (remove-input-target! (target : input-target)) => :void
  ;; The effective binding entry for KEYS, or #f.
  (key-binding (keys : :string)) => :t
  ;; The name of the command whose keys were completed before the running
  ;; command's, or #f (Emacs `last-command`).
  (last-command) => :t
  ;; The key or pointer event that completed the running command's keys,
  ;; or #f (Emacs `last-command-event`).
  (last-command-event) => :t
  ;; A number that changes whenever a binding is added to or removed from
  ;; any keymap.
  (keymap-generation) => :fixnum)

(def (current-keys) => Keys
  (let (input (service-provider input-service))
    (unless (and input (is-Keys? input))
      (error "The input service does not provide key bindings" input))
    (Keys input)))

(def (context-define-command! (ctx       : context)
                              (name      : :symbol)
                              (procedure : :procedure)
                              doc:    (doc    : :string := "")
                              source: (source :? :string := #f))
  => :void
  (Keys-define-command! (current-keys) ctx name procedure doc source))

;; (define-command ctx (name) "doc" body ...)
(defsyntax (define-command stx)
  (syntax-case stx ()
    ((_ ctx (name) doc body ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(context-define-command! ctx 'name (lambda () body ...)
                                  doc: doc source: source)))))

;; (defcommand (name) "doc" body ...) in a plugin body defines a command
;; through (current-context).
(defsyntax (defcommand stx)
  (syntax-case stx ()
    ((_ (name) doc body ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(context-define-command! (current-context) 'name (lambda () body ...)
                                  doc: doc source: source)))))

;; The effective entry for the command named NAME, with provenance, or #f.
(def (command-entry (name : :symbol)) => (Maybe entry)
  (Keys-command-entry (current-keys) name))

;; The effective command named NAME, or #f.
(def (command-ref (name : :symbol)) => (Maybe command)
  (let (best (command-entry name))
    (and best (entry-value best))))

(def (keymap-set! (ctx : context) (keys : :string) (command : :symbol) (source :? :string)) => :void
  (Keys-keymap-set! (current-keys) ctx keys command source))

;; (keymap-set ctx "C-c l" 'command), or (keymap-set "C-c l" 'command) in a
;; plugin body, which binds through (current-context). Records the source.
(defsyntax (keymap-set stx)
  (syntax-case stx ()
    ((_ ctx keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set! ctx keys command source)))
    ((_ keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set! (current-context) keys command source)))))

(def (keymap-set-in! (ctx : context) (keymap : entry-table) (keys : :string) (command : :symbol)
                     (source :? :string))
  => :void
  (Keys-keymap-set-in! (current-keys) ctx keymap keys command source))

;; (keymap-set-in ctx keymap "RET" 'command), or without CTX in a plugin
;; body. Records the source.
(defsyntax (keymap-set-in stx)
  (syntax-case stx ()
    ((_ ctx keymap keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set-in! ctx keymap keys command source)))
    ((_ keymap keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set-in! (current-context) keymap keys command source)))))

(def (push-input-target! (target : input-target)) => :void
  (Keys-push-input-target! (current-keys) target))

(def (remove-input-target! (target : input-target)) => :void
  (Keys-remove-input-target! (current-keys) target))

(def (key-binding (keys : :string)) => :t
  (Keys-key-binding (current-keys) keys))

(def (last-command) => (Maybe :symbol)
  (Keys-last-command (current-keys)))

;; A key-event, a pointer-event, or #f.
(def (last-command-event) => :t
  (Keys-last-command-event (current-keys)))

;; The keys of a plain click (mouse-1, mouse-2 or mouse-3) on a part of
;; kind AREA: under AREA as a prefix key ("<view> <mouse-1>"), and also
;; without it when ALONE?.
(def (plain-click-keys (area : :symbol) (alone? : :boolean)) => :list
  (let (prefix (string-append "<" (symbol->string area) "> "))
    (foldr (lambda ((button : :string) (out : :list))
             (let (click (string-append "<mouse-" button ">"))
               (cons (string-append prefix click) (if alone? (cons click out) out))))
           []
           ["1" "2" "3"])))

;; Whether a plain click on a part of kind AREA has a global binding with
;; AREA as its prefix key ("<tab-line> <mouse-1>"), so renderers mark such
;; parts clickable; #f without key bindings. The unprefixed global
;; fallbacks do not count: they would make every part clickable.
(def (part-clickable? (area : :symbol)) => :boolean
  (let (input (service-provider input-service))
    (and input (is-Keys? input)
         (ormap (lambda ((keys : :string)) (Keys-key-binding (Keys input) keys))
                (plain-click-keys area #f))
         #t)))

;; Whether KEYMAP, a node's own, binds a plain click on a part of kind
;; AREA, with or without AREA as a prefix key ("<mouse-1>", "<view>
;; <mouse-1>"), so renderers mark the node clickable.
(def (keymap-clickable? (keymap : entry-table) (area : :symbol)) => :boolean
  (and (ormap (cut entry-table-ref keymap <>) (plain-click-keys area #t)) #t))

;; The current keymap generation, or 0 without key bindings.
(def (keymap-generation) => :fixnum
  (let (input (service-provider input-service))
    (if (and input (is-Keys? input))
      (Keys-keymap-generation (Keys input))
      0)))
