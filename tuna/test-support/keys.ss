;;; Key presses for tests that drive plugins through the real editor loop.
(import :tuna/kernel
        (only-in :tuna/services/keys make-key-event))
(export press
        type!)

(def sequence 0)

(def browser-keys
  '(("RET" . "Enter") ("DEL" . "Backspace") ("SPC" . " ")
    ("<up>" . "ArrowUp") ("<down>" . "ArrowDown")
    ("<left>" . "ArrowLeft") ("<right>" . "ArrowRight")))

;; Submit one key to the running editor loop: "a", "RET", "C-f", "<up>".
(def (press (key : :string)) => :void
  (set! sequence (+ sequence 1))
  (let* ((ctrl? (string-prefix? "C-" key))
         (name (if ctrl? (substring key 2 (string-length key)) key))
         (browser-key (cond
                       ((assoc name browser-keys) => cdr)
                       (else name))))
    ((input-submitter)
     (make-key-event "test-client" sequence browser-key "" 0 #f #f #f ctrl? #f #f))))

(def (type! . keys)
  (for-each press keys))
