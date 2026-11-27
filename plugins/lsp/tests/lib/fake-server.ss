(define-values (libraries config record) (apply values (command-line-arguments)))

(library-directories
  (map (lambda (id)
         (cons (string-append libraries "/" id "/src") (string-append libraries "/" id "/build/obj/src")))
       '("chez-json-rpc" "chez-json")))

(import (json-rpc framing) (json-rpc) (json))

(define in (standard-input-port))
(define out (standard-output-port))

(define (send! message)
  (put-bytevector out (body->frame (json-rpc-message->bytevector message)))
  (flush-output-port out))

(define (note! text)
  (call-with-port (open-file-output-port record (file-options no-fail no-truncate append)
                    (buffer-mode block) (native-transcoder))
    (lambda (p) (put-string p text) (newline p))))

(define (settings)
  (if (file-exists? config) (call-with-input-file config read) '()))

(define (setting key default)
  (let ([e (assq key (settings))]) (if e (cdr e) default)))

(define (ref object key)
  (let ([pair (and (list? object) (assoc key object))]) (and pair (cdr pair))))

(define (read-message)
  (let ([body (read-frame in)])
    (and (not (eof-object? body))
         (begin
           (note! (utf8->string body))
           (bytevector->json-rpc-message body)))))

(define (answer! id method)
  (let ([found (assoc method (setting 'responses '()))])
    (let ([result (if found (cdr found) 'null)])
      (if (and (pair? result) (eq? (car result) 'delay))
          (let ([s (cadr result)])
            (sleep (make-time 'time-duration (exact (floor (* 1000000000 (- s (floor s))))) (exact (floor s))))
            (send! (make-json-rpc-response id (caddr result))))
          (send! (make-json-rpc-response id result))))))

(define (send-after! method)
  (let ([found (assoc method (setting 'after '()))])
    (when found
      (for-each (lambda (m) (send! (json->json-rpc-message m))) (cdr found)))))

(define (act! m)
  (cond
    [(json-rpc-request? m)
     (let ([id (json-rpc-request-id m)] [method (json-rpc-request-method m)])
       (cond
         [(string=? method "initialize")
          (send! (make-json-rpc-response id
                   (list (cons "capabilities" (setting 'capabilities '()))
                         (cons "serverInfo" (list (cons "name" (setting 'name "fake")))))))]
         [else (answer! id method)])
       (send-after! method))]
    [(json-rpc-notification? m)
     (let ([method (json-rpc-notification-method m)] [params (json-rpc-notification-params m)])
       (cond
         [(string=? method "exit") (exit 0)]
         [(string=? method "fake/send") (send! (json->json-rpc-message (ref params "message")))]
         [(string=? method "fake/crash") (exit 3)]
         [(string=? method "fake/stderr")
          (put-string (current-error-port) (string-append (ref params "line") "\n"))
          (flush-output-port (current-error-port))]
         [else (send-after! method)]))]
    [else (void)]))

(let loop ()
  (let ([m (read-message)])
    (when m
      (act! m)
      (loop))))
