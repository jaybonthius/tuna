#!tuna
;; Kept on the property list, which outlives the module's instances.
(define (shout name) (putprop 'entries 'shouted (cons name (getprop 'entries 'shouted '()))))

(define (wrap text name) (string-append "[" (text name) "]"))

(define (noted option value) (putprop 'entries 'noted (cons value (getprop 'entries 'noted '()))))
