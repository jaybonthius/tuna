#!tuna
(import (commands) (keys) (web) (echo-area))

;; A quit can cut a keymap's on-exit short, so each client's newest
;; repetition is ended through the procedure that ends it, which does
;; nothing once the keymap has ended.
(define %repetitions (make-ephemeron-eq-hashtable))

;; A click clears no message, so the hint, kept with the message it
;; followed, is taken back when its repetition ends rather than left for
;; the next typed key, and replaced rather than extended at the next
;; repeated click.
(define %shown #f)

(define (%last-key sequence)
  (let loop ([i (fx- (string-length sequence) 1)])
    (cond
      [(fx< i 0) #f]
      [(char=? (string-ref sequence i) #\space)
       (substring sequence (fx+ i 1) (string-length sequence))]
      [else (loop (fx- i 1))])))

(define (%keymap-for command key)
  (exists (lambda (entry)
            (let ([keymap (car entry)])
              (and (eq? (table-ref keymap key #f) command) keymap)))
          (table-entries keys:repeat-keymaps)))

;; Not logged, as in Emacs: it shows at every repeated key.
(define (%show! text face)
  (with-options ([echo-area:log-max 0])
    (parameterize ([echo-area:face face])
      (echo-area:message! "~a" text))))

(define (show-hint keymap)
  (unless (or (not keymap) (table? keymap))
    (assertion-violation 'repeat:show-hint "neither a keymap nor #f" keymap))
  (let* ([current (echo-area:current-message)]
         [ours? (and %shown current (string=? current (car %shown)))]
         [base (if ours? (cdr %shown) current)]
         [face (and base (echo-area:current-face))])
    (cond
      [keymap
       (let* ([hint (format "Repeat with ~{~a~^, ~}" (map car (keys:bindings keymap)))]
              [text (if base (format "~a [~a]" base hint) hint)])
         (%show! text face)
         (set! %shown (cons text base)))]
      [ours?
       (%show! (or base "") face)
       (set! %shown #f)])))

(define (%enter! client keymap)
  (let ([repetition (eq-hashtable-ref %repetitions client #f)])
    (when repetition ((cdr repetition))))
  (eq-hashtable-set! %repetitions client
    (cons keymap
          (keys:push-keymap! client keymap (lambda (found next) (eq? found keymap))
            (lambda () (show-hint #f)))))
  (show-hint keymap))

(define (%repeating-keymap client sequence command)
  (let ([repetition (eq-hashtable-ref %repetitions client #f)])
    (and repetition
         (eq? (table-ref (car repetition) sequence #f) command)
         (memq (car repetition) (keys:active-keymaps client))
         (car repetition))))

(define (%after-command command)
  (let ([sequence (keys:command-keys)] [client (web:current-client)])
    (when (and sequence client)
      (let* ([key (%last-key sequence)] [keymap (and key (%keymap-for command key))])
        (cond
          [keymap (%enter! client keymap)]
          [(%repeating-keymap client sequence command) => show-hint])))))

(add-hook! commands:after-command %after-command)
