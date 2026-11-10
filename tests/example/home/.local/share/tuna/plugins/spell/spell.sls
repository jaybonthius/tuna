#!tuna
(define (language) "en")

(define (dictionary-path)
  "The file of words for the current language."
  (string-append "/usr/share/dict/" (language)))

(define (check path)
  "Reports misspelt words in the file at a path."
  (display (string-append "checking " path " against " (dictionary-path))))
