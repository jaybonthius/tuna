#!tuna
(import (keys) (commands))

;; One record serves every client, so only the setting bounds it, not a
;; with-options binding or a buffer's local value; on-change is called for
;; a local value's change too, in that value's scope.
(define-option size 300 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many keys and commands the record keeps, counted alike; older ones go."
  (lambda (kept) (unless (current-scope) (set! %record (%newest %record kept)))))

;; A fresh list at each change, rather than a ring changed in place, so
;; a reader on any thread sees a whole record.
(define %record '())

(define (%newest record n)
  (if (fx> (length record) n) (list-head record n) record))

(define (%record! entry)
  (set! %record (cons entry (%newest %record (fx- (option-setting size) 1)))))

(define (recent-keys) (reverse %record))

(define %mouse-movement "<mouse-movement>")

(define (%mouse-movement? key)
  (let ([start (fx- (string-length key) (string-length %mouse-movement))])
    (and (fx>= start 0)
         (string=? (substring key start (string-length key)) %mouse-movement))))

(define (%record-key press client key)
  (let ([name (if (pair? key) (car key) key)])
    (when (and (string? name) (not (%mouse-movement? name)))
      (%record! name)))
  (press client key))

;; By name, since a command's procedure cannot be named once its module
;; has unloaded.
(define (%record-command command)
  (%record! (commands:command-name command)))

(advice-add! keys:press! %record-key)
(add-hook! commands:before-command %record-command)
