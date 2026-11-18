#!tuna
(import (web) (layout) (keys) (commands) (editing) (kill-ring))

;; A paste puts its text on the kill ring, where this plugin would copy
;; it back to the computer's clipboard, which holds it already.
(define %pasted #f)

(define (%text item key)
  (let ([text (cdr (or (assoc key item) '(#f . #f)))])
    (unless (string? text)
      (assertion-violation 'clipboard "not a clipboard item" item))
    text))

(define (%paste client item)
  (let ([text (%text item "text")])
    (set! %pasted text)
    (layout:call-with-frame (layout:frame client)
      (lambda () (commands:run (or (keys:command-remapping client editing:paste) editing:paste) text)))))

(define (copy-to! client text)
  (unless (web:client? client)
    (assertion-violation 'clipboard:copy-to! "not a client" client))
  (unless (string? text)
    (assertion-violation 'clipboard:copy-to! "not a string" text))
  (web:call-page! client "copy" text))

(define (copy entry)
  (let ([text (kill-ring:text entry)] [client (web:current-client)])
    (cond
      [(equal? text %pasted) (set! %pasted #f)]
      [client (copy-to! client text)])))

;; A browser offers its clipboard only to a page served over HTTPS or
;; from localhost, and may refuse it when the page is not focused.
(define (%failed client item)
  (raise-continuable
    (condition (make-warning)
      (make-message-condition
        (if (equal? (cdr (or (assoc "outcome" item) '(#f . #f))) "unavailable")
            "Copy failed: the page has no clipboard, which needs HTTPS or localhost"
            (format "Copy failed: the browser refused the clipboard (~a)" (%text item "reason")))))))

(table-set! web:scripts 'clipboard "clipboard/clipboard.js")
(table-set! web:input-handlers "paste" %paste)
(table-set! web:input-handlers "clipboard" %failed)
(add-hook! kill-ring:after-push copy)
