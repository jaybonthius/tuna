#!tuna
(import (buffers) (document) (views) (commands) (web))

(define-option duration 0.5 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds a mark stays, unless the next command ends it first.")

(define highlight 'pulse.highlight)

;; Keyed by the view, so the place is marked where the user went and a
;; buffer's other views show nothing. Below lsp's highlights (5) and a
;; picker's preview (10), whose line and matches come with a jump too, so
;; they show over the mark.
(buffers:define-layer %marks (priority 1))

(define %current #f)

(define (%end!)
  (let ([c %current])
    (set! %current #f)
    (when c
      (cancel-timer! (caddr c))
      (when (buffers:live? (car c))
        (buffers:set-spans! (cadr c) 0 (document:length (buffers:document (car c))) '())))))

(define (%range? r n)
  (and (list? r) (fx= (length r) 2) (fixnum? (car r)) (fixnum? (cadr r)) (fx<= 0 (car r) (cadr r) n)))

(define (highlight! view ranges)
  (unless (views:view? view)
    (assertion-violation 'pulse:highlight! "not a view" view))
  (let ([b (views:buffer view)])
    (unless b
      (assertion-violation 'pulse:highlight! "the view shows no buffer" view))
    (let ([n (document:length (buffers:document b))])
      (unless (and (list? ranges) (for-all (lambda (r) (%range? r n)) ranges))
        (assertion-violation 'pulse:highlight! "not a list of ranges of the view's buffer" ranges)))
    (%end!)
    (let ([ranges (filter (lambda (r) (fx< (car r) (cadr r))) ranges)])
      (unless (null? ranges)
        (let ([layer (buffers:layer b %marks view)] [value `((face . ,highlight) (pulse . ,(duration)))])
          (for-each (lambda (r) (buffers:add-span! layer (car r) (cadr r) value)) ranges)
          (letrec ([entry (list b layer (as-module (this-module) (run-with-timer (duration) (lambda () (when (eq? %current entry) (%end!))))))])
            (set! %current entry)))))))

;; A line with nothing past its indentation has no text to mark, so it is
;; marked from its start through its line break, as Emacs's
;; xref-pulse-momentarily does.
(define (line-ranges view)
  (unless (views:view? view)
    (assertion-violation 'pulse:line-ranges "not a view" view))
  (let ([b (views:buffer view)])
    (if (not b)
        '()
        (let* ([doc (buffers:document b)] [n (document:length doc)]
               [line-start (document:line-start doc (document:line doc (views:point view)))]
               [start (or (buffers:stop b line-start) line-start)]
               [token (lambda (p) (and (fx< p n) (document:token doc p)))]
               [indented (let loop ([p start]) (if (memv (token p) '(#\space #\tab)) (loop (fx+ p 1)) p))]
               [end (let loop ([p indented]) (let ([t (token p)]) (if (and (char? t) (not (char=? t #\newline))) (loop (fx+ p 1)) p)))])
          (cond
            [(fx< indented end) (list (list indented end))]
            [(eqv? (token end) #\newline) (list (list start (fx+ end 1)))]
            [(fx< start end) (list (list start end))]
            [else '()])))))

(define (highlight-line! view) (highlight! view (line-ranges view)))

;; The fade lasts as long as the mark, whatever pulse:duration is.
(define (%attributes seconds)
  (list (cons "style" (format "--pulse-duration: ~as" (exact->inexact seconds)))))

(table-set! views:span-properties 'pulse %attributes)
(add-hook! commands:before-command (lambda (command) (%end!)))
(table-set! web:stylesheets 'pulse "pulse/pulse.css")
