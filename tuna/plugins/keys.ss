;;; Key handling (startup tier): the command table, the global keymap, the
;;; input-target stack, key resolution, and the quit key (ADR 3, ADR 8).
;;; Keys resolve in the innermost input target's keymap, then in the global
;;; keymap. So do clicks: under the part kind as a prefix key, then without
;;; it, each from the most specific event name down (`pointer-event-names`).
;;; A click does not clear the echo area, so clicking it to read a message
;;; keeps the message.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys)
(export keys-plugin
        key-description)

(def quit-key "C-g")

(defclass global-keys ((commands      : entry-table)    ; command name -> command
                       (keymap        : entry-table)    ; key sequence -> command name
                       (targets       : :list)          ; input targets, innermost first
                       (pending       : :list)          ; keys typed so far of a prefix
                       (this-command  :? :symbol)       ; the input session (ADR 8)
                       (last-command  :? :symbol)
                       (command-event :? :t))           ; key-event or pointer-event
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

;; The keymaps keys resolve in, first to last.
(def (active-keymaps (self : global-keys)) => :list
  (match self.targets
    ([innermost . _] [(input-target-keymap innermost) self.keymap])
    ([] [self.keymap])))

;; The first binding of KEYS in KEYMAPS, or #f.
(def (lookup (keymaps : :list) (keys : :string)) => (Maybe entry)
  (ormap (cut entry-table-ref <> keys) keymaps))

(def (prefix-of-binding? (keymaps : :list) (keys : :string)) => :boolean
  (let (prefix (string-append keys " "))
    (ormap (lambda ((keymap : entry-table))
             (ormap (lambda ((bound : :string)) (string-prefix? prefix bound))
                    (entry-table-names keymap)))
           keymaps)))

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
        (keymaps (active-keymaps self)))
    (cond
     ((not key) #f)
     ((equal? key quit-key)
      ;; The quit key cancels a pending prefix; a waiting prompt may bind it.
      (let (name (cond
                  ((lookup keymaps quit-key) => entry-value)
                  (else 'keyboard-quit)))
        (complete-keys! self event name)
        (command-task self name)))
     (else
      (message "")
      (let* ((typed (append self.pending [key]))
             (keys (string-join typed " "))
             (binding (or (lookup keymaps keys)
                          (and (null? self.pending)
                               (printing-char? key)
                               (lookup keymaps printing-char-key)))))
        (cond
         (binding
          (let (name (entry-value binding))
            (complete-keys! self event name)
            (bound-command-task self keys name)))
         ((prefix-of-binding? keymaps keys)
          (set! self.pending typed)
          (message (string-append keys "-"))
          #f)
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
;; are that prefix, the part kind, and each of its event names ("C-x <tab>
;; <double-mouse-1>", "C-x <tab> <mouse-1>"), then the same without the
;; part kind.
(def (resolve-pointer! (self : global-keys) (event : pointer-event)) => (Maybe :pair)
  (let* ((keymaps (active-keymaps self))
         (area (string-append "<" (symbol->string (posn-area (pointer-event-start event))) ">"))
         (names (map (lambda ((name : :string)) (string-append "<" name ">"))
                     (pointer-event-names event)))
         (sequences (map (lambda ((tail : :list)) (string-join (append self.pending tail) " "))
                         (append (map (lambda (name) [area name]) names)
                                 (map (lambda (name) [name]) names))))
         (found (ormap (lambda ((keys : :string))
                         (let (binding (lookup keymaps keys))
                           (and binding (cons keys (entry-value binding)))))
                       sequences)))
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

(defmethod {keymap-set! global-keys}
  (lambda (self ctx keys command source)
    (using (self : global-keys)
      (context-add-entry! ctx self.keymap (normalize-keys keys) command source: source)
      (void))))

(defmethod {keymap-set-in! global-keys}
  (lambda (self ctx keymap keys command source)
    (context-add-entry! ctx keymap (normalize-keys keys) command source: source)
    (void)))

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

(defplugin (keys-plugin ctx)
  "Resolves keys through the global keymap. C-g quits."
  (using (self (global-keys commands: (new-entry-table) keymap: (new-entry-table) targets: []
                            pending: [] this-command: #f last-command: #f command-event: #f)
               : global-keys)
    ;; Straight into this table: while this plugin activates, the input
    ;; service need not resolve to it yet.
    (add-command! self ctx 'keyboard-quit signal-quit
                  "Cancel the current key sequence or command." (this-source))
    (context-provide! ctx input-service (Keys self))))
