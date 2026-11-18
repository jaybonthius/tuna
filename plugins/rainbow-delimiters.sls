#!tuna
(import (syntax) (buffers) (views) (modes) (web))

(define-option mode #f boolean?
  "Whether brackets are coloured by depth."
  (lambda (on?) (syntax:bracket-users-changed)))

;; Past the ninth depth the faces start again at depth-2, so depth-1 marks
;; only the outermost list.
(define (%bracket-face bracket)
  (cond
    [(eq? bracket 'unmatched) "rainbow-delimiters.unmatched"]
    [(eq? bracket 'mismatched) "rainbow-delimiters.mismatched"]
    [(and (fixnum? bracket) (fx> bracket 0))
     (string-append "rainbow-delimiters.depth-"
       (number->string (if (fx<= bracket 9) bracket (fx+ 2 (fxmod (fx- bracket 2) 8)))))]
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
