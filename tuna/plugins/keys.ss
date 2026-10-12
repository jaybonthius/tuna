;;; Key handling (startup tier): the global keymap, key resolution, and the
;;; quit key (ADR 8).
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys)
(export keys-plugin
        key-description)

(def quit-key "C-g")

(defclass global-keys ((keymap  : entry-table)   ; key sequence -> command name
                       (pending : :list))        ; keys typed so far of a prefix
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

(def (prefix-of-binding? (self : global-keys) (keys : :string)) => :boolean
  (let (prefix (string-append keys " "))
    (ormap (lambda ((bound : :string)) (string-prefix? prefix bound))
           (entry-table-keys self.keymap))))

(def (resolve-key! (self : global-keys) (event : key-event)) => :t
  (let (key (key-description event))
    (cond
     ((not key) #f)
     ((equal? key quit-key)
      (set! self.pending [])
      (command-ref 'keyboard-quit))
     (else
      (message "")
      (let* ((typed (append self.pending [key]))
             (keys (string-join typed " "))
             (binding (entry-table-ref self.keymap keys)))
        (cond
         (binding
          (set! self.pending [])
          (let (name (entry-value binding))
            (or (command-ref name)
                (begin
                  (message (string-append keys " runs " (symbol->string name) ", which is not defined"))
                  #f))))
         ((prefix-of-binding? self keys)
          (set! self.pending typed)
          (message (string-append keys "-"))
          #f)
         (else
          (set! self.pending [])
          (message (string-append keys " is undefined"))
          #f)))))))

(defmethod {resolve-event! global-keys}
  (lambda (self event) (resolve-key! self event)))

(defmethod {quit-event? global-keys}
  (lambda (self event) (equal? (key-description event) quit-key)))

(defmethod {keymap-set! global-keys}
  (lambda (self ctx keys command)
    (using (self : global-keys)
      (context-add-entry! ctx self.keymap (normalize-keys keys) command)
      (void))))

(defmethod {key-binding global-keys}
  (lambda (self keys)
    (using (self : global-keys)
      (entry-table-ref self.keymap (normalize-keys keys)))))

(defplugin (keys-plugin ctx)
  "Resolves keys through the global keymap. C-g quits."
  (define-command ctx (keyboard-quit) "Cancel the current key sequence or command."
    (signal-quit))
  (context-provide! ctx input-service
                    (Keys (global-keys keymap: (new-entry-table) pending: []))))
