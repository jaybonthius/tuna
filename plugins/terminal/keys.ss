;;; Keys for terminals: which keys a terminal's keymaps send to its
;;; program, as ghostel binds them (`ghostel--define-terminal-keys`), and a
;;; browser key as a libghostty key event, which the terminal's own key
;;; encoder turns into bytes for the modes the program asked for
;;; (application cursor keys, the Kitty keyboard protocol).
prelude: :gerbil/core

(import (only-in :tuna/plugins/keys/contract
                 key-event key-event-key key-event-code key-event-repeat? key-event-composing?
                 key-event-alt? key-event-ctrl? key-event-meta? key-event-shift? key-event-alt-graph?)
        (rename-in (only-in :gerbil-libghostty/ghostty
                            key-event physical-key? key-text?)
                   (key-event ghostty-key-event)))
(export terminal-key-names
        event-physical-key
        default-keymap-exceptions
        browser-physical-key
        terminal-key-event
        key-unshifted-codepoint)

;; The keys Tuna keeps in semi-char mode (ghostel-keymap-exceptions).
(def default-keymap-exceptions
  ["C-c" "C-x" "C-u" "C-h" "M-x" "M-:" "C-\\"])

;; Keys with names, as Tuna writes them (the keys plugin's
;; key-description), that ghostel sends with every modifier.
(def special-keys
  ["RET" "TAB" "DEL" "ESC" "<up>" "<down>" "<right>" "<left>" "<home>" "<end>" "<prior>" "<next>"
   "<delete>" "<insert>" "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>" "<f7>" "<f8>" "<f9>" "<f10>"
   "<f11>" "<f12>"])

;; Tuna writes modifiers in this order: C- M- S- s-.
(def special-modifiers ["" "S-" "C-" "M-" "C-S-" "M-S-" "C-M-"])

(def (letters (prefix : :string)) => :list
  (map (lambda ((i : :fixnum)) (string-append prefix (string (integer->char (fx+ 97 i))))) (iota 26)))

;; The keys a terminal keymap sends to the program: everything ghostel
;; binds, minus EXCEPTIONS unless CHAR-MODE?, which binds them all. C-y
;; (yank) and C-g are bound separately, as in ghostel. Printing
;; characters are reached through the keys contract's <printing-char>,
;; which is not SPC.
(def (terminal-key-names (exceptions : :list) (char-mode? : :boolean)) => :list
  (let* ((keep? (lambda ((key : :string)) (or char-mode? (not (member key exceptions)))))
         (specials (apply append (map (lambda ((key : :string))
                                        (map (cut string-append <> key) special-modifiers))
                                      special-keys)))
         (controls (filter (lambda ((key : :string)) (not (member key ["C-y" "C-g"]))) (letters "C-")))
         (metas (map (lambda ((i : :fixnum)) (string-append "M-" (string (integer->char (fx+ 33 i)))))
                     (iota (fx- 127 33))))
         (others (append ["SPC" "M-SPC" "M-DEL"] (letters "C-M-") ["C-]" "C-/" "C-M-]" "C-M-/" "C-@"]
                         (if char-mode? ["C-SPC" "C-\\" "M-:" "C-y" "C-g"] []))))
    (filter keep? (append specials controls metas others))))

;;; Browser keys

(def named-codes
  '(("MetaLeft" . super-left) ("MetaRight" . super-right) ("OSLeft" . super-left)
    ("OSRight" . super-right) ("Space" . space)))

