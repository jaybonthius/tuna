(import (chezscheme) (tuna test) (tuna version))

(test "the version is a dotted triple of numbers"
  (let ([parts (let split ([chars (string->list tuna-version)] [part '()])
                 (cond
                   [(null? chars) (list (list->string (reverse part)))]
                   [(char=? (car chars) #\.)
                    (cons (list->string (reverse part)) (split (cdr chars) '()))]
                   [else (split (cdr chars) (cons (car chars) part))]))])
    (check-equal? 3 (length parts))
    (check (for-all string->number parts))))

(test-exit)
