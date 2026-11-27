#!tuna
(import (files) (buffers) (document) (views) (hooks) (options) (saved))

(define (%ends-with? s suffix)
  (let ([n (string-length s)] [k (string-length suffix)])
    (and (>= n k) (string=? (substring s (- n k) n) suffix))))

(define (%starts-with? s prefix)
  (let ([n (string-length s)] [k (string-length prefix)])
    (and (>= n k) (string=? (substring s 0 k) prefix))))

;; Version control tools have the user edit these and then delete them,
;; so a place in one is never wanted back.
(define (%version-control-file? path)
  (let ([name (path-last path)])
    (or (string=? name "COMMIT_EDITMSG")
        (string=? name "svn-commit.tmp")
        (and (%starts-with? name "hg-editor-") (%ends-with? name ".txt"))
        (%starts-with? name "bzr_log."))))

(options:define-option limit 400 (lambda (v) (or (not v) (and (fixnum? v) (fx>= v 0))))
  "How many files' places save-place keeps, the most recently left; #f keeps every one.")

(options:define-option ignored-file-predicate %version-control-file? procedure?
  "A procedure of a file's path that returns true for a file whose place save-place does not keep.")

(saved:define-saved places '()
  (lambda (v) (and (list? v) (for-all (lambda (p) (and (pair? p) (string? (car p)) (fixnum? (cdr p)) (fx>= (cdr p) 0))) v))))

(define (%keep-place! buffer)
  (let ([path (files:path buffer)])
    (when (and path (not ((ignored-file-predicate) path)))
      (let* ([point (views:last-point buffer)]
             [others (remp (lambda (place) (string=? (car place) path)) (places))]
             [kept (if (and point (> point 1)) (cons (cons path point) others) others)]
             [n (limit)])
        (saved:set! places (if (and n (> (length kept) n)) (list-head kept n) kept))))))

(define (%restore-place! buffer)
  (let* ([path (files:path buffer)] [place (and path (assoc path (places)))])
    (when (and place (not (views:last-point buffer)))
      (views:set-last-point! buffer (min (cdr place) (- (document:length (buffers:document buffer)) 1))))))

;; Views forget a killed buffer's last point in their own entry, so this
;; one runs first.
(hooks:add! buffers:killed %keep-place! -10)
(hooks:add! files:after-visit %restore-place!)
