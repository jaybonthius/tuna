;;; Key presses and clicks for tests that drive plugins through the real
;;; editor loop.
(import :tuna/kernel
        (only-in :tuna/services/keys make-key-event make-pointer-event make-posn))
(export press
        type!
        click)

(def sequence 0)

(def browser-keys
  '(("RET" . "Enter") ("DEL" . "Backspace") ("SPC" . " ")
    ("<up>" . "ArrowUp") ("<down>" . "ArrowDown")
    ("<left>" . "ArrowLeft") ("<right>" . "ArrowRight")))

;; Submit one key to the running editor loop: "a", "RET", "C-f", "<up>",
;; "S-<left>".
(def (press (key : :string)) => :void
  (set! sequence (+ sequence 1))
  (let* ((ctrl? (string-prefix? "C-" key))
         (shift? (string-prefix? "S-" key))
         (alt? (string-prefix? "M-" key))
         (name (if (or ctrl? shift? alt?) (substring key 2 (string-length key)) key))
         (browser-key (cond
                       ((assoc name browser-keys) => cdr)
                       (else name))))
    ((input-submitter)
     (make-key-event "test-client" sequence browser-key "" 0 #f #f alt? ctrl? #f shift? #f #f #f #f))))

(def (type! . keys)
  (for-each press keys))

;; Submit one click to the running editor loop on the part AREA with id
;; PART, as if made on screen REVISION: (click 'tab-line 30),
;; (click 'view 12 button: 3 clicks: 2 ctrl?: #t node: 4).
(def (click (area : :symbol) (part : :fixnum)
            button: (button 1) clicks: (clicks 1) node: (node #f) revision: (revision 0)
            ctrl?: (ctrl? #f) alt?: (alt? #f) shift?: (shift? #f) meta?: (meta? #f))
  => :void
  (set! sequence (+ sequence 1))
  ((input-submitter)
   (make-pointer-event "test-client" sequence button clicks alt? ctrl? meta? shift?
                       (make-posn area part node revision))))