;; The libghostty physical key at the browser's KeyboardEvent.code CODE,
;; or #f for one it does not know: "KeyA" is a, "Digit1" digit-1,
;; "ArrowLeft" arrow-left, "Numpad1" numpad-1, "F5" f5.
(def (browser-physical-key (code : :string)) => (Maybe :symbol)
  (let* ((size (string-length code))
         (name
          (cond
           ((assoc code named-codes) => cdr)
           ((and (fx= size 4) (string-prefix? "Key" code))
            (string->symbol (string-downcase (substring code 3 4))))
           ((and (fx> size 1) (char=? (string-ref code 0) #\F) (string->number (substring code 1 size)))
            (string->symbol (string-downcase code)))
           (else
            (let (out (open-output-string))
              (let lp ((i 0))
                (when (fx< i size)
                  (let (c (string-ref code i))
                    (when (and (fx> i 0)
                               (or (char-upper-case? c)
                                   (and (char-numeric? c) (not (char-numeric? (string-ref code (fx1- i)))))))
                      (write-char #\- out))
                    (write-char (char-downcase c) out))
                  (lp (fx1+ i))))
              (string->symbol (get-output-string out)))))))
    (and (physical-key? name) name)))

;; Physical keys on a US keyboard by code: unshifted, then shifted.
(def us-punctuation
  '(("Backquote" . "`~") ("Minus" . "-_") ("Equal" . "=+") ("BracketLeft" . "[{")
    ("BracketRight" . "]}") ("Backslash" . "\\|") ("Semicolon" . ";:") ("Quote" . "'\"")
    ("Comma" . ",<") ("Period" . ".>") ("Slash" . "/?") ("Space" . "  ")))

;; The character KEY's code types without modifiers on a US keyboard, or
;; #f: what the encoder needs for C-a or the Kitty protocol when the
;; browser's key text is the shifted or composed character.
(def (key-unshifted-codepoint (e : key-event)) => (Maybe :char)
  (let* ((code (key-event-code e))
         (size (string-length code))
         (key (key-event-key e)))
    (cond
     ((and (fx= size 4) (string-prefix? "Key" code)) (char-downcase (string-ref code 3)))
     ((and (fx= size 6) (string-prefix? "Digit" code)) (string-ref code 5))
     ((assoc code us-punctuation) => (lambda ((pair : :pair)) (string-ref (cdr pair) 0)))
     ((and (fx= size 0) (fx= (string-length key) 1) (char-alphabetic? (string-ref key 0)))
      (char-downcase (string-ref key 0)))
     (else #f))))

;; Whether TEXT, the browser's key text, is one character the program
;; should receive as typed text.
(def (typed-text? (text : :string)) => :boolean
  (and (fx= (string-length text) 1)
       (char>=? (string-ref text 0) #\space)
       (not (char=? (string-ref text 0) #\delete))
       (key-text? text)))

;; E, a browser key, as a libghostty key event, or #f when it names no
;; key libghostty knows and types nothing.
;; Browser key names as physical keys, for events without a code.
(def named-keys
  '(("Enter" . enter) ("Tab" . tab) ("Backspace" . backspace) ("Escape" . escape) (" " . space)
    ("ArrowUp" . arrow-up) ("ArrowDown" . arrow-down) ("ArrowLeft" . arrow-left)
    ("ArrowRight" . arrow-right) ("Home" . home) ("End" . end) ("PageUp" . page-up)
    ("PageDown" . page-down) ("Insert" . insert) ("Delete" . delete)))

;; The physical key E names: by its code, or, without one (an event a
;; program made), by its key: a named key, a letter or a digit.
(def (event-physical-key (e : key-event)) => (Maybe :symbol)
  (let (key (key-event-key e))
    (or (browser-physical-key (key-event-code e))
        (let (named (assoc key named-keys)) (and named (cdr named)))
        (and (fx= (string-length key) 1)
             (let (c (char-downcase (string-ref key 0)))
               (cond
                ((char<=? #\a c #\z) (string->symbol (string c)))
                ((char<=? #\0 c #\9) (string->symbol (string-append "digit-" (string c))))
                (else #f))))
        (browser-physical-key key))))

(def (terminal-key-event (e : key-event)) => :t
  (let* ((key (event-physical-key e))
         (text (key-event-key e))
         (alt-graph? (key-event-alt-graph? e))
         (typed (and (typed-text? text) text))
         (modifiers (append (if (and (key-event-ctrl? e) (not alt-graph?)) '(ctrl) '())
                            (if (and (key-event-alt? e) (not alt-graph?)) '(alt) '())
                            (if (key-event-meta? e) '(super) '())
                            (if (key-event-shift? e) '(shift) '())))
         ;; Shift (and AltGr) made the typed character: the program gets
         ;; the character, not the modifier.
         (consumed (append (if (and typed (key-event-shift? e)) '(shift) '())
                           (if alt-graph? '(ctrl alt) '())))
         (unshifted (key-unshifted-codepoint e)))
    (and (or key typed)
         (ghostty-key-event (if (key-event-repeat? e) 'repeat 'press) (or key 'unidentified)
                            modifiers: modifiers
                            consumed-modifiers: (filter (cut memq <> modifiers) consumed)
                            text: typed
                            unshifted-codepoint: unshifted
                            composing?: (key-event-composing? e)))))
