#!tuna
(import (files) (hooks) (options))

(options:define-option language "en" string? "Dictionary used for checking.")

(define (dictionary-path)
  "The file of words for the current language."
  (string-append "/usr/share/dict/" (language)))

(define (check path)
  "Reports misspelt words in the file at a path."
  (display (string-append "checking " path " against " (dictionary-path))))

(hooks:add! files:after-save check)
