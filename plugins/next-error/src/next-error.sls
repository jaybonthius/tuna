#!tuna
(import (buffers) (ask))

(define (tell-locus buffer n)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'next-error:tell-locus "not a buffer" buffer))
  (unless (fixnum? n)
    (assertion-violation 'next-error:tell-locus "not a count" n))
  (ask:message
    (string-append (cond [(fx> n 0) "Next"] [(fx< n 0) "Previous"] [else "Current"])
                   " locus from " (buffers:name buffer))))
