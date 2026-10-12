;;; Key handling (startup tier): the global keymap, the input-target stack,
;;; key resolution, and the quit key (ADR 3, ADR 8). Keys resolve in the
;;; innermost input target's keymap, then in the global keymap.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys)
(export keys-plugin
        key-description)

(def quit-key "C-g")

(defclass global-keys ((keymap        : entry-table)    ; key sequence -> command name
                       (targets       : :list)          ; input targets, innermost first
                       (pending       : :list)          ; keys typed so far of a prefix
                       (this-command  :? :symbol)       ; the input session (ADR 8)
                       (last-command  :? :symbol)
                       (command-event :? key-event))
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
                    (entry-table-keys keymap)))
           keymaps)))

(def (printing-char? (key : :string)) => :boolean
  (and (fx= (string-length key) 1)
       (char>? (string-ref key 0) #\space)
       (not (char=? (string-ref key 0) #\delete))))

;; A key sequence ended with EVENT and selected the command named NAME, or
;; #f for none.
(def (complete-keys! (self : global-keys) (event : key-event) (name :? :symbol)) => :void
  (set! self.pending [])
  (set! self.last-command self.this-command)
  (set! self.this-command name)
  (set! self.command-event event))

(def (resolve-key! (self : global-keys) (event : key-event)) => :t
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
        (command-ref name)))
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
            (or (command-ref name)
                (begin
                  (message (string-append keys " runs " (symbol->string name) ", which is not defined"))
                  #f))))
         ((prefix-of-binding? keymaps keys)
          (set! self.pending typed)
          (message (string-append keys "-"))
          #f)
         (else
          (complete-keys! self event #f)
          (message (string-append keys " is undefined"))
          #f)))))))

(defmethod {resolve! global-keys}
  (lambda (self event) (resolve-key! self event)))

;; The quit key interrupts; every other key event is queued.
(defmethod {arrival global-keys}
  (lambda (self event) (if (equal? (key-description event) quit-key) 'interrupt 'queue)))

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
  (define-command ctx (keyboard-quit) "Cancel the current key sequence or command."
    (signal-quit))
  (context-provide! ctx input-service
                    (Keys (global-keys keymap: (new-entry-table) targets: [] pending: []
                                       this-command: #f last-command: #f command-event: #f))))
