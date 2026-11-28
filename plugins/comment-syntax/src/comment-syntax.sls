#!tuna
(import (buffers) (languages) (modes) (options))

(options:define-option start #f (lambda (v) (or (not v) (and (string? v) (fx> (string-length v) 0))))
  "The text that starts a comment the commands write, such as \";\"; #f for the language's first line comment, else the start of its first block comment.")

(options:define-option end #f (lambda (v) (or (not v) (string? v)))
  "The text that ends such a comment, empty for a comment that the end of its line ends; #f for the end of the language's block comment whose start is written, else empty.")

(options:define-option add 0 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many more times a one-character comment-syntax:start is written at the start of a comment alone on its line.")

(options:define-option column 32 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "The column of a comment after the code on its line.")

;; As Emacs's comment-normalize-vars, every command reads the two texts
;; through here, so a local value and the language's facts agree.
(define (delimiters buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'comment-syntax:delimiters "not a buffer" buffer))
  (let* ([language (languages:of (modes:major-mode buffer))]
         [lines (if language (languages:line-comments-of language) '())]
         [blocks (if language (languages:block-comments-of language) '())]
         [start (or (buffers:with-buffer buffer (start))
                    (and (pair? lines) (languages:delimiter-start (car lines)))
                    (and (pair? blocks) (languages:delimiter-start (car blocks))))])
    (values start
            (or (buffers:with-buffer buffer (end))
                (let ([block (find (lambda (d) (equal? (languages:delimiter-start d) start)) blocks)])
                  (if block (languages:delimiter-end block) ""))))))
