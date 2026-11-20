(define-values (libraries record) (apply values (command-line-arguments)))

(library-directories
  (map (lambda (id)
         (cons (string-append libraries "/" id "/src") (string-append libraries "/" id "/build/obj/src")))
       '("chez-json-rpc" "chez-json")))

(import (json-rpc framing) (json-rpc) (json))

(define in (standard-input-port))
(define out (standard-output-port))
(define err (standard-error-port))

(define (write-bytes! bytes)
  (put-bytevector out bytes)
  (flush-output-port out))

(define (send! message)
  (write-bytes! (body->frame (json-rpc-message->bytevector message))))

(define (note! text)
  (call-with-port (open-file-output-port record (file-options no-fail no-truncate append)
                    (buffer-mode block) (native-transcoder))
    (lambda (p) (put-string p text) (newline p))))

(define (ref object key)
  (let ([pair (and (list? object) (assoc key object))]) (and pair (cdr pair))))

(define (read-message)
  (let ([body (read-frame in)])
    (and (not (eof-object? body))
         (begin
           (note! (utf8->string body))
           (bytevector->json-rpc-message body)))))

;; Requests the program sends wait for their answers here, so other
;; messages read meanwhile are acted on in turn.
(define (answer-of id)
  (let ([m (read-message)])
    (cond
      [(not m) #f]
      [(and (json-rpc-response? m) (equal? (json-rpc-response-id m) id)) m]
      [else (act! m) (answer-of id)])))

(define asked 0)

(define (act! m)
  (when (json-rpc-request? m)
    (let ([id (json-rpc-request-id m)] [params (json-rpc-request-params m)])
      (define (answer! result) (send! (make-json-rpc-response id result)))
      (case (string->symbol (json-rpc-request-method m))
        [(echo) (answer! params)]
        [(fail)
         (send! (make-json-rpc-error-response id
                  (make-json-rpc-error (ref params "code") (ref params "message") (or (ref params "data") 'null))))]
        [(wait) (void)]
        [(big)
         (answer! (make-string (ref params "size") #\x))
         (note! (format "sent ~a" (let ([t (current-time 'time-utc)])
                                    (+ (* (time-second t) 1000000000) (time-nanosecond t)))))]
        [(raw)
         (for-each (lambda (s) (write-bytes! (string->utf8 s))) (vector->list (ref params "texts")))
         (answer! "written")]
        [(stderr)
         (put-bytevector err (string->utf8 (ref params "text")))
         (flush-output-port err)
         (answer! "written")]
        [(notify)
         (for-each (lambda (method) (send! (make-json-rpc-notification method '(("n" . 1)))))
                   (vector->list (ref params "methods")))
         (answer! "sent")]
        [(ask)
         (set! asked (+ asked 1))
         (let ([mine (string-append "server-" (number->string asked))])
           (send! (make-json-rpc-request mine (ref params "method") (or (ref params "params") 'null)))
           (let ([reply (answer-of mine)])
             (answer!
               (cond
                 [(not reply) 'null]
                 [(json-rpc-response-error reply)
                  => (lambda (e) (list (cons "error" (json-rpc-error-code e)) (cons "message" (condition-message e))))]
                 [else (list (cons "result" (json-rpc-response-result reply)))]))))]
        [(exit) (exit (ref params "status"))]
        [else
         (send! (make-json-rpc-error-response id
                  (make-json-rpc-error json-rpc-method-not-found-code "no such method")))]))))

(let loop ()
  (let ([m (read-message)])
    (when m
      (act! m)
      (loop))))
