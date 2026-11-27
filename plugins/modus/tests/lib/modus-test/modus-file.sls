#!tuna
(import (design-tokens-test css) (design-tokens-test colours) (design-tokens-test token-file))

(define text (design-tokens-test/css:file-text "modus/modus.css"))

(define declarations
  (design-tokens-test/css:rule-declarations
    (find (lambda (r) (and (string=? "themes" (design-tokens-test/css:rule-layer r)) (string=? ":root" (design-tokens-test/css:rule-selector r)))) (design-tokens-test/css:rules text))))

(define colours (filter (lambda (d) (design-tokens-test/css:prefix? "--modus-" (car d))) declarations))

(define mapping (filter (lambda (d) (not (design-tokens-test/css:prefix? "--modus-" (car d)))) declarations))

(define (declares? name) (and (assoc name declarations) #t))

(define (%pair name) (design-tokens-test/colours:hex-colours (cdr (assoc name colours))))

(define (colour-of token mode)
  (let ([pair (%pair (car (car (design-tokens-test/css:references (cdr (assoc token mapping))))))])
    (string-append "#" (if (eq? mode 'dark) (cadr pair) (car pair)))))

(define (%linear name mode)
  (let ([pair (%pair name)]) (design-tokens-test/colours:hex->linear (if (eq? mode 'dark) (cadr pair) (car pair)))))

(define (theme-contrast fg bg)
  (map (lambda (mode)
         (design-tokens-test/colours:rounded (design-tokens-test/colours:contrast (%linear (car (car (design-tokens-test/css:references (cdr (assoc (string-append "--tuna-" fg) mapping))))) mode)
                                            (%linear (car (car (design-tokens-test/css:references (cdr (assoc (string-append "--tuna-" bg) mapping))))) mode))))
       '(light dark)))

(define (palette-contrast fg bg)
  (map (lambda (mode)
         (design-tokens-test/colours:rounded (design-tokens-test/colours:contrast (%linear (string-append "--modus-" fg) mode) (%linear (string-append "--modus-" bg) mode))))
       '(light dark)))

(define (attributes suffix) (filter (lambda (d) (design-tokens-test/css:suffix? suffix (car d))) mapping))
