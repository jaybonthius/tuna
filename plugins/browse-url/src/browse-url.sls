#!tuna
(import (web) (commands) (ask) (buffers) (document) (views) (tables))

(define %schemes '("http:" "https:" "mailto:"))

(define (%prefix-ci-at? prefix s start)
  (let ([n (string-length prefix)])
    (and (fx<= (fx+ start n) (string-length s)) (string-ci=? prefix (substring s start (fx+ start n))))))

(define (%offered-url)
  (let* ([v (views:current)] [b (and v (views:buffer v))])
    (and b
         (let ([doc (buffers:document b)] [p (views:point v)] [m (views:mark v)])
           (if (and m (not (fx= m p)))
               (document:text doc (fxmin m p) (fxmax m p))
               (let-values ([(start end) (url-at b p)])
                 (and start (document:text doc start end))))))))

(commands:define-command (open [url (ask:line "URL: " (%offered-url))] [client (web:current-client)])
  "Opens URL, an http, https or mailto address, in a new tab of CLIENT's browser; asked for, it offers the region's text, else the address at point."
  (unless (string? url)
    (assertion-violation 'browse-url:open "not a string" url))
  ;; The text may be anyone's, as a program's output in a terminal is, and
  ;; a file: address would show the user's files, a javascript: one run
  ;; script.
  (unless (exists (lambda (scheme) (%prefix-ci-at? scheme url 0)) %schemes)
    (error 'browse-url:open "Only http, https and mailto addresses open"))
  (unless client
    (assertion-violation 'browse-url:open "no browser to open it in" url))
  (unless (web:client? client)
    (assertion-violation 'browse-url:open "not a client" client))
  (web:call-page! client "browse-url" url))

;; A URL ends where Emacs's thing-at-point-url-path-regexp ends it. In
;; prose a URL is often followed by punctuation, or closed by a bracket
;; that opened before it, which are not part of it.
(define (%url-char? c)
  (and (char? c) (not (char-whitespace? c)) (not (memv c '(#\" #\' #\< #\> #\[ #\] #\^ #\` #\{ #\} #\|)))))

(define (url-at buffer position)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'browse-url:url-at "not a buffer" buffer))
  (let* ([doc (buffers:document buffer)] [n (document:length doc)])
    (unless (and (fixnum? position) (fx<= 0 position n))
      (assertion-violation 'browse-url:url-at "not a position in the buffer" position))
    (let* ([run-start (let loop ([p position]) (if (and (fx> p 0) (%url-char? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p))]
           [run-end (let loop ([p position]) (if (and (fx< p n) (%url-char? (document:token doc p))) (loop (fx+ p 1)) p))]
           [run (document:text doc run-start run-end)]
           [at (fx- position run-start)]
           [start (let loop ([i at])
                    (cond
                      [(fx< i 0) #f]
                      [(exists (lambda (scheme) (%prefix-ci-at? scheme run i)) %schemes) i]
                      [else (loop (fx- i 1))]))])
      (if start
          (let* ([opened? (exists (lambda (c) (char=? c #\()) (string->list (substring run start (string-length run))))]
                 [end (let loop ([e (string-length run)])
                        (if (and (fx> e start)
                                 (or (memv (string-ref run (fx- e 1)) '(#\. #\, #\; #\: #\! #\?))
                                     (and (char=? (string-ref run (fx- e 1)) #\)) (not opened?))))
                            (loop (fx- e 1))
                            e))])
            (if (and (fx<= start at) (fx<= at end)
                     (not (exists (lambda (scheme) (string-ci=? scheme (substring run start end))) %schemes)))
                (values (fx+ run-start start) (fx+ run-start end))
                (values #f #f)))
          (values #f #f)))))

;; A browser may open a tab only soon after the user's click or key, and
;; Safari and Firefox count the round trip to Tuna as too late.
(define (%blocked client item)
  (let ([url (cdr (or (assoc "url" item) '(#f . #f)))])
    (unless (string? url)
      (assertion-violation 'browse-url "not a browse-url item" item))
    (raise-continuable
      (condition (make-warning)
        (make-message-condition (format "The browser blocked the new tab for ~a" url))))))

(tables:set! web:scripts 'browse-url "browse-url/browse-url.js")
(tables:set! web:input-handlers "browse-url" %blocked)
