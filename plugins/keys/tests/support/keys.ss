;;; Key presses and clicks for tests that drive plugins through the real
;;; editor loop.
(import :tuna/kernel
        (only-in :tuna/plugins/keys/contract make-key-event make-pointer-event make-posn make-paste-event))
(export press
        type!
        click
        paste)

(def sequence 0)

(def browser-keys
  '(("RET" . "Enter") ("DEL" . "Backspace") ("SPC" . " ")
    ("<up>" . "ArrowUp") ("<down>" . "ArrowDown")
    ("<left>" . "ArrowLeft") ("<right>" . "ArrowRight")
    ("<delete>" . "Delete")))

;; Submit one key to the running editor loop: "a", "RET", "C-f", "<up>",
;; "S-<left>", "C-S-<right>", "M-DEL", from the clients contract's CLIENT,
;; if given. Modifiers come in the order C-, M-, S-.
(def (press (key : :string) client: (client #f)) => :void
  (set! sequence (+ sequence 1))
  (let* ((ctrl? (string-prefix? "C-" key))
         (key (if ctrl? (substring key 2 (string-length key)) key))
         (alt? (string-prefix? "M-" key))
         (key (if alt? (substring key 2 (string-length key)) key))
         (shift? (string-prefix? "S-" key))
         (name (if shift? (substring key 2 (string-length key)) key))
         (browser-key (cond
                       ((assoc name browser-keys) => cdr)
                       (else name))))
    ((input-submitter)
     (make-key-event sequence client browser-key "" 0 #f #f alt? ctrl? #f shift? #f #f #f #f))))

(def (type! . keys)
  (for-each press keys))

;; Submit one click to the running editor loop on the part AREA with id
;; PART, as if made on screen REVISION: (click 'tab-line 30),
;; (click 'view 12 button: 3 clicks: 2 ctrl?: #t node: 4); in a line, by
;; its token, its text's revision when drawn and a column:
;; (click 'view 12 node: 4 line: "4.7.0" line-revision: 0 column: 3).
;; KIND makes it a press, a movement or a drag instead (the keys
;; contract's pointer-event): (click 'view 12 kind: 'down …).
(def (click (area : :symbol) (part : :fixnum) kind: (kind 'click)
            client: (client #f) button: (button 1) clicks: (clicks 1) node: (node #f) revision: (revision 0)
            line: (line #f) line-revision: (line-revision 0) column: (column 0)
            ctrl?: (ctrl? #f) alt?: (alt? #f) shift?: (shift? #f) meta?: (meta? #f))
  => :void
  (set! sequence (+ sequence 1))
  ((input-submitter)
   (make-pointer-event sequence client kind button clicks alt? ctrl? meta? shift?
                       (make-posn area part node revision line line-revision column))))

;; Submit a paste of TEXT to the running editor loop, from the clients
;; contract's CLIENT, if given.
(def (paste (text : :string) client: (client #f)) => :void
  (set! sequence (+ sequence 1))
  ((input-submitter) (make-paste-event sequence client text)))
