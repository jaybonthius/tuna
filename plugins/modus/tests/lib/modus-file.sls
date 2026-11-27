#!tuna
(import (css) (colours) (token-file))

(define text (css:file-text "modus/modus.css"))

(define declarations
  (css:rule-declarations
    (find (lambda (r) (and (string=? "themes" (css:rule-layer r)) (string=? ":root" (css:rule-selector r)))) (css:rules text))))

(define colours (filter (lambda (d) (css:prefix? "--modus-" (car d))) declarations))

(define mapping (filter (lambda (d) (not (css:prefix? "--modus-" (car d)))) declarations))

(define (declares? name) (and (assoc name declarations) #t))

(define (%pair name) (colours:hex-colours (cdr (assoc name colours))))

(define (colour-of token mode)
  (let ([pair (%pair (car (car (css:references (cdr (assoc token mapping))))))])
    (string-append "#" (if (eq? mode 'dark) (cadr pair) (car pair)))))

(define (%linear name mode)
  (let ([pair (%pair name)]) (colours:hex->linear (if (eq? mode 'dark) (cadr pair) (car pair)))))

(define (theme-contrast fg bg)
  (map (lambda (mode)
         (colours:rounded (colours:contrast (%linear (car (car (css:references (cdr (assoc (string-append "--tuna-" fg) mapping))))) mode)
                                            (%linear (car (car (css:references (cdr (assoc (string-append "--tuna-" bg) mapping))))) mode))))
       '(light dark)))

(define (palette-contrast fg bg)
  (map (lambda (mode)
         (colours:rounded (colours:contrast (%linear (string-append "--modus-" fg) mode) (%linear (string-append "--modus-" bg) mode))))
       '(light dark)))

(define (attributes suffix) (filter (lambda (d) (css:suffix? suffix (car d))) mapping))
