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
;;; the echo area, so clicking it to read a message keeps the message.
;;; Scroll reports and scroll bar events resolve under their keys
;;; ("<scroll>", "<vertical-scroll-bar> <drag-mouse-1>") from the node
;;; their view's scroller draws from, leaving a pending prefix, the echo
;;; area and the last command event as they were. A scroll report is a
;;; special event (Emacs's special-event-map): the browser telling the
;;; server what it measured, not something the user did, so its binding
;;; runs outside the command loop's bookkeeping (call-special-command): it
;;; becomes neither this-command nor last-command and runs no command
;;; hooks. Scroll bar events are the user's, ordinary commands, as in
;;; Emacs.

(import :tuna/kernel
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

(defclass global-keys ((click-resolvers : entry-table)
                       (keymap        : entry-table)    ; key sequence -> command name
                       (targets       : :list)          ; input targets, innermost first
                       (pending       : :list)          ; keys typed so far of a prefix
                       (command-event :? :t)            ; key-event or pointer-event
                       (generation    : :fixnum))       ; changes with any binding
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

;; Capture the event in the resolved task, so another command at a prompt
;; cannot overwrite the suspended command's event.
(def activation-event (make-parameter #f))

(def (command-task (self : global-keys) (name : :symbol)) => (Maybe :pair)
  (and (command-entry name)
       (let (event self.command-event)
         (cons name (lambda ()
                      (parameterize ((activation-event event))
                        (call-command name)))))))

;; A key sequence ended with EVENT, a key or pointer event, and selected
;; the command named NAME, or #f for none.
(def (complete-keys! (self : global-keys) (event : :t) (name :? :symbol)) => :void
  (set! self.pending [])
  (set! self.command-event event))

(def (resolve-key! (self : global-keys) (event : key-event)) => (Maybe :pair)
  (let ((key (key-description event))
        (keymaps (active-keymaps self (focused-node))))
    (cond
     ((not key) #f)
     ((equal? key quit-key)
      ;; The quit key cancels a pending prefix; a keymap may bind it, as the
      ;; minibuffer's prompts do.
      (let* ((found (find-binding keymaps quit-key #f))
             (name (if (and found (not (eq? found 'prefix))) (entry-value found) 'keyboard-quit)))
        (complete-keys! self event name)
        (command-task self name)))
     (else
      (message "")
      (let* ((typed (append self.pending [key]))
             (keys (string-join typed " "))
             (found (find-binding keymaps keys
                                  (and (null? self.pending) (printing-char? key)
                                       printing-char-key))))
        (cond
         ((eq? found 'prefix)
          (set! self.pending typed)
          (message (string-append keys "-"))
          #f)
         (found
          (let (name (entry-value found))
            (complete-keys! self event name)
            (bound-command-task self keys name)))
         (else
          (complete-keys! self event #f)
          (message (string-append keys " is undefined"))
          #f)))))))

;; The command NAME of a completed sequence KEYS, as a task, or #f with a
;; message when no command has that name.
(def (bound-command-task (self : global-keys) (keys : :string) (name : :symbol)) => (Maybe :pair)
  (or (command-task self name)
      (begin
        (message (string-append keys " runs " (symbol->string name) ", which is not defined"))
        #f)))

;; A click ends any pending prefix: the sequences it is looked up under
;; are that prefix, the part kind, and each of its event names ("C-x
;; <tab-line> <double-mouse-1>", "C-x <tab-line> <mouse-1>"), then the same
;; without the part kind, all of them in one keymap before the next.
(def (resolve-pointer! (self : global-keys) (event : pointer-event)) => (Maybe :pair)
  (let* ((start (pointer-event-start event))
         (keymaps (active-keymaps self (clicked-node self start)))
         (area (string-append "<" (symbol->string (posn-area start)) ">"))
         (names (map (lambda ((name : :string)) (string-append "<" name ">"))
                     (pointer-event-names event)))
         (sequences (map (lambda ((tail : :list)) (string-join (append self.pending tail) " "))
                         (append (map (lambda (name) [area name]) names)
                                 (map (lambda (name) [name]) names))))
         (found (ormap (lambda ((keymap : entry-table))
                         (ormap (lambda ((keys : :string))
                                  (let (binding (entry-table-ref keymap keys))
                                    (and binding (cons keys (entry-value binding)))))
                                sequences))
                       keymaps)))
    (if found
      (begin
        (complete-keys! self event (cdr found))
        (bound-command-task self (car found) (cdr found)))
      (begin
        (complete-keys! self event #f)
        (message (string-append (car sequences) " is undefined"))
        #f))))

;; A scroll report or scroll bar event, EVENT, at P, looked up under KEYS.
;; Reports arrive whenever the browser needs a redraw, and a scroll bar
;; drag sends many, between the keys of a sequence too, so they change no
;; key state. A special event's binding runs as one (call-special-command).
(def (resolve-scroll! (self : global-keys) (event : :t) (p : posn) (keys : :string)
                      (special? : :boolean))
  => (Maybe :pair)
  (let (found (find-binding (active-keymaps self (clicked-node self p)) keys #f))
    (and found (not (eq? found 'prefix))
         (let (name (entry-value found))
           (and (command-entry name)
                (cons name (lambda ()
                             (parameterize ((activation-event event))
                               (if special?
                                 (call-special-command name)
                                 (call-command name))))))))))

(defmethod {resolve! global-keys}
  (lambda (self event)
    (cond
     ((pointer-event? event) (resolve-pointer! self event))
     ((scroll-event? event) (resolve-scroll! self event (scroll-event-start event) scroll-key #t))
     ((scroll-bar-event? event)
      (resolve-scroll! self event (scroll-bar-event-start event) (scroll-bar-event-keys event) #f))
     (else (resolve-key! self event)))))

;; The quit key interrupts; every other key, pointer, scroll or scroll bar
;; event is queued.
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

;; Bind KEYS to COMMAND in KEYMAP for CTX's plugin. The generation changes
;; now and again once the binding is gone: the deferred change is
;; registered first, so it runs after the entry's removal.
(def (bind! (self : global-keys) (ctx : context) (keymap : entry-table) (keys : :string)
            (command : :symbol) (source :? :string))
  => :void
  (let (normal (normalize-keys keys))
    (context-defer! ctx (lambda () (set! self.generation (next-id!))))
    (context-add-entry! ctx keymap normal command source: source)
    (set! self.generation (next-id!))))

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
  (lambda (self) (or (activation-event) (global-keys-command-event self))))

(defmethod {set-click-resolver! global-keys}
  (lambda (self ctx resolve)
    (context-add-entry! ctx (global-keys-click-resolvers self) 'click resolve)
    (void)))

(defmethod {keymap-generation global-keys}
  (lambda (self) (global-keys-generation self)))

(defplugin (keys ctx)
  "Resolves keys through node keymaps and the global keymap. C-g quits."
  provides: [input-service]
  requires: [commands-service]
  optional: [settings-service buffers-service]
  (using (self (global-keys click-resolvers: (new-entry-table) keymap: (new-entry-table) targets: []
                            pending: [] command-event: #f
                            generation: (next-id!))
               : global-keys)
    (context-define-command! ctx 'keyboard-quit signal-quit
                             doc: "Cancel the current key sequence or command." source: (this-source))
    (context-provide! ctx input-service (Keys self))))
