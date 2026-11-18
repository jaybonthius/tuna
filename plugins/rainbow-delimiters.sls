#!tuna
(import (syntax) (buffers) (views) (modes) (web))

(define-option mode #f boolean?
  "Whether brackets are coloured by depth."
  (lambda (on?) (syntax:bracket-users-changed)))

(define-option outermost-only-face-count 0 (lambda (v) (and (fixnum? v) (fx<= 0 v 8)))
  "How many of the outermost depths keep their face for themselves: past depth 9 the faces start again after them.")

(define (%bracket-face bracket)
  (cond
    [(eq? bracket 'unmatched) "rainbow-delimiters.unmatched"]
    [(eq? bracket 'mismatched) "rainbow-delimiters.mismatched"]
    [(and (fixnum? bracket) (fx> bracket 0))
     (string-append "rainbow-delimiters.depth-"
       (number->string
         (if (fx<= bracket 9)
             bracket
             (let ([kept (outermost-only-face-count)])
               (fx+ 1 kept (fxmod (fx- bracket 10) (fx- 9 kept)))))))]
    [else #f]))

(define (%bracket-attributes bracket)
  (let ([face (and (mode) (%bracket-face bracket))])
    (if face (list (cons "data-face" face)) '())))

(define (%draws-brackets? buffer)
  (buffers:with-buffer buffer (mode)))

(table-set! modes:minor-modes mode 0)
(table-set! syntax:bracket-users 'rainbow-delimiters %draws-brackets?)
(table-set! views:span-properties 'bracket %bracket-attributes)
(table-set! web:stylesheets 'rainbow-delimiters "rainbow-delimiters/rainbow-delimiters.css")
(syntax:bracket-users-changed)
;; Unload actions run before the plugin's table entries are taken back,
;; so the hook would still find this entry.
(on-unload
  (lambda ()
    (table-remove! syntax:bracket-users 'rainbow-delimiters)
    (syntax:bracket-users-changed)))
