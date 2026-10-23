;;; Key bindings: the key and pointer events a transport
;;; submits as input items, the part of the input service that plugins
;;; bind keys through, and the input-target stack
;;; (ADR 3, ADR 8). Plugins that bind keys require `input-service`;
;;; command definitions require the separate commands service.
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
;;; contract finds the view, node and position a posn names (`posn-view`,
;;; `posn-node`, `posn-point`).
;;;
;;; A key with shift (`S-<right>`, or an upper-case letter with or
;;; without other modifiers, `C-F`) that ends a sequence with no binding
;;; is looked up again without it (`<right>`, `C-f`), as Emacs's shift
;;; translation does; the command it finds can tell
;;; (`this-command-keys-shift-translated?`), which is how shifted motion
;;; keys select text.
;;;
;;; A scroll report (`scroll-event`) is what the browser measured of a
;;; view's scroller. It is looked up like a click, under `scroll-key`
;;; ("<scroll>"), in the keymaps from the node the scroller draws from up,
;;; then the innermost input target's and the global keymap, so the
;;; command that handles it can be rebound or advised. It neither ends nor
;;; joins a pending key sequence, and an unbound one is ignored quietly. A
;;; scroll report is a special event (Emacs's special-event-map): not something
;;; the user did, so its binding runs as a special command (the commands
;;; contract's `call-special-command`), never becoming this-command or
;;; last-command and running no command hooks.
;;;
;;; Sources (ADR 17): each keymap bound through this contract has one,
;;; which changes when a binding is added to it or goes, and one more
;;; source changes with the global keymap's bindings and with its
;;; provider. `keymap-clickable?` and `part-clickable?` record reads of
;;; them, so a rebind draws again only what was drawn from that keymap.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/lib/memo
        (only-in :tuna/plugins/buffers/contract node)
        ;; Events have a field named client, which would shadow the type
        ;; of that name in their constructors.
        (rename-in (only-in :tuna/plugins/clients/contract client) (client client-type)))
(export context-set-click-resolver!
        where-is
        (struct-out key-event posn pointer-event scroll-event)
        pointer-event-names
        scroll-key
        event-start
        part-clickable?
        keymap-clickable?
        keymap-changed!
        global-bindings-changed!
        report-stale-click
        (interface-out Keys)
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
        last-command-event
        this-command-keys-shift-translated?)

;; One keydown from CLIENT (#f for none), with its page-load sequence
;; number (ADR 7, ADR 10, ADR 16). The web transport submits it as an input
;; item; the input service resolves it. MAC?, ALT-LEFT?, ALT-RIGHT? and
;; ALT-GRAPH? are browser facts; the input plugin decides their meaning.
(defstruct key-event ((sequence   : :fixnum)
                      (client     :? client-type)
                      (key        : :string)
                      (code       : :string)
                      (location   : :fixnum)
                      (repeat?    : :boolean)
                      (composing? : :boolean)
                      (alt?       : :boolean)
                      (ctrl?      : :boolean)
                      (meta?      : :boolean)
                      (shift?     : :boolean)
                      (mac?       : :boolean)
                      (alt-left?  : :boolean)
                      (alt-right? : :boolean)
                      (alt-graph? : :boolean))
  final: #t)

;; Where a click happened (Emacs's position, `posn`): on the part of the
;; screen with kind AREA (tab-line, view, status-line; Emacs's `posn-area`) and
;; id PART, over the node with id NODE-ID if any, on the screen with
;; revision REVISION. Parts are named by stable id, never by position: a
;; view or its status line by the view's id, a tab of a tab line by the id
;; of the part it shows. A click in a line of text also names the line,
;; by its item token LINE (the buffers contract's `item-token`), the
;; character revision LINE-REVISION of its text when the screen was drawn,
;; and the COLUMN, in characters from the line's start, of the gap
;; between characters nearest the click; LINE is #f for any other click,
;; and the other two are 0. The layout contract's `posn-point` turns them
;; into a position now.
(defstruct posn ((area          : :symbol)
                 (part          : :fixnum)
                 (node-id       :? :fixnum)
                 (revision      : :fixnum)
                 (line          :? :string)
                 (line-revision : :fixnum)
                 (column        : :fixnum))
  final: #t)

;; One click from CLIENT (#f for none), with its page-load sequence number
;; (ADR 7, ADR 10, ADR 16): BUTTON 1, 2 or 3 (left, middle, right, numbered
;; as Emacs does), released after CLICKS presses in a row, at START.
(defstruct pointer-event ((sequence : :fixnum)
                          (client   :? client-type)
                          (button   : :fixnum)
                          (clicks   : :fixnum)
                          (alt?     : :boolean)
                          (ctrl?    : :boolean)
                          (meta?    : :boolean)
                          (shift?   : :boolean)
                          (start    : posn))
  final: #t)

;; What CLIENT's browser (#f for none) measured of a view's scroller, with
;; its page-load sequence number (ADR 7, ADR 10, ADR 16). START names the view (its part), the
;; node the scroller draws from (its node) and the screen measured. Items
;; are named by their tokens (the buffers contract's `item-token`); every
;; pixel quantity is measured. TOP-ITEM is the item at the top edge, with
;; TOP-OFFSET px of it above the edge, and LAST-VISIBLE-ITEM the last item
;; wholly in view, or TOP-ITEM when none is (#f when no item is there).
;; When the top edge is in a spacer standing in for items not drawn
;; (SPACER 'above or 'below the drawn items; #f otherwise), TOP-ITEM is
;; the drawn item next to that spacer, the first drawn or the last, and
;; SPACER-DISTANCE the px from it to the top edge: up from the first drawn
;; item's top, or down from the last drawn item's bottom; LAST-VISIBLE-ITEM
;; is then #f unless an item is wholly in view. DRAWN-BEFORE and
;; DRAWN-AFTER count the items drawn before and after TOP-ITEM, DRAWN-HEIGHT
;; is the px from the top of the first of them to the bottom of the last,
;; and PX-ABOVE and PX-BELOW are the px of them beyond the view's top and
;; bottom edges; PLACEMENT is the number of the last placement the page
;; applied to the view. SETTLED? is whether scrolling had come to rest
;; when the page measured, rather than being on its way.
(defstruct scroll-event ((sequence          : :fixnum)
                         (client            :? client-type)
                         (start             : posn)
                         (placement         : :fixnum)
                         (top-item          :? :string)
                         (top-offset        : :flonum)
                         (last-visible-item :? :string)
                         (spacer            :? :symbol)
                         (spacer-distance   : :flonum)
                         (drawn-before      : :fixnum)
                         (drawn-after       : :fixnum)
                         (drawn-height      : :flonum)
                         (px-above          : :flonum)
                         (px-below          : :flonum)
                         (viewport-width    : :fixnum)
                         (viewport-height   : :fixnum)
                         (settled?          : :boolean))
  final: #t)

;; The key scroll events are looked up under.
(def scroll-key "<scroll>")

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

;; Where EVENT happened: a pointer or scroll event's posn, or
;; #f for a key event, which has no position (Emacs gives point in the
;; selected window).
(def (event-start (event : :t)) => (Maybe posn)
  (cond
   ((pointer-event? event) (pointer-event-start event))
   ((scroll-event? event) (scroll-event-start event))
   (else #f)))

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
  ;; RESOLVE receives a posn and returns the starting node, or #f.
  (set-click-resolver! (ctx : context) (resolve : :procedure)) => :void
  ;; Reverse lookup in the maps active from FOCUS (#f: current focus), shortest first.
  (where-is (name : :symbol) (focus :? node)) => :list
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
  ;; The key, pointer or scroll event that completed the running
  ;; command's keys, or #f (Emacs `last-command-event`).
  (last-command-event) => :t
  ;; Whether the running command's keys were found only once shift was
  ;; taken off their last key (Emacs `this-command-keys-shift-translated`).
  (this-command-keys-shift-translated?) => :boolean)

(def (context-set-click-resolver! (ctx : context) (resolve : :procedure)) => :void
  (:- (with-service-provider (provider input-service Keys)
        (Keys-set-click-resolver! provider ctx resolve)) :void))

(def (where-is (name : :symbol) (focus :? node := #f)) => :list
  (:- (with-service-provider (provider input-service Keys) (Keys-where-is provider name focus)) :list))

(def (keymap-set! (ctx : context) (keys : :string) (command : :symbol) (source :? :string)) => :void
  (:- (with-service-provider (provider input-service Keys) (Keys-keymap-set! provider ctx keys command source)) :void))

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
  (:- (with-service-provider (provider input-service Keys) (Keys-keymap-set-in! provider ctx keymap keys command source)) :void))

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
  (:- (with-service-provider (provider input-service Keys) (Keys-push-input-target! provider target)) :void))

(def (remove-input-target! (target : input-target)) => :void
  (:- (with-service-provider (provider input-service Keys) (Keys-remove-input-target! provider target)) :void))

(def (key-binding (keys : :string)) => :t
  (with-service-provider (provider input-service Keys) (Keys-key-binding provider keys)))

;; A key-event, a pointer-event, a scroll-event, or #f.
(def (last-command-event) => :t
  (with-service-provider (provider input-service Keys) (Keys-last-command-event provider)))

(def (this-command-keys-shift-translated?) => :boolean
  (:- (with-service-provider (provider input-service Keys) (Keys-this-command-keys-shift-translated? provider))
      :boolean))

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

;;; Sources

;; Keymap -> its source, for the keymaps bindings were made in. A source
;; does not refer to its keymap, so a keymap no one keeps is collected.
(def keymap-sources (make-hash-table test: eq? weak-keys: #t))

;; Changes when a keymap is first bound: until then a read of a keymap
;; records this.
(def unbound-keymaps-source (new-source))

;; Changes with the global keymap's bindings, and with its provider.
(def global-bindings-source (new-source))

;; For providers: a binding was added to KEYMAP or removed from it.
(def (keymap-changed! (keymap : entry-table)) => :void
  (let (s (hash-get keymap-sources keymap))
    (if s
      (source-changed! s)
      (begin
        (hash-put! keymap-sources keymap (new-source))
        (source-changed! unbound-keymaps-source)))))

;; For providers: the global keymap's bindings changed, or its provider
;; started or stopped.
(def (global-bindings-changed!) => :void
  (source-changed! global-bindings-source))

(def (record-keymap-read! (keymap : entry-table)) => :void
  (record-read! (or (hash-get keymap-sources keymap) unbound-keymaps-source)))

;; Whether a plain click on a part of kind AREA has a global binding with
;; AREA as its prefix key ("<tab-line> <mouse-1>"), so renderers mark such
;; parts clickable; #f without key bindings. The unprefixed global
;; fallbacks do not count: they would make every part clickable.
(def (part-clickable? (area : :symbol)) => :boolean
  (record-read! global-bindings-source)
  (:- (let (input (service-provider input-service))
          (and input (is-Keys? input)
               (ormap (lambda ((keys : :string)) (Keys-key-binding (Keys input) keys))
                      (plain-click-keys area #f))
               #t)) :boolean))

;; Whether KEYMAP, a node's own, binds a plain click on a part of kind
;; AREA, with or without AREA as a prefix key ("<mouse-1>", "<view>
;; <mouse-1>"), so renderers mark the node clickable.
(def (keymap-clickable? (keymap : entry-table) (area : :symbol)) => :boolean
  (record-keymap-read! keymap)
  (and (ormap (cut entry-table-ref keymap <>) (plain-click-keys area #t)) #t))
