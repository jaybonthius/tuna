#!tuna
(import (web))

(define (%prefix-ci? prefix s)
  (let ([n (string-length prefix)])
    (and (fx<= n (string-length s)) (string-ci=? prefix (substring s 0 n)))))

(define open
  (case-lambda
    [(url) (open url (web:current-client))]
    [(url client)
     (unless (and (string? url) (exists (lambda (scheme) (%prefix-ci? scheme url)) '("http:" "https:" "mailto:")))
       (assertion-violation 'browse-url:open "not an http, https or mailto address" url))
     (unless client
       (assertion-violation 'browse-url:open "no browser to open it in" url))
     (unless (web:client? client)
       (assertion-violation 'browse-url:open "not a client" client))
     (web:call-page! client "browse-url" url)]))

;; A browser may open a tab only soon after the user's click or key, and
;; Safari and Firefox count the round trip to Tuna as too late.
(define (%blocked client item)
  (let ([url (cdr (or (assoc "url" item) '(#f . #f)))])
    (unless (string? url)
      (assertion-violation 'browse-url "not a browse-url item" item))
    (raise-continuable
      (condition (make-warning)
        (make-message-condition (format "The browser blocked the new tab for ~a" url))))))

(table-set! web:scripts 'browse-url "browse-url/browse-url.js")
(table-set! web:input-handlers "browse-url" %blocked)
