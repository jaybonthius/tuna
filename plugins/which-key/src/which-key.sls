#!tuna
(import (keys) (commands) (layout) (web) (haml) (hooks) (options) (tables) (timers))

(define %self (current-owner))

(options:define-option delay 1.0 (lambda (v) (and (real? v) (finite? v) (not (negative? v))))
  "Seconds from the key that leaves keys pending to the popup, not negative; 0 shows it with that key's screen.")

(tables:define-table labels
  "Maps a prefix, a key sequence such as \"C-c l\", to the label the popup shows for it in its parent's popup.")

(define-record-type (%waiting %make-waiting %waiting?)
  (sealed #t)
  (fields (mutable timer %waiting-timer %waiting-timer-set!)
          (mutable ready %waiting-ready %waiting-ready-set!)))

;; Weak, since a key whose command was paused when its client went away
;; returns afterwards and makes an entry again.
(define %clients (make-weak-eq-hashtable))

(define (%waiting-of client)
  (or (eq-hashtable-ref %clients client #f)
      (let ([w (%make-waiting #f #f)])
        (eq-hashtable-set! %clients client w)
        w)))

(define (%stop-timer! w)
  (when (%waiting-timer w)
    (timers:cancel! (%waiting-timer w))
    (%waiting-timer-set! w #f)))

(define (%forget! w)
  (%stop-timer! w)
  (%waiting-ready-set! w #f))

(define (%forget-client! client)
  (let ([w (eq-hashtable-ref %clients client #f)])
    (when w
      (%stop-timer! w)
      (eq-hashtable-delete! %clients client))))

(define (%first-key keys)
  (let loop ([i 0])
    (cond
      [(fx= i (string-length keys)) keys]
      [(char=? (string-ref keys i) #\space) (substring keys 0 i)]
      [else (loop (fx+ i 1))])))

(define (%after prefix s)
  (let ([n (string-length prefix)])
    (and (fx< n (string-length s))
         (string=? prefix (substring s 0 n))
         (substring s n (string-length s)))))

(define (%mouse-key? key)
  (let ([n (string-length key)])
    (and (fx> n 0)
         (char=? (string-ref key (fx- n 1)) #\>)
         (let loop ([i 0])
           (and (fx<= (fx+ i 6) n)
                (or (string=? (substring key i (fx+ i 6)) "mouse-")
                    (string=? (substring key i (fx+ i 6)) "wheel-")
                    (loop (fx+ i 1))))))))

(define (%extends? keys ready)
  (or (string=? keys ready) (and (%after (string-append ready " ") keys) #t)))

(define (%wait! client w keys)
  (%stop-timer! w)
  (unless (%mouse-key? (%first-key keys))
    (if (zero? (delay))
        (%waiting-ready-set! w keys)
        (call-as-owner %self
          (lambda ()
            (%waiting-timer-set! w
              (timers:run-after (delay)
                (lambda ()
                  (%waiting-timer-set! w #f)
                  (when (equal? (keys:pending client) keys)
                    (%waiting-ready-set! w keys))))))))))

;; A key that runs a command returns only when the command ends, which
;; may be after a pause, so a key counts as leaving keys pending only when
;; the pending keys are the ones it made.
(define (%follow-keys press client key)
  (let ([before (keys:pending client)] [name (if (pair? key) (car key) key)])
    (press client key)
    (let ([pending (keys:pending client)] [w (%waiting-of client)])
      (cond
        [(not pending) (%forget! w)]
        [(not (string=? pending (if before (string-append before " " name) name))) (void)]
        [(and before (%waiting-ready w) (%extends? pending (%waiting-ready w))) (void)]
        [else (%waiting-ready-set! w #f) (%wait! client w pending)]))))

(define (%named-key? key) (member key '("RET" "SPC" "TAB" "ESC" "DEL")))

(define (%modified-key? key)
  (and (fx> (string-length key) 2)
       (char=? (string-ref key 1) #\-)
       (memv (string-ref key 0) '(#\C #\M #\S #\s))
       #t))

(define (%function-key-number key)
  (let ([n (string-length key)])
    (and (fx> n 3)
         (string=? (substring key 0 2) "<f")
         (char=? (string-ref key (fx- n 1)) #\>)
         (string->number (substring key 2 (fx- n 1)) 10))))

(define (%key-class key)
  (cond
    [(%named-key? key) 0]
    [(fx= (string-length key) 1) 1]
    [(%modified-key? key) 3]
    [else 2]))

;; F-keys by number, so <f10> follows <f2>, and keys that share their first
;; modifier by what follows it, so C-z comes before C-M-a, as in Emacs's
;; which-key.
(define (%key<? a b)
  (let ([ca (%key-class a)] [cb (%key-class b)])
    (cond
      [(not (fx= ca cb)) (fx< ca cb)]
      [(fx= ca 2)
       (let ([fa (%function-key-number a)] [fb (%function-key-number b)])
         (cond
           [(and fa fb) (< fa fb)]
           [(or fa fb) (and fa #t)]
           [else (string<? a b)]))]
      [(and (fx= ca 3) (string=? (substring a 0 2) (substring b 0 2)))
       (%key<? (substring a 2 (string-length a)) (substring b 2 (string-length b)))]
      [else (string<? a b)])))

(define (%following client keys)
  (let ([start (string-append keys " ")] [found (make-hashtable string-hash string=?)])
    (for-each
      (lambda (decided)
        (for-each
          (lambda (binding)
            (let ([rest (%after start (car binding))])
              (when rest
                (let ([key (%first-key rest)])
                  (unless (hashtable-contains? found key)
                    (hashtable-set! found key (and (string=? key rest) (cdr binding))))))))
          (cdr decided)))
      (keys:active-bindings client))
    (let-values ([(following commands) (hashtable-entries found)])
      (list-sort (lambda (a b) (%key<? (car a) (car b)))
                 (map cons (vector->list following) (vector->list commands))))))

(define (%label client prefix)
  (let ([label (tables:ref labels prefix #f)])
    (cond
      [(string? label) label]
      [label (assertion-violation 'which-key:labels "not a string" label)]
      [else
       (or (let ([keymap (keys:lookup client prefix)])
             (and (tables:table? keymap)
                  (not (memq keymap (keys:active-keymaps client)))
                  (tables:documentation keymap)))
           "prefix")])))

(define-record-type (%entry %make-entry %entry?)
  (sealed #t)
  (fields (immutable key %entry-key) (immutable text %entry-text) (immutable label? %entry-label?)))

(define (%entry-of client keys following)
  (let ([key (car following)] [command (cdr following)])
    (if command
        (%make-entry key (symbol->string (commands:command-name command)) #f)
        (%make-entry key (string-append "+" (%label client (string-append keys " " key))) #t))))

(define (%draw-entry e)
  (let ([key (%entry-key e)])
    (if (%mouse-key? key)
        (haml (:li (:span.which-key-entry (:kbd key) (%draw-text e))))
        (haml (:li (:button.which-key-entry ([type "button"] [tabindex "-1"] [data-key key]) (:kbd key) (%draw-text e)))))))

(define (%draw-text e)
  (if (%entry-label? e)
      (haml (:span.which-key-text.which-key-label (%entry-text e)))
      (haml (:span.which-key-text (%entry-text e)))))

(define (%longest strings)
  (fold-left (lambda (n s) (fxmax n (string-length s))) 0 strings))

(define (%popup client)
  (let ([keys (keys:pending client)] [w (eq-hashtable-ref %clients client #f)])
    (if (and keys w (%waiting-ready w) (%extends? keys (%waiting-ready w))
             (tables:table? (keys:lookup client keys)))
        (let ([entries (map (lambda (f) (%entry-of client keys f)) (%following client keys))])
          (if (null? entries)
              '()
              (haml
                (:div.which-key
                  ([style "--which-key-key-size:" (%longest (map %entry-key entries))
                          ";--which-key-text-size:" (%longest (map %entry-text entries))])
                  (:header.which-key-prefix (:kbd keys))
                  (:ul.which-key-keys (map %draw-entry entries))))))
        '())))

;; The wrapper is drawn even with no popup, so showing or hiding one
;; morphs only the popup.
(define (%add-popup screen client)
  (haml (:div.which-key-screen (screen client) (%popup client))))

(tables:set! web:stylesheets 'which-key "which-key/which-key.css")
(advice-add! keys:press! %follow-keys)
(advice-add! layout:screen %add-popup)
(hooks:add! web:client-removed %forget-client!)
