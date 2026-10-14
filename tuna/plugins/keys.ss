;;; Key handling (startup tier): the command table, the global keymap, the
;;; input-target stack, key resolution, and the quit key (ADR 3, ADR 8).
;;;
;;; Keys resolve in the keymaps of the focused node and the nodes above it
;;; (when a buffers provider is running), then the innermost input
;;; target's, then the global keymap (the keys contract lists the order). So do clicks, starting at the node clicked (when a layout is
;;; running): in each keymap under the part kind as a prefix key, then
;;; without it, each from the most specific event name down
;;; (`pointer-event-names`), before the next keymap. A click does not clear
;;; the echo area, so clicking it to read a message keeps the message.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        (only-in :tuna/services/buffers
                 buffers-service selected-view view-node view-showing buffer-root
                 node node-parent node-keymap)
        (only-in :tuna/services/layout layout-service posn-view posn-node))
(export keys-plugin
        key-description)

(def quit-key "C-g")

(defclass global-keys ((commands      : entry-table)    ; command name -> command
                       (keymap        : entry-table)    ; key sequence -> command name
                       (targets       : :list)          ; input targets, innermost first
                       (pending       : :list)          ; keys typed so far of a prefix
                       (this-command  :? :symbol)       ; the input session (ADR 8)
                       (last-command  :? :symbol)
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

;; EVENT in Emacs key syntax ("C-c", "M-x", "<left>"), or #f for a key that
;; only modifies or composes others.
(def (key-description (event : key-event)) => (Maybe :string)
  (let (key (key-event-key event))
    (and (not (key-event-composing? event))
         (not (member key ignored-keys))
         (let* ((character? (fx= (string-length key) 1))
                (base (cond
                       ((hash-get named-keys key))
                       (character? key)
                       (else (string-append "<" (string-downcase key) ">")))))
           (string-append (if (key-event-ctrl? event) "C-" "")
                          (if (key-event-alt? event) "M-" "")
                          (if (and (key-event-shift? event) (not character?)) "S-" "")
                          (if (key-event-meta? event) "s-" "")
                          base)))))

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
  (and (service-provider buffers-service)
       (let (v (selected-view))
         (or (view-node v) (buffer-root (view-showing v))))))

;; The node a click at P starts from: the node clicked, or the root of the
;; clicked view's buffer; #f without a layout or a view.
(def (clicked-node (p : posn)) => (Maybe node)
  (and (service-provider layout-service)
       (or (posn-node p)
           (let (v (posn-view p))
             (and v (buffer-root (view-showing v)))))))

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

;; Add the command NAME to SELF's table, owned by CTX's plugin.
(def (add-command! (self : global-keys) (ctx : context) (name : :symbol) (procedure : :procedure)
                   (doc : :string) (source :? :string))
  => :void
  (context-add-entry! ctx self.commands name (make-command name procedure doc)
                      doc: doc source: source)
  (void))

;; The task that runs the command named NAME, as (name . thunk), or #f.
(def (command-task (self : global-keys) (name : :symbol)) => (Maybe :pair)
  (let (best (entry-table-ref self.commands name))
    (and best
         (using (c (entry-value best) : command)
           (cons c.name c.procedure)))))

;; A key sequence ended with EVENT, a key or pointer event, and selected
;; the command named NAME, or #f for none.
(def (complete-keys! (self : global-keys) (event : :t) (name :? :symbol)) => :void
  (set! self.pending [])
  (set! self.last-command self.this-command)
  (set! self.this-command name)
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
         (keymaps (active-keymaps self (clicked-node start)))
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

(defmethod {resolve! global-keys}
  (lambda (self event)
    (if (pointer-event? event)
      (resolve-pointer! self event)
      (resolve-key! self event))))

;; The quit key interrupts; every other key or pointer event is queued.
(defmethod {arrival global-keys}
  (lambda (self event)
    (if (and (key-event? event) (equal? (key-description event) quit-key)) 'interrupt 'queue)))

(defmethod {define-command! global-keys}
  (lambda (self ctx name procedure doc source)
    (add-command! self ctx name procedure doc source)))

(defmethod {command-entry global-keys}
  (lambda (self name)
    (using (self : global-keys)
      (entry-table-ref self.commands name))))

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

(defmethod {last-command global-keys}
  (lambda (self) (global-keys-last-command self)))

(defmethod {last-command-event global-keys}
  (lambda (self) (global-keys-command-event self)))

(defmethod {keymap-generation global-keys}
  (lambda (self) (global-keys-generation self)))

(defplugin (keys-plugin ctx)
  "Resolves keys through node keymaps and the global keymap. C-g quits."
  (using (self (global-keys commands: (new-entry-table) keymap: (new-entry-table) targets: []
                            pending: [] this-command: #f last-command: #f command-event: #f
                            generation: (next-id!))
               : global-keys)
    ;; Straight into this table: while this plugin activates, the input
    ;; service need not resolve to it yet.
    (add-command! self ctx 'keyboard-quit signal-quit
                  "Cancel the current key sequence or command." (this-source))
    (context-provide! ctx input-service (Keys self))))
