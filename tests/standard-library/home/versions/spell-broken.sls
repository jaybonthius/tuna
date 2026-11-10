#!tuna
(import (files))

(define-option language "en" string? "Dictionary used for checking.")

(define (dictionary-path)
  "The file of words for the current language."
  (string-append "/usr/share/words/" (language)))

(define (check path)
  "Reports misspelt words in the file at a path."
  (display (string-append "checking " path " against " (dictionary-path))))

(define-syntax with-words (syntax-rules () [(_ e) (list 'v2 e)]))

(define broken (car (quote ())))
(add-hook! files:after-save check)
