;;; Which keys a terminal's keymaps send, and how a browser key becomes
;;; the bytes its program asked for.
(import :std/test
        (only-in :tuna/plugins/keys/contract make-key-event)
        :tuna/plugins/terminal/keys
        (only-in :gerbil-libghostty/ghostty make-terminal make-key-encoder key-encoder-encode terminal-write!))
(export keys-test)

;; A browser keydown: KEY and CODE, with modifiers.
(def (browser-key key code ctrl?: (ctrl? #f) alt?: (alt? #f) shift?: (shift? #f))
  (make-key-event 1 #f key code 0 #f #f alt? ctrl? #f shift? #f #f #f #f))

(def (encoded event (term (make-terminal 80 24)))
  (u8vector->list (key-encoder-encode (make-key-encoder) (terminal-key-event event) terminal: term)))

(def keys-test
  (test-suite "tuna/plugins/terminal: keys"
    (test-case "semi-char mode keeps ghostel's exceptions; char mode sends them too"
      (let ((semi (terminal-key-names default-keymap-exceptions #f))
            (char (terminal-key-names default-keymap-exceptions #t)))
        (for-each (lambda (key) (check (and (member key semi) #t) => #f)) default-keymap-exceptions)
        (for-each (lambda (key) (check (and (member key char) #t) => #t)) default-keymap-exceptions)
        (check (and (member "C-y" semi) #t) => #f)
        (check (and (member "C-g" char) #t) => #t)
        (for-each (lambda (key) (check (and (member key semi) #t) => #t))
                  ["SPC" "RET" "C-a" "M-f" "C-M-x" "S-<up>" "C-<left>" "<f5>" "M-DEL" "C-]"])))

    (test-case "browser codes name libghostty's physical keys"
      (check (map browser-physical-key ["KeyA" "Digit7" "ArrowLeft" "Numpad1" "F5" "PageUp" "Space" "IntlBackslash" "Nope"])
             => '(a digit-7 arrow-left numpad-1 f5 page-up space intl-backslash #f))
      (check (event-physical-key (browser-key "Enter" "")) => 'enter)
      (check (event-physical-key (browser-key "q" "")) => 'q))

    (test-case "keys encode as the program's modes ask"
      (check (encoded (browser-key "c" "KeyC" ctrl?: #t)) => '(3))
      (check (encoded (browser-key "Enter" "Enter")) => '(13))
      (check (encoded (browser-key "A" "KeyA" shift?: #t)) => '(65))
      (check (encoded (browser-key "x" "KeyX" alt?: #t)) => '(27 120))
      (check (encoded (browser-key "ArrowUp" "ArrowUp")) => '(27 91 65))
      ;; Application cursor keys (DECCKM), as vim asks for them.
      (let (term (make-terminal 80 24))
        (terminal-write! term (string->utf8 "\x1b;[?1h"))
        (check (encoded (browser-key "ArrowUp" "ArrowUp") term) => '(27 79 65))))))
