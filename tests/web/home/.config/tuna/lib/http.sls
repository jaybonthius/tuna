#!tuna
(import (json))

;; The client works on threads of its own, since code on the main thread
;; must not wait on the network.
(module (request response-status response-header response-body open-page page-id
         page-connect! page-close! page-send! page-send-numbered! send-items page-send-all! page-send-range!
         page-confirm! page-goodbye! page-next page-events-closed? page-connect-and-next! heartbeats-seen
         wait-for-server occupy-port! target-port target-address source-address set-port-source! percent-encode-all
         flood auto-confirm)

  (define libc (load-shared-object "libc.so.6"))
  (define c-socket (foreign-procedure "socket" (int int int) int))
  (define c-connect (foreign-procedure __collect_safe "connect" (int u8* int) int))
  (define c-send (foreign-procedure __collect_safe "send" (int u8* size_t int) ssize_t))
  (define c-recv (foreign-procedure __collect_safe "recv" (int u8* size_t int) ssize_t))
  (define c-shutdown (foreign-procedure "shutdown" (int int) int))
  (define c-close (foreign-procedure "close" (int) int))

  ;; Waits on its own thread, so that the main thread goes on running
  ;; tasks; the value, or the raise, comes back in the task.
  (define (off-main-thread thunk)
    (suspend
      (lambda (resume)
        (fork-thread
          (lambda ()
            (resume (guard (e [#t (lambda () (raise e))])
                      (let ([v (thunk)]) (lambda () v)))))))))

  (define-record-type connection
    (fields fd buffer (mutable start) (mutable end)))

  (define target-port (make-thread-parameter #f))

  (define address-of
    (case-lambda
      [(port) (address-of "127.0.0.1" port)]
      [(host port)
       (let ([address (make-immobile-bytevector 16 0)])
         (bytevector-u16-native-set! address 0 2)
         (bytevector-u16-set! address 2 port (endianness big))
         (for-each (lambda (i part) (bytevector-u8-set! address (fx+ 4 i) (string->number part)))
                   '(0 1 2 3) (split host #\.))
         address)]))

  (define target-address (make-thread-parameter "127.0.0.1"))

  (define source-address (make-thread-parameter #f))

  (define c-bind (foreign-procedure "bind" (int u8* int) int))
  (define c-listen (foreign-procedure "listen" (int int) int))

  (define (occupy-port! port)
    (let ([fd (c-socket 2 1 0)])
      (unless (and (fx= 0 (c-bind fd (address-of port) 16)) (fx= 0 (c-listen fd 1)))
        (error 'http "cannot listen" port))
      fd))

  ;; Read on the calling thread, since a thread starts without its
  ;; creator's parameter bindings.
  (define (server-port) (or (target-port) (port-source)))

  (define port-source #f)

  (define (set-port-source! source) (set! port-source source))

  (define connect
    (case-lambda
      [(port) (connect port "127.0.0.1" #f)]
      [(port to from)
       (let ([fd (c-socket 2 1 0)])
         (unless (or (not from) (fx= 0 (c-bind fd (address-of from 0) 16)))
           (c-close fd)
           (error 'http "cannot bind" from))
         (connect-socket fd port to))]))

  (define (connect-socket fd port to)
    (let ([address (address-of to port)])
      (unless (fx= 0 (c-connect fd address 16))
        (c-close fd)
        (error 'http "cannot connect" port))
      (make-connection fd (make-immobile-bytevector 65536) 0 0)))

  ;; The bytes are copied to where the collector does not move them, since
  ;; send runs while collections go on.
  (define (send-all c bytes)
    (let loop ([at 0])
      (when (fx< at (bytevector-length bytes))
        (let ([chunk (make-immobile-bytevector (fx- (bytevector-length bytes) at))])
          (bytevector-copy! bytes at chunk 0 (bytevector-length chunk))
          (let ([n (c-send (connection-fd c) chunk (bytevector-length chunk) #x4000)])
            (cond
              [(fx> n 0) (loop (fx+ at n))]
              [(interrupted?) (loop at)]
              [else (error 'http "cannot send")]))))))

  (define errno-location (foreign-procedure "__errno_location" () uptr))

  (define (interrupted?) (fx= (foreign-ref 'int (errno-location) 0) 4))

  ;; A signal to the process can end a wait in recv early.
  (define (fill! c)
    (let ([n (let retry ()
               (let ([n (c-recv (connection-fd c) (connection-buffer c) (bytevector-length (connection-buffer c)) 0)])
                 (if (and (fx< n 0) (interrupted?)) (retry) n)))])
      (connection-start-set! c 0)
      (connection-end-set! c (fxmax n 0))
      (fx> n 0)))

  (define (read-u8 c)
    (if (or (fx< (connection-start c) (connection-end c)) (fill! c))
        (let ([b (bytevector-u8-ref (connection-buffer c) (connection-start c))])
          (connection-start-set! c (fx+ (connection-start c) 1))
          b)
        (eof-object)))

  (define (read-line c)
    (let loop ([bytes '()])
      (let ([b (read-u8 c)])
        (cond
          [(eof-object? b) (if (null? bytes) b (utf8->string (u8-list->bytevector (reverse bytes))))]
          [(fx= b 10)
           (utf8->string (u8-list->bytevector (reverse (if (and (pair? bytes) (fx= (car bytes) 13)) (cdr bytes) bytes))))]
          [else (loop (cons b bytes))]))))

  (define (read-bytes c n)
    (let ([out (make-bytevector n)])
      (let loop ([i 0])
        (if (fx= i n)
            out
            (let ([b (read-u8 c)])
              (if (eof-object? b)
                  (begin (bytevector-truncate! out i) out)
                  (begin (bytevector-u8-set! out i b) (loop (fx+ i 1)))))))))

  (define (read-head c)
    (let ([status-line (read-line c)])
      (if (eof-object? status-line)
          (values #f '())
          (let loop ([headers '()])
            (let ([line (read-line c)])
              (if (or (eof-object? line) (string=? line ""))
                  (values (string->number (substring status-line 9 12)) (reverse headers))
                  (let ([colon (let find ([i 0]) (if (char=? (string-ref line i) #\:) i (find (fx+ i 1))))])
                    (loop (cons (cons (string-downcase (substring line 0 colon))
                                      (string-trim (substring line (fx+ colon 1) (string-length line))))
                                headers)))))))))

  (define (string-trim s)
    (let loop ([i 0])
      (if (and (fx< i (string-length s)) (char=? (string-ref s i) #\space))
          (loop (fx+ i 1))
          (substring s i (string-length s)))))

  (define (header headers name)
    (let ([h (assoc name headers)])
      (and h (cdr h))))

  (define (read-chunks c each)
    (let loop ()
      (let ([line (read-line c)])
        (unless (eof-object? line)
          (let ([n (string->number (car (split line #\;)) 16)])
            (when (and n (fx> n 0))
              (each (read-bytes c n))
              (read-line c)
              (loop)))))))

  (define (split s char)
    (let loop ([i 0] [start 0] [parts '()])
      (cond
        [(fx= i (string-length s)) (reverse (cons (substring s start i) parts))]
        [(char=? (string-ref s i) char) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) parts))]
        [else (loop (fx+ i 1) start parts)])))

  (define (request-bytes port method path headers body)
    (request-bytes* port method path headers body #t))

  (define (request-bytes* port method path headers body close?)
    (let ([body (cond [(string? body) (string->utf8 body)] [body body] [else #vu8()])])
      (let-values ([(p extract) (open-bytevector-output-port)])
        (put-bytevector p (string->utf8
                            (string-append
                              method " " path " HTTP/1.1\r\n"
                              (if (assoc "host" headers) "" (format "host: 127.0.0.1:~a\r\n" port))
                              (apply string-append
                                (map (lambda (h) (string-append (car h) ": " (cdr h) "\r\n")) headers))
                              (format "content-length: ~a\r\n~a\r\n" (bytevector-length body)
                                (if close? "connection: close\r\n" "")))))
        (put-bytevector p body)
        (extract))))

  (define-record-type response
    (fields status headers body))

  (define (response-header r name) (header (response-headers r) name))

  ;; A whole response; for an event stream, what came before the server
  ;; ended it, since this client asks for no keep-alive.
  (define (request method path headers body)
    (let ([port (server-port)] [to (target-address)] [from (source-address)])
      (off-main-thread
        (lambda ()
          (let ([c (connect port to from)])
            (send-all c (request-bytes port method path headers body))
            (let-values ([(status response-headers) (read-head c)])
              (let ([body (cond
                            [(memv status '(204 304)) #vu8()]
                            [(equal? (header response-headers "transfer-encoding") "chunked")
                             (let-values ([(p extract) (open-bytevector-output-port)])
                               (read-chunks c (lambda (bytes) (put-bytevector p bytes)))
                               (extract))]
                            [(header response-headers "content-length")
                             => (lambda (n) (read-bytes c (string->number n)))]
                            [else (read-bytes c 0)])])
                (c-close (connection-fd c))
                (make-response status response-headers body))))))))

  (define (read-response-body c status response-headers)
    (cond
      [(memv status '(204 304)) #vu8()]
      [(header response-headers "content-length") => (lambda (n) (read-bytes c (string->number n)))]
      [else #vu8()]))

  (define (wait-for-server)
    (let loop ([tries 0])
      (unless (or (guard (e [#t #f]) (request "GET" "/web/tuna.js" '() #f) #t) (fx= tries 500))
        (sleep-for 0.01)
        (loop (fx+ tries 1)))))

  (define-record-type page
    (fields id (mutable seq) mutex arrived (mutable events) (mutable stream) (mutable closed?)
            (mutable heartbeats)))

  (define (open-page)
    (let* ([r (request "GET" "/" '() #f)]
           [text (utf8->string (response-body r))]
           [at (let find ([i 0])
                 (if (string=? (substring text i (fx+ i 21)) "data-signals:client=\"") i (find (fx+ i 1))))])
      (make-page (substring text (fx+ at 22) (fx+ at 54)) 0 (make-mutex) (make-condition) '() #f #f 0)))

  (define (signals page)
    (json->string (list (cons "client" (page-id page)))))

  (define (percent-encode-all s)
    (apply string-append
      (map (lambda (b) (format "%~2,'0x" b)) (bytevector->u8-list (string->utf8 s)))))

  (define (event-reader page)
    (let ([type #f] [data '()] [partial ""])
      (define (line! line)
        (cond
          [(string=? line "")
           (when type
             (with-mutex (page-mutex page)
               (page-events-set! page (append (page-events page) (list (cons type (reverse data)))))
               (condition-broadcast (page-arrived page))))
           (set! type #f)
           (set! data '())]
          [(char=? (string-ref line 0) #\:)
           (with-mutex (page-mutex page)
             (page-heartbeats-set! page (fx+ (page-heartbeats page) 1)))]
          [(and (fx>= (string-length line) 7) (string=? (substring line 0 7) "event: "))
           (set! type (substring line 7 (string-length line)))]
          [(and (fx>= (string-length line) 6) (string=? (substring line 0 6) "data: "))
           (let* ([rest (substring line 6 (string-length line))]
                  [space (let find ([i 0]) (cond [(fx= i (string-length rest)) i] [(char=? (string-ref rest i) #\space) i] [else (find (fx+ i 1))]))])
             (set! data (cons (cons (substring rest 0 space)
                                    (if (fx< space (string-length rest)) (substring rest (fx+ space 1) (string-length rest)) ""))
                              data)))]
          [else (void)]))
      (lambda (bytes)
        (let ([lines (split (string-append partial (utf8->string bytes)) #\newline)])
          (let loop ([lines lines])
            (if (null? (cdr lines))
                (set! partial (car lines))
                (begin (line! (car lines)) (loop (cdr lines)))))))))

  ;; Waits on the network, so it runs off the main thread.
  (define (open-stream! page port)
    (let ([c (connect port)])
      (send-all c (request-bytes port "GET" (string-append "/screen?datastar=" (percent-encode-all (signals page)))
                    '() #f))
      (read-head c)
      (with-mutex (page-mutex page)
        (page-stream-set! page c)
        (page-closed?-set! page #f))
      (fork-thread
        (lambda ()
          (read-chunks c (event-reader page))
          (with-mutex (page-mutex page)
            (when (eq? (page-stream page) c)
              (page-closed?-set! page #t))
            (condition-broadcast (page-arrived page)))
          (c-close (connection-fd c))))
      (void)))

  (define (page-connect! page)
    (let ([port (server-port)])
      (off-main-thread (lambda () (open-stream! page port)))))

  (define (seconds->time seconds)
    (let ([ns (exact (round (* seconds 1000000000)))])
      (add-duration (current-time 'time-utc)
        (make-time 'time-duration (remainder ns 1000000000) (quotient ns 1000000000)))))

  (define (take-event! page seconds)
    (let ([until (seconds->time seconds)])
      (with-mutex (page-mutex page)
        (let wait ()
          (cond
            [(pair? (page-events page))
             (let ([e (car (page-events page))])
               (page-events-set! page (cdr (page-events page)))
               e)]
            [(page-closed? page) 'closed]
            [(condition-wait (page-arrived page) (page-mutex page) until) (wait)]
            [else 'timeout])))))

  (define page-next
    (case-lambda
      [(page) (page-next page 5)]
      [(page seconds) (off-main-thread (lambda () (take-event! page seconds)))]))

  ;; Opens the stream and takes its first event on one thread, so that only
  ;; what the stream's opening makes Tuna do can send that event.
  (define (page-connect-and-next! page)
    (let ([port (server-port)])
      (off-main-thread
        (lambda ()
          (open-stream! page port)
          (take-event! page 5)))))

  (define (page-close! page)
    (let ([c (with-mutex (page-mutex page)
               (let ([c (page-stream page)])
                 (page-stream-set! page #f)
                 (page-closed?-set! page #t)
                 c))])
      (when c
        (c-shutdown (connection-fd c) 2)
        (void))))

  (define (heartbeats-seen page)
    (with-mutex (page-mutex page) (page-heartbeats page)))

  (define (page-events-closed? page)
    (with-mutex (page-mutex page) (page-closed? page)))

  (define (page-send-numbered! page seq item)
    (when (and (fixnum? seq) (fx> seq (page-seq page)))
      (page-seq-set! page seq))
    (response-status
      (request "POST" "/input" '(("content-type" . "application/json"))
        (json->string (append item (list (cons "client" (page-id page)) (cons "seq" seq)))))))

  (define (page-send! page item)
    (page-send-numbered! page (fx+ (page-seq page) 1) item))

  (define (item-bytes page seq item)
    (string->utf8 (json->string (append item (list (cons "client" (page-id page)) (cons "seq" seq))))))

  ;; Items sent one after another from one thread, on one connection, so
  ;; that the main thread runs none of this form's code meanwhile.
  (define (send-items page numbered)
    (let ([port (server-port)])
      (off-main-thread
        (lambda ()
          (let ([c (connect port)])
            (let ([statuses
                   (let loop ([numbered numbered])
                     (if (null? numbered)
                         '()
                         (let ([n (car numbered)])
                           (send-all c (request-bytes* port "POST" "/input" '(("content-type" . "application/json"))
                                         (item-bytes page (car n) (cdr n)) #f))
                           (let-values ([(status headers) (read-head c)])
                             (read-response-body c status headers)
                             (cons status (loop (cdr numbered)))))))])
              (c-close (connection-fd c))
              statuses))))))

  (define (number-items! page items)
    (let ([first (fx+ (page-seq page) 1)])
      (page-seq-set! page (fx+ (page-seq page) (length items)))
      (map (lambda (i item) (cons (fx+ first i) item)) (iota (length items)) items)))

  (define (page-send-all! page items)
    (send-items page (number-items! page items)))

  (define (page-send-range! page from to item)
    (page-seq-set! page (fxmax (page-seq page) to))
    (let ([statuses (send-items page (map (lambda (i) (cons (fx+ from i) (cons (cons "n" (fx+ from i)) item))) (iota (fx+ (fx- to from) 1))))])
      (length statuses)))

  ;; Each page's items 1 to n, from several threads at once, each sending
  ;; every third item on a connection of its own, in windows of five sent
  ;; in reverse, so that items arrive out of order and interleaved.
  (define (flood pages n)
    (let ([port (server-port)] [threads 3])
      (off-main-thread
        (lambda ()
          (let ([m (make-mutex)] [done (make-condition)] [running 0])
            (for-each
              (lambda (page)
                (do ([k 0 (fx+ k 1)]) ((fx= k threads))
                  (let ([numbers (filter (lambda (i) (fx= (fxmod i threads) k)) (map 1+ (iota n)))])
                    (with-mutex m (set! running (fx+ running 1)))
                    (fork-thread
                      (lambda ()
                        (let ([c (connect port)])
                          (for-each
                            (lambda (seq)
                              (send-all c (request-bytes* port "POST" "/input" '()
                                            (item-bytes page seq (list (cons "type" "flood") (cons "n" seq))) #f))
                              (let-values ([(status headers) (read-head c)])
                                (read-response-body c status headers)))
                            (windows-reversed numbers 5))
                          (c-close (connection-fd c)))
                        (with-mutex m
                          (set! running (fx- running 1))
                          (condition-signal done)))))))
              pages)
            (with-mutex m
              (let wait () (unless (fx= running 0) (condition-wait done m) (wait)))))))))

  (define (windows-reversed numbers size)
    (if (null? numbers)
        '()
        (let ([k (fxmin size (length numbers))])
          (append (reverse (list-head numbers k)) (windows-reversed (list-tail numbers k) size)))))

  (define (auto-confirm page)
    (let ([port (server-port)] [seen '()] [m (make-mutex)])
      (fork-thread
        (lambda ()
          (let loop ()
            (let ([e (take-event! page 10)])
              (when (pair? e)
                (let ([shown (show e)])
                  (when (eq? (car shown) 'screen)
                    (with-mutex m (set! seen (cons (cons (cadr shown) (cadddr shown)) seen)))
                    (let ([c (connect port)])
                      (send-all c (request-bytes port "POST" (format "/applied?count=~a" (cadr shown))
                                    '(("content-type" . "application/json")) (signals page)))
                      (read-head c)
                      (c-close (connection-fd c))))
                  (loop)))))))
      (lambda () (with-mutex m (reverse seen)))))

  (define (page-confirm! page n)
    (response-status
      (request "POST" (format "/applied?count=~a" n) '(("content-type" . "application/json")) (signals page))))

  (define (page-goodbye! page)
    (response-status (request "POST" "/goodbye" '() (signals page)))))

(define get
  (case-lambda
    [(path) (request "GET" path '() #f)]
    [(path headers) (request "GET" path headers #f)]))

(define (post path headers body) (request "POST" path headers body))

(define (status r) (response-status r))

(define (header r name) (response-header r name))

(define (body r) (utf8->string (response-body r)))

(define (page) (open-page))

(define (id p) (page-id p))

(define (connect! p) (page-connect! p))

(define (connect-and-next! p) (page-connect-and-next! p))

(define (close! p) (page-close! p))

(define (send! p item) (page-send! p item))

(define (send-numbered! p seq item) (page-send-numbered! p seq item))

(define (send-all! p items) (page-send-all! p items))

(define (send-numbered-all! p numbered) (send-items p numbered))

(define (send-range! p from to item) (page-send-range! p from to item))

(define (occupy! port) (occupy-port! port))

(define (encode s) (percent-encode-all s))

(define (on-port port thunk) (parameterize ([target-port port]) (thunk)))

(define (to-address address thunk) (parameterize ([target-address address]) (thunk)))

(define (from-address address thunk) (parameterize ([source-address address]) (thunk)))

;; The client follows the server's port through a procedure, so that it
;; need not import the plugin it tests and is not reloaded with it.
(define (use-port! source) (set-port-source! source))

(define (flood! pages n) (flood pages n))

(define (auto-confirm! p) (auto-confirm p))

(define (confirm! p n) (page-confirm! p n))

(define (goodbye! p) (page-goodbye! p))

(define (closed? p) (page-events-closed? p))

(define (heartbeats p) (heartbeats-seen p))

(define next
  (case-lambda
    [(p) (page-next p)]
    [(p seconds) (page-next p seconds)]))

(define (head-files)
  (let ([text (utf8->string (response-body (request "GET" "/" '() #f)))])
    (let loop ([i 0] [found '()])
      (let ([at (search text "=\"/files/" i)])
        (if at
            (let ([end (search text "\"" (fx+ at 2))])
              (loop end (cons (substring text (fx+ at 2) end) found)))
            (reverse found))))))

(define (search text part from)
  (let ([n (string-length text)] [m (string-length part)])
    (let loop ([i from])
      (cond
        [(fx> (fx+ i m) n) #f]
        [(string=? (substring text i (fx+ i m)) part) i]
        [else (loop (fx+ i 1))]))))

;; Takes events in the order they came, which a list of calls to next
;; would not, since Chez evaluates arguments in any order.
(define (take p n)
  (if (fx= n 0)
      '()
      (let ([e (show (page-next p))])
        (cons e (take p (fx- n 1))))))

(define (show e)
  (cond
    [(symbol? e) e]
    [else
     (let* ([data (cdr e)] [elements (assoc "elements" data)] [text (and elements (cdr elements))])
       (cond
         [(and text (fx> (string-length text) 23) (string=? (substring text 0 23) "<main id=\"screen\" data-"))
          (let* ([open-end (let find ([i 0]) (if (char=? (string-ref text i) #\>) i (find (fx+ i 1))))]
                 [open (substring text 0 open-end)]
                 [attribute (lambda (name)
                              (let* ([key (string-append name "=\"")]
                                     [at (let find ([i 0]) (if (string=? (substring open i (fx+ i (string-length key))) key) i (find (fx+ i 1))))]
                                     [start (fx+ at (string-length key))]
                                     [end (let find ([i start]) (if (char=? (string-ref open i) #\") i (find (fx+ i 1))))])
                                (string->number (substring open start end))))])
            (list 'screen (attribute "data-count") (attribute "data-through")
                  (substring text (fx+ open-end 1) (fx- (string-length text) 7))))]
         [(and text (assoc "selector" data) (string=? (cdr (assoc "selector" data)) "body")
               (fx> (string-length text) 7) (string=? (substring text 0 7) "<script"))
          (let ([start (fx+ 1 (let find ([i 0]) (if (char=? (string-ref text i) #\>) i (find (fx+ i 1)))))])
            (list 'script (substring text start (fx- (string-length text) 9))))]
         [else (cons (string->symbol (car e)) (map (lambda (d) (list (car d) (cdr d))) data))]))]))
