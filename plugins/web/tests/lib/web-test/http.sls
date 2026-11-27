#!tuna
(import (json) (haml))

;; The client's threads are its own, not those of the code that calls it,
;; so they end with its unload, which shuts its connections down.
(define %self (current-owner))

(define (%fork proc) (call-as-owner %self (lambda () (fork-task proc))))

;; The client works on threads of its own, since code on the main thread
;; must not wait on the network.
(module (request request-in-batch response-status response-header response-body open-page page-id page-sxml
         page-connect! page-close! page-send! page-send-numbered! send-items page-send-all! page-send-range!
         page-confirm! page-goodbye! page-next page-connect-and-next! heartbeats-seen
         occupy-port! unused-port target-port target-address source-address set-port-source! percent-encode-all
         flood auto-confirm open-raw-stream raw-stream-encoding raw-stream-next raw-stream-close!
         shut-down-connections! attribute children tagged)

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
        (%fork (lambda (restore) (resume (guard (e [#t (lambda () (raise e))])
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

  (define c-setsockopt (foreign-procedure "setsockopt" (int int int u8* int) int))

  (define (reuse-address! fd)
    (let ([one (make-bytevector 4 0)])
      (bytevector-s32-native-set! one 0 1)
      (c-setsockopt fd 1 2 one 4)))

  ;; Without SO_REUSEADDR the bind fails on a port that unused-port holds.
  (define (occupy-port! port)
    (let ([fd (c-socket 2 1 0)])
      (reuse-address! fd)
      (unless (and (fx= 0 (c-bind fd (address-of port) 16)) (fx= 0 (c-listen fd 1)))
        (error 'http "cannot listen" port))
      fd))

  (define c-getsockname (foreign-procedure "getsockname" (int u8* u8*) int))

  ;; Asked of every address, so the port is free on 127.0.0.2 too, where
  ;; the proxy's tests listen. The socket stays bound, so that no other
  ;; process takes the port before Tuna listens on it; SO_REUSEADDR, which
  ;; Tuna's listener also sets, lets the two share it while this one does
  ;; not listen.
  (define (unused-port)
    (let ([fd (c-socket 2 1 0)] [address (address-of "0.0.0.0" 0)] [size (make-bytevector 4)])
      (bytevector-u32-native-set! size 0 16)
      (reuse-address! fd)
      (let ([found? (and (fx= 0 (c-bind fd address 16)) (fx= 0 (c-getsockname fd address size)))])
        (unless found?
          (c-close fd)
          (error 'http "cannot find an unused port"))
        (bytevector-u16-ref address 2 (endianness big)))))

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
      (let ([c (make-connection fd (make-immobile-bytevector 65536) 0 0)])
        (with-mutex open-connections-mutex (hashtable-set! open-connections c #t))
        c)))

  ;; A connection is closed under the mutex, so a shutdown never reaches
  ;; its descriptor once another file may have the same number.
  (define open-connections (make-eq-hashtable))
  (define open-connections-mutex (make-mutex))

  (define (close-connection! c)
    (with-mutex open-connections-mutex
      (hashtable-delete! open-connections c)
      (c-close (connection-fd c))))

  ;; A reader waits in recv, where no stop reaches it, and its module's
  ;; unload waits for its thread; a shutdown ends the wait.
  (define (shut-down-connections!)
    (with-mutex open-connections-mutex
      (vector-for-each (lambda (c) (c-shutdown (connection-fd c) 2)) (hashtable-keys open-connections))))

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
  (define (exchange port to from method path headers body)
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
          (close-connection! c)
          (make-response status response-headers body)))))

  (define (request method path headers body)
    (let ([port (server-port)] [to (target-address)] [from (source-address)])
      (off-main-thread
        (lambda () (exchange port to from method path headers body)))))

  ;; The main thread waits for the response, so the batch it is in cannot
  ;; end before the server has answered.
  (define (request-in-batch method path headers body)
    (exchange (server-port) (target-address) (source-address) method path headers body))

  (define (read-response-body c status response-headers)
    (cond
      [(memv status '(204 304)) #vu8()]
      [(header response-headers "content-length") => (lambda (n) (read-bytes c (string->number n)))]
      [else #vu8()]))

  (define-record-type page
    (fields id (mutable seq) mutex arrived (mutable events) (mutable stream) (mutable closed?)
            (mutable heartbeats) sxml))

  ;; The id is the body's data-signals:client, a quoted JavaScript string.
  (define (open-page)
    (let* ([sxml (html->sxml (response-body (request "GET" "/" '() #f)))]
           [signal (attribute (car (tagged sxml 'body)) "data-signals:client")])
      (make-page (substring signal 1 (fx- (string-length signal) 1)) 0 (make-mutex) (make-condition) '() #f #f 0 sxml)))

  (define (attributes element)
    (let ([rest (cdr element)])
      (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdar rest) '())))

  (define (children element)
    (let ([rest (cdr element)])
      (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdr rest) rest)))

  (define (attribute element name)
    (let ([a (find (lambda (a) (string=? (symbol->string (car a)) name)) (attributes element))])
      (and a (cadr a))))

  (define (tagged sxml name)
    (let walk ([node sxml])
      (if (pair? node)
          (let ([inner (apply append (map walk (children node)))])
            (if (eq? (car node) name) (cons node inner) inner))
          '())))

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
      (%fork (lambda (restore) (read-chunks c (event-reader page))
          (with-mutex (page-mutex page)
            (when (eq? (page-stream page) c)
              (page-closed?-set! page #t))
            (condition-broadcast (page-arrived page)))
          (close-connection! c)))
      (void)))

  ;; Its events arrive compressed, which this client cannot read, so only
  ;; the bytes of each chunk are counted.
  (define-record-type raw-stream
    (fields connection mutex arrived encoding (mutable sizes) (mutable closed?)))

  (define (open-raw-stream page headers)
    (let ([port (server-port)])
      (off-main-thread
        (lambda ()
          (let ([c (connect port)])
            (send-all c (request-bytes port "GET" (string-append "/screen?datastar=" (percent-encode-all (signals page)))
                          headers #f))
            (let-values ([(status response-headers) (read-head c)])
              (let ([s (make-raw-stream c (make-mutex) (make-condition) (header response-headers "content-encoding") '() #f)])
                (%fork (lambda (restore) (read-chunks c
                      (lambda (bytes)
                        (with-mutex (raw-stream-mutex s)
                          (raw-stream-sizes-set! s (cons (bytevector-length bytes) (raw-stream-sizes s)))
                          (condition-broadcast (raw-stream-arrived s)))))
                    (with-mutex (raw-stream-mutex s)
                      (raw-stream-closed?-set! s #t)
                      (condition-broadcast (raw-stream-arrived s)))
                    (close-connection! c)))
                s)))))))

  ;; A screen can come in several chunks, so its bytes are those of the
  ;; chunks that arrive until none has for a tenth of a second.
  (define (raw-stream-next s)
    (off-main-thread
      (lambda ()
        (with-mutex (raw-stream-mutex s)
          (let ([until (seconds->time 5)])
            (let wait ()
              (when (and (null? (raw-stream-sizes s)) (not (raw-stream-closed? s))
                         (condition-wait (raw-stream-arrived s) (raw-stream-mutex s) until))
                (wait))))
          (let settle ()
            (let ([n (length (raw-stream-sizes s))])
              (condition-wait (raw-stream-arrived s) (raw-stream-mutex s) (seconds->time 0.1))
              (unless (fx= n (length (raw-stream-sizes s)))
                (settle))))
          (let ([total (apply + (raw-stream-sizes s))])
            (raw-stream-sizes-set! s '())
            total)))))

  (define (raw-stream-close! s)
    (c-shutdown (connection-fd (raw-stream-connection s)) 2)
    (void))

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
              (close-connection! c)
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
                    (%fork (lambda (restore) (let ([c (connect port)])
                          (for-each
                            (lambda (seq)
                              (send-all c (request-bytes* port "POST" "/input" '()
                                            (item-bytes page seq (list (cons "type" "flood") (cons "n" seq))) #f))
                              (let-values ([(status headers) (read-head c)])
                                (read-response-body c status headers)))
                            (windows-reversed numbers 5))
                          (close-connection! c))
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
      (%fork (lambda (restore) (let loop ()
            (let ([e (take-event! page 10)])
              (when (pair? e)
                (let ([shown (show e)])
                  (when (eq? (car shown) 'screen)
                    (with-mutex m (set! seen (cons (cons (cadr shown) (cadddr shown)) seen)))
                    (let ([c (connect port)])
                      (send-all c (request-bytes port "POST" (format "/applied?count=~a" (cadr shown))
                                    '(("content-type" . "application/json")) (signals page)))
                      (read-head c)
                      (close-connection! c)))
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

(define (post-in-batch path headers body) (request-in-batch "POST" path headers body))

(define (status r) (response-status r))

(define (header r name) (response-header r name))

(define (body r) (utf8->string (response-body r)))

(define (page) (open-page))

(define (page-markup p) (page-sxml p))

(define (id p) (page-id p))

(define (connect! p) (page-connect! p))

(define (connect-and-next! p) (show (page-connect-and-next! p)))

(define (close! p) (page-close! p))

(define (open-raw! p headers) (open-raw-stream p headers))

(define (raw-encoding s) (raw-stream-encoding s))

(define (raw-next s) (raw-stream-next s))

(define (close-raw! s) (raw-stream-close! s))

(define (send! p item) (page-send! p item))

(define (send-numbered! p seq item) (page-send-numbered! p seq item))

(define (send-all! p items) (page-send-all! p items))

(define (send-numbered-all! p numbered) (send-items p numbered))

(define (send-range! p from to item) (page-send-range! p from to item))

(define (occupy! port) (occupy-port! port))

(define (free-port) (unused-port))

(define (encode s) (percent-encode-all s))

(define (on-port port thunk) (parameterize ([target-port port]) (thunk)))

(define (to-address address thunk) (parameterize ([target-address address]) (thunk)))

(define (from-address address thunk) (parameterize ([source-address address]) (thunk)))

(define (url-port url)
  (string->number (substring url (string-length "http://127.0.0.1:") (fx- (string-length url) 1))))

;; The client follows the server through a procedure of no arguments
;; giving its URL, so that it need not import the plugin it tests and is
;; not reloaded with it.
(define (use-url! source) (set-port-source! (lambda () (let ([url (source)]) (and url (url-port url))))))

(define (flood! pages n) (flood pages n))

(define (auto-confirm! p) (auto-confirm p))

(define (confirm! p n) (page-confirm! p n))

(define (goodbye! p) (page-goodbye! p))

(define (heartbeats p) (heartbeats-seen p))

(define next
  (case-lambda
    [(p) (show (page-next p))]
    [(p seconds) (show (page-next p seconds))]))

(define (elements-named sxml name) (tagged sxml name))

(define (element-attribute element name) (attribute element name))

(define (element-text element)
  (let walk ([node element])
    (cond
      [(string? node) node]
      [(pair? node) (apply string-append (map walk (children node)))]
      [else ""])))

(define (head-files)
  (let ([head (car (tagged (html->sxml (response-body (request "GET" "/" '() #f))) 'head))])
    (filter (lambda (path) (and path (fx> (string-length path) 7) (string=? "/files/" (substring path 0 7))))
            (map (lambda (e) (and (pair? e) (or (attribute e "href") (attribute e "src")))) (children head)))))

;; Takes events in the order they came, which a list of calls to next
;; would not, since Chez evaluates arguments in any order.
(define (take p n)
  (if (fx= n 0)
      '()
      (let ([e (next p)])
        (cons e (take p (fx- n 1))))))

(define (show e)
  (if (symbol? e)
      e
      (let* ([data (cdr e)]
             [field (lambda (name) (let ([d (assoc name data)]) (and d (cdr d))))]
             [sxml (let ([text (field "elements")]) (if text (html->sxml text) '(*TOP*)))]
             [first (and (pair? (cdr sxml)) (pair? (cadr sxml)) (cadr sxml))])
        (cond
          [(and first (eq? (car first) 'main) (attribute first "data-count"))
           (list 'screen (string->number (attribute first "data-count")) (string->number (attribute first "data-through"))
                 (children first))]
          [(and first (eq? (car first) 'script) (equal? (field "selector") "body"))
           (list 'script (element-text first))]
          [else (list 'patch (field "selector") (field "mode") sxml)]))))

(on-unload shut-down-connections!)
