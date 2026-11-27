#!tuna
(import (design-tokens-test css) (design-tokens-test colours))

(define text (design-tokens-test/css:file-text "design-tokens/design-tokens.css"))

(define %rules (design-tokens-test/css:rules text))

(define (%root-in layer?)
  (let ([r (find (lambda (r) (and (layer? (design-tokens-test/css:rule-layer r)) (string=? ":root" (design-tokens-test/css:rule-selector r)))) %rules)])
    (filter (lambda (d) (design-tokens-test/css:prefix? "--" (car d))) (design-tokens-test/css:rule-declarations r))))

(define tokens (%root-in (lambda (layer) (string=? layer "defaults"))))

(define reduced (%root-in (lambda (layer) (design-tokens-test/css:prefix? "preferences @media (prefers-reduced-motion: reduce)" layer))))

(define (token name) (cdr (assoc (string-append "--tuna-" name) tokens)))

(define (declared? name) (and (assoc name tokens) #t))

(define semantic-names
  '("surface" "surface-subtle" "surface-raised" "chrome" "text" "text-muted" "text-faint"
    "bar" "on-bar" "bar-inactive" "on-bar-inactive" "border" "border-strong" "focus"
    "accent" "on-accent" "link" "hover" "pressed" "selected" "on-selected" "control"
    "cursor" "region" "line-current" "match" "match-other"
    "error" "error-surface" "warning" "warning-surface" "success" "success-surface" "info" "info-surface"
    "added" "added-surface" "removed" "removed-surface" "changed" "changed-surface"
    "font-ui" "font-code" "font-size-ui" "font-size-code" "line-height-code"
    "control-radius" "panel-radius" "border-width" "focus-width" "shadow-raised" "bar-size" "control-size"
    "duration" "ease"))

(define (%semantic? name) (member (substring name 7 (string-length name)) semantic-names))

(define primitives (filter (lambda (d) (not (%semantic? (car d)))) tokens))

(define colour-primitives
  (filter (lambda (d)
            (and (or (design-tokens-test/css:prefix? "light-dark(oklch(" (cdr d)) (design-tokens-test/css:prefix? "oklch(" (cdr d)))
                 (not (string=? (car d) "--tuna-shadow-color"))))
          primitives))

(define (%named-primitive value)
  (and (design-tokens-test/css:prefix? "var(--tuna-" value)
       (let ([name (substring value 4 (- (string-length value) 1))])
         (and (assoc name primitives) (substring name 7 (string-length name))))))

(define (primitive-of name)
  (or (and (member name semantic-names) (%named-primitive (token name))) name))

(define (colour name mode)
  (let ([value (token name)])
    (if (design-tokens-test/css:prefix? "color-mix(" value)
        (let* ([mixed (car (car (design-tokens-test/css:references value)))]
               [percent (let* ([close (design-tokens-test/css:search value ") " 0)] [end (design-tokens-test/css:search value "%" close)])
                          (string->number (design-tokens-test/css:trim (substring value (+ close 2) end))))])
          (design-tokens-test/colours:overlay (colour (substring mixed 7 (string-length mixed)) mode) (/ percent 100.0)
                           (colour (primitive-of "surface") mode)))
        (let ([vs (design-tokens-test/colours:oklch-values value)])
          (apply design-tokens-test/colours:oklch->linear (if (and (eq? mode 'dark) (pair? (cdr vs))) (cadr vs) (car vs)))))))

(define (token-contrast fg bg mode)
  (design-tokens-test/colours:contrast (colour (primitive-of fg) mode) (colour (primitive-of bg) mode)))

;; Faint text is meant for the page alone, where a pair of its own checks
;; it.
(define face-colours
  (let loop ([rules (filter (lambda (r) (string=? "defaults.faces" (design-tokens-test/css:rule-layer r))) (design-tokens-test/css:file-rules "faces/faces.css"))] [acc '()])
    (if (null? rules)
        (reverse acc)
        (let* ([chain (let ([v (design-tokens-test/css:declaration (car rules) "color")]) (if v (design-tokens-test/css:var-chain v) '()))]
               [last (and (pair? chain) (car (last-pair chain)))]
               [name (and last (design-tokens-test/css:prefix? "--tuna-" last) (substring last 7 (string-length last)))])
          (loop (cdr rules) (if (and name (not (member name acc)) (not (string=? name "text-faint"))) (cons name acc) acc))))))

(define pairs
  (append
    (map (lambda (bg) (list "text" bg 7)) '("surface" "surface-subtle" "surface-raised" "hover" "line-current" "region"))
    (apply append
      (map (lambda (fg) (map (lambda (bg) (list fg bg 4.5)) '("surface" "surface-subtle" "line-current" "region")))
           (append '("text-muted" "link") face-colours)))
    (map (lambda (p) (list (car p) (cdr p) 4.5))
         '(("on-bar" . "bar") ("on-bar-inactive" . "bar-inactive") ("on-accent" . "accent") ("on-selected" . "selected")
           ("text" . "control") ("text" . "match") ("text" . "match-other")))
    (apply append
      (map (lambda (s) (list (list s "surface" 4.5) (list s (string-append s "-surface") 4.5)))
           '("error" "warning" "success" "info" "added" "removed" "changed")))
    '(("text" "chrome" 7) ("text-faint" "surface" 4.5) ("focus" "surface" 3) ("focus" "bar" 3) ("focus" "bar-inactive" 3)
      ("cursor" "surface" 3))))
