#lang :tuna/prelude
;;; Key handling (startup tier): the global keymap, the
;;; input-target stack, key resolution, and the quit key (ADR 3, ADR 8).
;;;
;;; Keys resolve in the keymaps of the focused node and the nodes above it
;;; (when a buffers provider is running), then the innermost input
;;; target's, then the global keymap (the keys contract lists the order). So do clicks, starting at the node clicked (when a layout is
;;; running): in each keymap under the part kind as a prefix key, then
;;; without it, each from the most specific event name down
;;; (`pointer-event-names`), before the next keymap. A click does not clear
;;; the echo area, so clicking it to read a message keeps the message. A
;;; press with no binding is dropped quietly, keeping a pending prefix, as
;;; Emacs drops unbound down events. A pointer movement while a button is
;;; held is looked up like a click, but is a special event, as a scroll
;;; report is: it changes no key state and is ignored quietly when unbound.
;;; Scroll reports resolve under their key ("<scroll>") from the node
;;; their view's scroller draws from, leaving a pending prefix, the echo
;;; area and the last command event as they were. A scroll report is a
;;; special event (Emacs's special-event-map): the browser telling the
;;; server what it measured, not something the user did, so its binding
;;; runs outside the command loop's bookkeeping (call-special-command): it
;;; becomes neither this-command nor last-command and runs no command
;;; hooks.
;;;
;;; A paste resolves like a key, under its key ("<paste>").
;;;
;;; A sequence with no binding whose last key has shift is looked up again
;;; without it (Emacs's shift translation; `unshifted-key`), and its
;;; command runs knowing so (`this-command-keys-shift-translated?`).
;;;
;;; Keys in progress are per client (ADR 16; Emacs's kboard): each client's
;;; pending prefix and the event that completed its last sequence, so a
;;; prefix typed in one browser tab never joins keys from another. Events
;;; with no client share one session. Each command's task sees its client
;;; as `current-client`.
;;;
;;; `C-g` with nothing running runs `keyboard-quit`, which also quits a
;;; command waiting in `off-thread` or `sleep-for` (tuna/lib/background):
;;; the most recent wait of a command this client started, otherwise of
;;; any client's, unless the `C-g` cancelled a pending prefix. A task that
;;; is not a command, such as a timer's, is never quit this way.

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        (only-in :tuna/lib/background background-waiting-tasks quit-background-wait!)
        :tuna/plugins/clients/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/settings/contract
        (only-in :tuna/plugins/buffers/contract
                 buffers-service selected-view view-node view-showing buffer-root
                 node node-parent node-keymap))
(export keys
        key-description
        mac-option-modifier
        mac-right-option-modifier)

(def quit-key "C-g")

;; One client's keys in progress.
(defclass key-session ((pending       : :list)          ; keys typed so far of a prefix
                       (command-event :? :t))           ; key-event, pointer-event or paste-event
  final: #t)

(defclass global-keys ((click-resolvers : entry-table)
                       (keymap        : entry-table)    ; key sequence -> command name
                       (targets       : :list)          ; input targets, innermost first
                       (sessions      : HashTable)      ; client -> key-session
                       (shared        : key-session)    ; the session of events with no client
                       (command-clients : HashTable))   ; running command's task id -> (box client)
  final: #t)

;; Browser key names with Emacs spellings.
(def named-keys
  (list->hash-table
   '((" " . "SPC") ("Enter" . "RET") ("Tab" . "TAB") ("Escape" . "ESC")
     ("Backspace" . "DEL") ("Delete" . "<delete>") ("Insert" . "<insert>")
     ("ArrowLeft" . "<left>") ("ArrowRight" . "<right>")
     ("ArrowUp" . "<up>") ("ArrowDown" . "<down>")
     ("Home" . "<home>") ("End" . "<end>")
     ("PageUp" . "<prior>") ("PageDown" . "<next>"))))

;; Keys that only modify or compose other keys.
(def ignored-keys
  '("" "Shift" "Control" "Alt" "AltGraph" "Meta" "Super" "Hyper" "OS"
    "CapsLock" "NumLock" "ScrollLock" "Fn" "FnLock" "Symbol" "SymbolLock"
    "Dead" "Process" "Compose" "Unidentified"))

;; Mac Option policy is resolved for each event, so live settings take
;; effect without replacing the input plugin. Without a settings provider,
;; the keys plugin can still run with the declared defaults.
(defsetting mac-option-modifier 'meta
  "Left macOS Option: meta uses the physical US key; none types the browser character.")
(defsetting mac-right-option-modifier 'none
  "Right macOS Option: meta uses the physical US key; none types the browser character.")

(def (optional-provider? (svc : service)) => :boolean
  (and (service-provider svc) #t))

(def (option-meta? (s : setting)) => :boolean
  (case (if (optional-provider? settings-service) (setting-value s) (setting-default s))
    ((meta) #t)
    ((none) #f)
    (else (error "Option modifier must be meta or none" (setting-name s)))))

;; If both Options are held, either configured Meta wins. If the browser
;; missed the modifier press (no side), use the left Option setting.
(def (alt-meta? (event : key-event)) => :boolean
  (and (key-event-alt? event)
       (not (key-event-alt-graph? event))
       (or (not (key-event-mac? event))
           (and (or (key-event-alt-left? event) (not (key-event-alt-right? event)))
                (option-meta? mac-option-modifier))
           (and (key-event-alt-right? event) (option-meta? mac-right-option-modifier)))))

;; Physical positions on a US keyboard: unshifted, then shifted.
(def option-punctuation
  (list->hash-table
   '(("Backquote" . "`~") ("Minus" . "-_") ("Equal" . "=+")
     ("BracketLeft" . "[{") ("BracketRight" . "]}") ("Backslash" . "\\|")
     ("Semicolon" . ";:") ("Quote" . "'\"") ("Comma" . ",<")
     ("Period" . ".>") ("Slash" . "/?"))))

;; A Mac Meta key's physical US character, or the browser key for named
;; keys and codes we cannot map. No physical translation while composing.
(def (option-key (event : key-event)) => :string
  (let ((code (key-event-code event))
        (shift? (key-event-shift? event)))
    (cond
     ((and (fx= (string-length code) 4) (string-prefix? "Key" code)
           (char<=? #\A (string-ref code 3) #\Z))
      (let (letter (string-ref code 3))
        (string (if shift? letter (char-downcase letter)))))
     ((and (fx= (string-length code) 6) (string-prefix? "Digit" code)
           (char<=? #\0 (string-ref code 5) #\9))
      (let (digit (string-ref code 5))
        (string (if shift? (string-ref ")!@#$%^&*(" (fx- (char->integer digit) 48)) digit))))
     ((hash-get option-punctuation code)
      => (lambda ((pair : :string)) (string (string-ref pair (if shift? 1 0)))))
     (else (key-event-key event)))))

;; EVENT in Emacs key syntax ("C-c", "M-x", "<left>"), or #f for a key that
;; only modifies or composes others.
(def (key-description (event : key-event)) => (Maybe :string)
  (and (not (key-event-composing? event))
       ;; Only Dead may become a physical Meta key; IME Process and the
       ;; other ignored keys must stay ignored even if they have a code.
       (or (equal? (key-event-key event) "Dead")
           (not (member (key-event-key event) ignored-keys)))
       (let* ((alt? (alt-meta? event))
              (key (if (and alt? (key-event-mac? event)) (option-key event) (key-event-key event))))
         (and (not (member key ignored-keys))
              (let* ((character? (fx= (string-length key) 1))
                     (base (cond
                            ((hash-get named-keys key))
                            (character? key)
                            (else (string-append "<" (string-downcase key) ">")))))
                (string-append (if (and (key-event-ctrl? event) (not (key-event-alt-graph? event))) "C-" "")
                               (if alt? "M-" "")
                               (if (and (key-event-shift? event) (not character?)) "S-" "")
                               (if (key-event-meta? event) "s-" "")
                               base))))))

;; "C-c  l" -> "C-c l".
(def (normalize-keys (keys : :string)) => :string
  (let (parts (filter (lambda ((part : :string)) (not (string-empty? part)))
                      (string-split keys #\space)))
    (when (null? parts)
      (error "Empty key sequence" keys))
    (string-join parts " ")))

;; The keymaps of N and of each node above it, innermost first.
(def (node-keymaps (n :? node)) => :list
  (let up ((n n) (out []))
    (if n
      (up (node-parent n) (let (keymap (node-keymap n)) (if keymap (cons keymap out) out)))
      (reverse out))))

;; The node keys start from: the selected view's focused text node, or the
;; root of its buffer when it has none; #f without buffers.
(def (focused-node) => (Maybe node)
  (and (optional-provider? buffers-service)
       (let (v (selected-view))
         (or (view-node v) (buffer-root (view-showing v))))))

;; The node a click at P starts from: the node clicked, or the root of the
;; clicked view's buffer; #f without a layout or a view.
(def (clicked-node (self : global-keys) (p : posn)) => (Maybe node)
  (let (resolver (entry-table-ref self.click-resolvers 'click))
    (and resolver (:? ((entry-value resolver) p) node))))

;; The keymaps a key or click resolves in, first to last: those of the
;; nodes from START up, the innermost input target's, and the global
;; keymap.
(def (active-keymaps (self : global-keys) (start :? node)) => :list
  (append (node-keymaps start)
          (match self.targets
            ([innermost . _] [(input-target-keymap innermost)])
            ([] []))
          [self.keymap]))

(def (prefix-in? (keymap : entry-table) (keys : :string)) => :boolean
  (let (prefix (string-append keys " "))
    (ormap (lambda ((bound : :string)) (string-prefix? prefix bound))
           (entry-table-names keymap))))

;; What KEYS means in KEYMAPS: the binding of the first keymap that binds
;; KEYS (or, failing that, FALLBACK, such as <printing-char>), 'prefix when
;; that keymap first binds a longer sequence starting with KEYS, or #f.
(def (find-binding (keymaps : :list) (keys : :string) (fallback :? :string)) => :t
  (let lp ((rest keymaps))
    (match rest
      ([] #f)
      ([keymap . more]
       (cond
        ((entry-table-ref keymap keys))
        ((prefix-in? keymap keys) 'prefix)
        ((and fallback (entry-table-ref keymap fallback)))
        (else (lp more)))))))

(def (printing-char? (key : :string)) => :boolean
  (and (fx= (string-length key) 1)
       (char>? (string-ref key 0) #\space)
       (not (char=? (string-ref key 0) #\delete))))

;; This form's source location, as "path:line".
(defsyntax (this-source stx)
  (with-syntax ((source (stx-source-string stx))) #'source))

;; The client EVENT, a key, pointer, scroll or paste event, came from, or #f.
(def (event-client (event : :t)) => (Maybe client)
  (cond
   ((key-event? event) (key-event-client event))
   ((pointer-event? event) (pointer-event-client event))
   ((scroll-event? event) (scroll-event-client event))
   ((paste-event? event) (paste-event-client event))
   (else #f)))

;; The keys in progress of CLIENT (#f for none), made when first needed.
(def (client-session (self : global-keys) (c :? client)) => key-session
  (if c
    (or (hash-get self.sessions c)
        (let (session (key-session pending: [] command-event: #f))
          (hash-put! self.sessions c session)
          session))
    self.shared))

;; Capture the event and its client in the resolved task, so another
;; command at a prompt cannot overwrite the suspended command's event.
(def activation-event (make-parameter #f))

;; Whether the quit key that started this task cancelled a pending prefix.
(def quit-cancelled-prefix? (make-parameter #f))

;; Whether this task's command was found by shift translation.
(def activation-shift-translated? (make-parameter #f))

;; The command NAME as the task EVENT starts. While it runs, SELF knows
;; its client, so the quit key can find the commands a client started.
(def (command-task (self : global-keys) (event : :t) (name : :symbol)
                   cancelled-prefix?: (cancelled-prefix? : :boolean := #f)
                   shift-translated?: (shift-translated? : :boolean := #f))
  => (Maybe :pair)
  (and (command-entry name)
       (cons name (lambda ()
                    (let ((client (event-client event))
                          (id (current-task-id)))
                      (parameterize ((activation-event event)
                                     (current-client client)
                                     (quit-cancelled-prefix? cancelled-prefix?)
                                     (activation-shift-translated? shift-translated?))
                        (hash-put! self.command-clients id (box client))
                        (unwind-protect
                          (call-command name)
                          (hash-remove! self.command-clients id))))))))

;; A key sequence of SESSION ended with EVENT, a key, pointer or paste event, and
;; selected the command named NAME, or #f for none.
(def (complete-keys! (session : key-session) (event : :t) (name :? :symbol)) => :void
  (set! session.pending [])
  (set! session.command-event event))

;; EVENT, a key or paste event, typed as KEY: its key-description, #f for
;; a key that only modifies or composes others, or paste-key.
(def (resolve-key! (self : global-keys) (event : :t) (key :? :string)) => (Maybe :pair)
  (let ((keymaps (active-keymaps self (focused-node)))
        (session (client-session self (event-client event))))
    (cond
     ((not key) #f)
     ((equal? key quit-key)
      ;; The quit key cancels a pending prefix; a keymap may bind it, as the
      ;; minibuffer's prompts do.
      (let* ((found (find-binding keymaps quit-key #f))
             (name (if (and found (not (eq? found 'prefix))) (entry-value found) 'keyboard-quit))
             (pending? (pair? (key-session-pending session))))
        (complete-keys! session event name)
        (command-task self event name cancelled-prefix?: pending?)))
     (else
      (message "")
      (let* ((typed (append (key-session-pending session) [key]))
             (keys (string-join typed " "))
             (found (find-binding keymaps keys
                                  (and (null? (key-session-pending session)) (printing-char? key)
                                       printing-char-key))))
        (cond
         ((eq? found 'prefix)
          (set! (key-session-pending session) typed)
          (message (string-append keys "-"))
          #f)
         (found
          (let (name (entry-value found))
            (complete-keys! session event name)
            (bound-command-task self event keys name)))
         ((let (unshifted (unshifted-key key))
            (and unshifted
                 (let* ((typed (append (key-session-pending session) [unshifted]))
                        (keys (string-join typed " ")))
                   (cons typed (find-binding keymaps keys #f)))))
          => (lambda ((translated : :pair))
               (let ((typed (car translated))
                     (found (cdr translated)))
                 (shift-translated! self session event typed found keys))))
         (else
          (complete-keys! session event #f)
          (message (string-append keys " is undefined"))
          #f)))))))

;; KEY, the last of a sequence with no binding, without shift (Emacs's
;; shift translation): without its S- modifier ("C-S-<right>" ->
;; "C-<right>"), or an upper-case letter in lower case ("C-F" -> "C-f");
;; #f for a key without shift.
(def (unshifted-key (key : :string)) => (Maybe :string)
  (let lp ((rest key) (modifiers ""))
    (cond
     ((and (fx> (string-length rest) 2) (char=? (string-ref rest 1) #\-)
           (memv (string-ref rest 0) '(#\C #\M #\S #\s)))
      (if (char=? (string-ref rest 0) #\S)
        (string-append modifiers (substring rest 2 (string-length rest)))
        (lp (substring rest 2 (string-length rest)) (string-append modifiers (substring rest 0 2)))))
     ((and (fx= (string-length rest) 1) (char-upper-case? (string-ref rest 0))
           (not (char=? (char-downcase (string-ref rest 0)) (string-ref rest 0))))
      (string-append modifiers (string (char-downcase (string-ref rest 0)))))
     (else #f))))

;; The keys TYPED, the sequence ORIGINAL with shift taken off its last
;; key, found FOUND (find-binding) for SESSION's EVENT: a command, which
;; runs knowing it was shift-translated; a prefix, which waits for more;
;; or nothing, and ORIGINAL is undefined.
(def (shift-translated! (self : global-keys) (session : key-session) (event : :t) (typed : :list)
                        (found : :t) (original : :string))
  => (Maybe :pair)
  (cond
   ((eq? found 'prefix)
    (set! (key-session-pending session) typed)
    (message (string-append (string-join typed " ") "-"))
    #f)
   (found
    (let (name (entry-value found))
      (complete-keys! session event name)
      (or (command-task self event name shift-translated?: #t)
          (begin
            (message (string-append (string-join typed " ") " runs " (symbol->string name) ", which is not defined"))
            #f))))
   (else
    (complete-keys! session event #f)
    (message (string-append original " is undefined"))
    #f)))

;; The command NAME of a sequence KEYS that EVENT completed, as a task, or
;; #f with a message when no command has that name.
(def (bound-command-task (self : global-keys) (event : :t) (keys : :string) (name : :symbol))
  => (Maybe :pair)
  (or (command-task self event name)
      (begin
        (message (string-append keys " runs " (symbol->string name) ", which is not defined"))
        #f)))

;; The binding of EVENT after the keys PENDING, as (keys . command name),
;; or #f: looked up under PENDING, the part kind, and each of its event
;; names ("C-x <tab-line> <double-mouse-1>", "C-x <tab-line> <mouse-1>"),
;; then the same without the part kind, all of them in one keymap before
;; the next. The first sequence tried comes with #f for none found.
(def (pointer-binding (self : global-keys) (event : pointer-event) (pending : :list)) => :pair
  (let* ((start (pointer-event-start event))
         (keymaps (active-keymaps self (clicked-node self start)))
         (area (string-append "<" (symbol->string (posn-area start)) ">"))
         (names (map (lambda ((name : :string)) (string-append "<" name ">"))
                     (pointer-event-names event)))
         (sequences (map (lambda ((tail : :list)) (string-join (append pending tail) " "))
                         (append (map (lambda (name) [area name]) names)
                                 (map (lambda (name) [name]) names)))))
    (or (ormap (lambda ((keymap : entry-table))
                 (ormap (lambda ((keys : :string))
                          (let (binding (entry-table-ref keymap keys))
                            (and binding (cons keys (entry-value binding)))))
                        sequences))
               keymaps)
        (cons (car sequences) #f))))

;; A click or a drag ends any pending prefix; a press does when it is
;; bound, and is otherwise dropped quietly; a movement is a special event
;; (resolve-movement!).
(def (resolve-pointer! (self : global-keys) (event : pointer-event)) => (Maybe :pair)
  (if (eq? (pointer-event-kind event) 'movement)
    (resolve-movement! self event)
    (let* ((session (client-session self (pointer-event-client event)))
           (found (pointer-binding self event (key-session-pending session))))
      (cond
       ((cdr found)
        (complete-keys! session event (cdr found))
        (bound-command-task self event (car found) (cdr found)))
       ((eq? (pointer-event-kind event) 'down) #f)
       (else
        (complete-keys! session event #f)
        (message (string-append (car found) " is undefined"))
        #f)))))

;; A pointer movement while a button is held, EVENT, as a special event:
;; looked up like a click with no pending prefix, changing no key state,
;; and ignored quietly when unbound.
(def (resolve-movement! (self : global-keys) (event : pointer-event)) => (Maybe :pair)
  (let (name (cdr (pointer-binding self event [])))
    (and name (command-entry name)
         (cons name (lambda ()
                      (parameterize ((activation-event event)
                                     (current-client (pointer-event-client event)))
                        (call-special-command name)))))))

;; A scroll report, EVENT, looked up under scroll-key. Reports arrive
;; whenever the browser needs a redraw, between the keys of a sequence
;; too, so they change no key state; a report is a special event, and its
;; binding runs as one (call-special-command).
(def (resolve-scroll! (self : global-keys) (event : scroll-event)) => (Maybe :pair)
  (let (found (find-binding (active-keymaps self (clicked-node self (scroll-event-start event))) scroll-key #f))
    (and found (not (eq? found 'prefix))
         (let (name (entry-value found))
           (and (command-entry name)
                (cons name (lambda ()
                             (parameterize ((activation-event event)
                                            (current-client (scroll-event-client event)))
                               (call-special-command name)))))))))

(defmethod {resolve! global-keys}
  (lambda (self event)
    (cond
     ((pointer-event? event) (resolve-pointer! self event))
     ((scroll-event? event) (resolve-scroll! self event))
     ((paste-event? event) (resolve-key! self event paste-key))
     (else (resolve-key! self event (key-description event))))))

;; Quit (Emacs `keyboard-quit`). Unless the quit key that ran this
;; cancelled a pending prefix, first quit one command waiting in
;; off-thread or sleep-for: the most recent wait of a command started from
;; this client, otherwise the most recent of any client's command.
(def (keyboard-quit! (self : global-keys)) => :void
  (unless (quit-cancelled-prefix?)
    (let* ((clients self.command-clients)
           (c (current-client))
           (waiting (filter (cut hash-key? clients <>) (background-waiting-tasks)))
           (target (or (find (lambda (id) (eq? (unbox (hash-ref clients id)) c)) waiting)
                       (and (pair? waiting) (car waiting)))))
      (when target
        (quit-background-wait! target))))
  (signal-quit))

;; The quit key interrupts; every other key, pointer or scroll event is
;; queued.
(defmethod {arrival global-keys}
  (lambda (self event)
    ;; Alt can never produce the quit key. In particular, Mac Option
    ;; policy reads settings, which arrival must not consult off the baton.
    (if (and (key-event? event) (not (key-event-alt? event))
             (equal? (key-description event) quit-key))
      'interrupt 'queue)))

;; A sequence is effective only if every preceding prefix resolves in the
;; same active stack. This excludes shadowed exact bindings and prefixes.
(def (effective-sequence? (maps : :list) (keys : :string) (name : :symbol)) => :boolean
  (let lp ((parts (string-split keys #\space)) (prefix ""))
    (match parts
      ([part . more]
       (let* ((sequence (if (string-empty? prefix) part (string-append prefix " " part)))
              (found (find-binding maps sequence #f)))
         (if (null? more)
           (and found (not (eq? found 'prefix)) (eq? (entry-value found) name))
           (and (eq? found 'prefix) (lp more sequence)))))
      ([] #f))))

(defmethod {where-is global-keys}
  (lambda (self name focus)
    (let* ((maps (active-keymaps self (or focus (focused-node))))
           (names (hash-keys (list->hash-table
                             (map (lambda (keys) (cons keys #t))
                                  (foldr append [] (map entry-table-names maps))))))
           (bound (filter (lambda (keys) (effective-sequence? maps keys name)) names)))
      (list-sort (lambda ((a : :string) (b : :string))
                    (let ((na (length (string-split a #\space)))
                          (nb (length (string-split b #\space))))
                      (or (fx< na nb)
                          (and (fx= na nb)
                               (or (fx< (string-length a) (string-length b))
                                   (and (fx= (string-length a) (string-length b))
                                        (string<? a b)))))))
                 bound))))

;; Bind KEYS to COMMAND in KEYMAP for CTX's plugin. KEYMAP's source, and
;; for the global keymap the global bindings' source, change now and again
;; once the binding is gone: the deferred change is registered first, so
;; it runs after the entry's removal.
(def (bind! (self : global-keys) (ctx : context) (keymap : entry-table) (keys : :string)
            (command : :symbol) (source :? :string))
  => :void
  (let ((normal (normalize-keys keys))
        (changed! (lambda ()
                    (keymap-changed! keymap)
                    (when (eq? keymap self.keymap)
                      (global-bindings-changed!)))))
    (context-defer! ctx changed!)
    (context-add-entry! ctx keymap normal command source: source)
    (changed!)))

(defmethod {keymap-set! global-keys}
  (lambda (self ctx keys command source)
    (using (self : global-keys)
      (bind! self ctx self.keymap keys command source))))

(defmethod {keymap-set-in! global-keys}
  (lambda (self ctx keymap keys command source)
    (bind! self ctx keymap keys command source)))

(defmethod {push-input-target! global-keys}
  (lambda (self target)
    (using (self : global-keys)
      (set! self.targets (cons target self.targets)))))

(defmethod {remove-input-target! global-keys}
  (lambda (self target)
    (using (self : global-keys)
      (set! self.targets (remq target self.targets)))))

(defmethod {key-binding global-keys}
  (lambda (self keys)
    (using (self : global-keys)
      (entry-table-ref self.keymap (normalize-keys keys)))))

(defmethod {last-command-event global-keys}
  (lambda (self)
    (using (self : global-keys)
      (or (activation-event)
          (let (c (current-client))
            (if c
              (let (session (hash-get self.sessions c))
                (and session (key-session-command-event session)))
              (key-session-command-event self.shared)))))))

(defmethod {this-command-keys-shift-translated? global-keys}
  (lambda (self) (activation-shift-translated?)))

(defmethod {set-click-resolver! global-keys}
  (lambda (self ctx resolve)
    (context-add-entry! ctx (global-keys-click-resolvers self) 'click resolve)
    (void)))


(defplugin (keys ctx)
  "Resolves keys through node keymaps and the global keymap. C-g quits."
  provides: [input-service]
  requires: [commands-service]
  optional: [settings-service buffers-service]
  (using (self (global-keys click-resolvers: (new-entry-table) keymap: (new-entry-table) targets: []
                            sessions: (make-hash-table-eq)
                            shared: (key-session pending: [] command-event: #f)
                            command-clients: (make-hash-table-eqv))
               : global-keys)
    (global-bindings-changed!)
    (context-defer! ctx global-bindings-changed!)
    (context-add-hook! ctx client-gone-hook 'keys
                       (lambda ((c : client)) (hash-remove! self.sessions c)))
    (context-define-command! ctx 'keyboard-quit (lambda () (keyboard-quit! self))
                             doc: "Cancel the current key sequence, or quit the command waiting in the background that was started last from here."
                             source: (this-source))
    (context-provide! ctx input-service (Keys self))))
