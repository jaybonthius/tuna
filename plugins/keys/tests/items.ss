(import (tuna) (test) (test-user) (web) (options) (tables) (commands) (keys) (keys-test))

(define (key k code . modifiers)
  (keys:item-key (list (cons "type" "key") (cons "key" k) (cons "code" code) (cons "modifiers" (list->vector modifiers)))))

(define (settings-calls client)
  (map cdr (filter (lambda (call) (equal? "keys-settings" (car call))) (test-user:take-page-calls! client))))

(define (settings quit-keys left right)
  (list (cons "quitKeys" (list->vector quit-keys)) (cons "leftOptionMeta" left) (cons "rightOptionMeta" right)))

(test "a key item as the page script sends it names its key, whatever else the item holds"
  (check-equal? "C-g" (keys:item-key '(("type" . "key") ("key" . "g") ("code" . "KeyG") ("modifiers" . #("control")) ("quit" . #t)
                                       ("client" . "c1") ("seq" . 7)))))

(test "control gives C-, alt M-, super s-; shift is in a character and S- on a named key"
  (check-equal? '("C-x" "C-X" "_" "C-_" "C-?" "M-x" "M-X" "s-a" "é" "C--")
                (list (key "x" "KeyX" "control") (key "X" "KeyX" "control" "shift") (key "_" "Minus" "shift")
                      (key "_" "Minus" "control" "shift") (key "?" "Slash" "control" "shift") (key "x" "KeyX" "alt")
                      (key "X" "KeyX" "alt" "shift") (key "a" "KeyA" "super") (key "é" "KeyE") (key "-" "Minus" "control")))
  (check-equal? '("C-M-S-s-<left>" "S-<f1>" "S-TAB" "S-SPC" "C-SPC")
                (list (key "ArrowLeft" "ArrowLeft" "super" "shift" "alt" "control") (key "F1" "F1" "shift")
                      (key "Tab" "Tab" "shift") (key " " "Space" "shift") (key " " "Space" "control"))))

(test "the browser's named keys are Tuna's"
  (check-equal? '("RET" "SPC" "TAB" "ESC" "DEL" "<delete>" "<insert>" "<left>" "<right>" "<up>" "<down>" "<home>" "<end>"
                  "<prior>" "<next>" "<f1>" "<f12>" "<contextmenu>" "<audiovolumeup>")
                (map (lambda (k) (key k k))
                     '("Enter" " " "Tab" "Escape" "Backspace" "Delete" "Insert" "ArrowLeft" "ArrowRight" "ArrowUp"
                       "ArrowDown" "Home" "End" "PageUp" "PageDown" "F1" "F12" "ContextMenu" "AudioVolumeUp"))))

(test "AltGraph types the browser's character, with the Control and Alt some systems report beside it"
  (check-equal? '("@" "€" "{")
                (list (key "@" "KeyQ" "alt-graph") (key "€" "KeyE" "control" "alt" "alt-graph") (key "{" "Digit7" "alt-graph" "shift"))))

(test "an Option key that its option makes Meta gives M- and the US key at the code; otherwise it types the browser's character"
  (check-equal? '(#t #t) (list (keys:left-option-meta?) (keys:right-option-meta?)))
  (check-equal? '("M-x" "M-X" "M-!" "M--" "M-:" "M-SPC" "M-<left>" "M-e" "C-M-f" "M-¡" "M-s-w")
                (list (key "≈" "KeyX" "left-option") (key "˛" "KeyX" "left-option" "shift") (key "⁄" "Digit1" "left-option" "shift")
                      (key "–" "Minus" "left-option") (key "Ú" "Semicolon" "left-option" "shift") (key " " "Space" "left-option")
                      (key "ArrowLeft" "ArrowLeft" "left-option") (key "Dead" "KeyE" "left-option") (key "ƒ" "KeyF" "control" "left-option")
                      (key "¡" "IntlBackslash" "left-option") (key "∑" "KeyW" "left-option" "super")))
  (options:set! keys:right-option-meta? #f)
  (check-equal? '("≈" "<dead>" "M-x")
                (list (key "≈" "KeyX" "right-option") (key "Dead" "KeyE" "right-option") (key "≈" "KeyX" "left-option" "right-option")))
  (options:set! keys:left-option-meta? #f keys:right-option-meta? #t)
  (check-equal? '("≈" "M-x" "M-x")
                (list (key "≈" "KeyX" "left-option") (key "≈" "KeyX" "right-option") (key "≈" "KeyX" "left-option" "right-option")))
  (options:unset! keys:left-option-meta? keys:right-option-meta?))

(test "items the page script would not send are refused"
  (check-raises (keys-test:raised-by 'keys:item-key "not a modifier name") (key "x" "KeyX" "meta"))
  (check-raises (keys-test:raised-by 'keys:item-key "not a modifier name")
    (keys:item-key '(("type" . "key") ("key" . "x") ("code" . "KeyX") ("modifiers" . #(control)))))
  (check-raises (keys-test:raised-by 'keys:item-key "an item without a key") (keys:item-key '(("type" . "key") ("code" . "KeyX") ("modifiers" . #()))))
  (check-raises (keys-test:raised-by 'keys:item-key "an item without a list of modifiers")
    (keys:item-key '(("type" . "key") ("key" . "x") ("code" . "KeyX") ("modifiers" . ("control")))))
  (for-each (lambda (item) (check-raises (keys-test:raised-by 'keys:item-key "not an item") (keys:item-key item))) '("x" (1 2)))
  (for-each (lambda (k) (check-raises (keys-test:raised-by 'keys:item-key "not a key") (key k ""))) '("" "ab cd" "a-b" "👍🏽"))
  (check-equal? "👍" (key "👍" "")))

(test "every key item-key gives is one valid key"
  (for-each
    (lambda (k) (check-equal? (list k) (keys:sequence-keys k)))
    (list (key "≈" "KeyX" "left-option") (key "ArrowLeft" "ArrowLeft" "super" "shift" "alt" "control")
          (key "Dead" "KeyE" "left-option") (key "👍" "") (key "<" "Comma" "control" "shift")
          (key "F1" "F1" "shift") (key "\\" "Backslash" "alt") (key "~" "Backquote" "shift" "super"))))

(test "the page learns the quit keys and the Option options after the first batch its client is connected in, and after every change"
  (let ([c1 (test-user:open-client)])
    (test-user:settle)
    (check-equal? (list (settings '("C-g" "ESC") #t #t)) (settings-calls c1))
    (test-user:settle)
    (check-equal? '() (settings-calls c1))
    (options:set! keys:quit-keys '("C-g") keys:left-option-meta? #f)
    (let ([c2 (test-user:open-client)])
      (test-user:settle)
      (check-equal? (list (settings '("C-g") #f #t)) (settings-calls c1))
      (check-equal? (list (settings '("C-g") #f #t)) (settings-calls c2))
      (check-equal? '("C-g") (keys:page-quit-keys c2))
      (options:unset! keys:quit-keys keys:left-option-meta?)
      (test-user:settle)
      (check-equal? (list (settings '("C-g" "ESC") #t #t)) (settings-calls c1))
      (check-equal? (list (settings '("C-g" "ESC") #t #t)) (settings-calls c2))
      (web:close-client! c2))
    (web:close-client! c1)))

(test "each quit key is one valid key"
  (for-each
    (lambda (v) (check-raises (lambda (c) (and (who-condition? c) (eq? 'options:set! (condition-who c)))) (options:set! keys:quit-keys v)))
    '(("C-x C-g") "C-g" ("S-a")))
  (check-equal? '("C-g" "ESC") (keys:quit-keys)))

(test "what a quit key runs is its binding: the global keymap binds C-g and ESC to keyboard-quit, so ESC x is nothing"
  (check-equal? (list keys:keyboard-quit keys:keyboard-quit #f)
                (map (lambda (k) (keys:lookup (test-user:client) k)) '("C-g" "ESC" "ESC x"))))

(test "a quit key is never an ESC waiting to make the next key Meta, so it ends pending keys as C-g does"
  (check-equal? '("C-x ESC is undefined") (keys-test:report-messages (lambda () (test-user:press! "C-x ESC"))))
  (check-equal? #f (keys:pending (test-user:client)))
  (keys:unbind! keys:global "ESC")
  (keys:bind! keys:global "M-x" keys:ignore)
  (check-equal? '("ESC is undefined") (keys-test:report-messages (lambda () (test-user:press! "ESC"))))
  (check-equal? '(#f #f) (list (keys:pending (test-user:client)) (keys:lookup (test-user:client) "ESC x")))
  (options:set! keys:quit-keys '("C-g"))
  (check-equal? keys:ignore (keys:lookup (test-user:client) "ESC x"))
  (test-user:press! "C-x ESC")
  (check-equal? "C-x ESC" (keys:pending (test-user:client)))
  (check-equal? '("C-x ESC C-g is undefined") (keys-test:report-messages (lambda () (test-user:press! "C-g"))))
  (options:unset! keys:quit-keys)
  (keys:bind! keys:global "ESC" keys:keyboard-quit))
