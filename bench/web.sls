#!tuna
(import (web) (json) (haml))

;; The client works on threads of its own, since code on the main thread
;; must not wait on the network.
(module (connect close-connection shut-down send-request read-response read-chunk)
  (define libc (load-shared-object "libc.so.6"))
  (define c-socket (foreign-procedure "socket" (int int int) int))
  (define c-connect (foreign-procedure __collect_safe "connect" (int u8* int) int))
  (define c-send (foreign-procedure __collect_safe "send" (int u8* size_t int) ssize_t))
  (define c-recv (foreign-procedure __collect_safe "recv" (int u8* size_t int) ssize_t))
  (define c-setsockopt (foreign-procedure "setsockopt" (int int int u8* int) int))
  (define c-shutdown (foreign-procedure "shutdown" (int int) int))
  (define c-close (foreign-procedure "close" (int) int))
  (define errno-location (foreign-procedure "__errno_location" () uptr))

  ;; A signal to the process can end a wait in recv or send early.
  (define (interrupted?) (fx= (foreign-ref 'int (errno-location) 0) 4))

  (define-record-type connection
    (fields fd buffer (mutable start) (mutable end)))

  (define (connect port)
    (let ([fd (c-socket 2 1 0)] [address (make-immobile-bytevector 16 0)] [one (make-immobile-bytevector 4 0)])
      (bytevector-u16-native-set! address 0 2)
      (bytevector-u16-set! address 2 port (endianness big))
      (bytevector-u8-set! address 4 127)
      (bytevector-u8-set! address 7 1)
      (bytevector-s32-native-set! one 0 1)
      (unless (fx= 0 (c-connect fd address 16))
        (error 'web-bench "cannot connect" port))
      ;; Without TCP_NODELAY a request can wait for the previous one's
      ;; acknowledgement.
      (c-setsockopt fd 6 1 one 4)
      (make-connection fd (make-immobile-bytevector 65536) 0 0)))

  (define (close-connection c) (c-close (connection-fd c)))

  (define (shut-down c) (c-shutdown (connection-fd c) 2))

  ;; The bytes are copied to where the collector does not move them, since
  ;; send runs while collections go on.
  (define (send-request c text body)
    (let ([head (string->utf8 text)])
      (let loop ([at 0])
        (let ([size (fx- (fx+ (bytevector-length head) (bytevector-length body)) at)])
          (when (fx> size 0)
            (let ([out (make-immobile-bytevector size)])
              (do ([i 0 (fx+ i 1)]) ((fx= i size))
                (let ([k (fx+ at i)])
                  (bytevector-u8-set! out i
                    (if (fx< k (bytevector-length head))
                        (bytevector-u8-ref head k)
                        (bytevector-u8-ref body (fx- k (bytevector-length head)))))))
              (let ([n (c-send (connection-fd c) out size #x4000)])
                (cond
                  [(fx> n 0) (loop (fx+ at n))]
                  [(interrupted?) (loop at)]
                  [else (error 'web-bench "cannot send")]))))))))

  (define (fill! c)
    (let ([n (let retry ()
               (let ([n (c-recv (connection-fd c) (connection-buffer c) (bytevector-length (connection-buffer c)) 0)])
                 (if (and (fx< n 0) (interrupted?)) (retry) n)))])
      (connection-start-set! c 0)
      (connection-end-set! c (fxmax n 0))
      (unless (fx> n 0) (error 'web-bench "connection closed"))))

  (define (read-u8 c)
    (when (fx= (connection-start c) (connection-end c))
      (fill! c))
    (let ([b (bytevector-u8-ref (connection-buffer c) (connection-start c))])
      (connection-start-set! c (fx+ (connection-start c) 1))
      b))

  (define (read-bytes c n)
    (let ([out (make-bytevector n)])
      (do ([i 0 (fx+ i 1)]) ((fx= i n) out)
        (bytevector-u8-set! out i (read-u8 c)))))

  (define (read-line c)
    (let loop ([bytes '()])
      (let ([b (read-u8 c)])
        (if (fx= b 10)
            (utf8->string (u8-list->bytevector (reverse (if (and (pair? bytes) (fx= (car bytes) 13)) (cdr bytes) bytes))))
            (loop (cons b bytes))))))

  (define (read-response c)
    (let ([status (string->number (substring (read-line c) 9 12))])
      (let loop ([length 0])
        (let ([line (read-line c)])
          (cond
            [(string=? line "") (cons status (read-bytes c length))]
            [(and (fx> (string-length line) 15) (string-ci=? (substring line 0 15) "content-length:"))
             (loop (string->number (substring line 16 (string-length line))))]
            [else (loop length)])))))

  (define (read-chunk c)
    (let ([bytes (read-bytes c (string->number (read-line c) 16))])
      (read-line c)
      bytes)))

(define port (web:port))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs) (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (percentile xs p)
  (list-ref (list-sort < xs) (min (- (length xs) 1) (exact (floor (* p (length xs)))))))

(define (show name value) (printf "~a ~,2f\n" name value))

(define typed "")

;; Tuna drops a quit requested while no item runs, so the key that quits
;; is posted only once the spin has started.
(define spin-mutex (make-mutex))
(define spin-started (make-condition))
(define spinning? #f)

;; A screen as a display draws one view: sixty lines of spans, the typed
;; text on the thirtieth, about 9 KB.
(define (screen-of text)
  (haml
    (:div.view
      (map (lambda (i)
             (haml
               (:div.line (:span.n i) (:span.code "    (define (line-" i " x) (+ x " (* i 7) ")) ; ")
                 (:span.text (if (= i 30) text "the quick brown fox jumps over the lazy dog")))))
           (iota 60)))))

(define (request text) (format "~a HTTP/1.1\r\nhost: 127.0.0.1:~a\r\n" text port))

(define (new-page)
  (let ([c (connect port)])
    (send-request c (string-append (request "GET /") "connection: close\r\n\r\n") #vu8())
    (let* ([body (utf8->string (cdr (read-response c)))]
           [key "data-signals:client=\"'"]
           [at (let loop ([i 0]) (if (string=? (substring body i (+ i (string-length key))) key) i (loop (+ i 1))))])
      (close-connection c)
      (substring body (+ at (string-length key)) (+ at (string-length key) 32)))))

(define (signals id) (json->string (list (cons "client" id))))

(define (post-item! c id seq fields)
  (let ([body (json->bytevector (append fields (list (cons "client" id) (cons "seq" seq))))])
    (send-request c (format "~acontent-length: ~a\r\n\r\n" (request "POST /input") (bytevector-length body)) body)
    (car (read-response c))))

(define (confirm! c id n)
  (let ([body (string->utf8 (signals id))])
    (send-request c (format "~acontent-length: ~a\r\n\r\n" (request (format "POST /applied?count=~a" n))
                      (bytevector-length body))
      body)
    (read-response c)))

;; Asks for zstd, as browsers do.
(define (open-stream id)
  (open-stream-on (connect port) id))

(define (open-stream-on c id)
  (send-request c (string-append (request (string-append "GET /screen?datastar=" (percent-encoded (signals id))))
                    "accept-encoding: gzip, deflate, br, zstd\r\n\r\n")
    #vu8())
  (read-response c)
  c)

(define (percent-encoded s)
  (apply string-append (map (lambda (b) (format "%~2,'0x" b)) (bytevector->u8-list (string->utf8 s)))))

;; Waits on a thread of its own, so that the main thread goes on serving.
(define (off-main-thread thunk)
  (suspend
    (lambda (resume)
      (fork-thread
        (lambda ()
          (resume (guard (e [#t (lambda () (raise e))])
                    (let ([v (thunk)]) (lambda () v)))))))))

(define (time-ns thunk)
  (let ([start (now-ns)])
    (thunk)
    (- (now-ns) start)))

(define (client-measurements)
  (let* ([id (new-page)] [inputs (connect port)] [seq 0])
    (define (next-seq!) (set! seq (+ seq 1)) seq)
    (let ([posts (map (lambda (i) (time-ns (lambda () (post-item! inputs id (next-seq!) '(("type" . "nothing"))))))
                      (iota 2000))])
      ;; The page carried the first screen, so the stream sends none until
      ;; a key changes it.
      (let ([stream (open-stream id)] [count 0])
        (let ([keys '()] [sizes '()])
          (do ([i 0 (+ i 1)]) ((= i 500))
            (let* ([start (now-ns)]
                   [_ (post-item! inputs id (next-seq!) (list '("type" . "key") (cons "key" (string (integer->char (+ 97 (mod i 26)))))))]
                   [chunk (read-chunk stream)])
              (set! keys (cons (- (now-ns) start) keys))
              (set! sizes (cons (bytevector-length chunk) sizes))
              (set! count (+ count 1))
              (confirm! inputs id count)))
          (let ([quits
                 (map (lambda (i)
                        (with-mutex spin-mutex (set! spinning? #f))
                        (post-item! inputs id (next-seq!) '(("type" . "spin")))
                        (with-mutex spin-mutex
                          (let wait () (unless spinning? (condition-wait spin-started spin-mutex) (wait))))
                        (let* ([start (now-ns)]
                               [_ (post-item! inputs id (next-seq!) '(("type" . "key") ("key" . "q") ("quit" . #t)))]
                               [chunk (read-chunk stream)])
                          (set! count (+ count 1))
                          (confirm! inputs id count)
                          (- (now-ns) start)))
                      (iota 30))])
            (let ([reopens
                   (map (lambda (i)
                          (shut-down stream)
                          (close-connection stream)
                          (let ([start (now-ns)])
                            (set! stream (open-stream id))
                            (read-chunk stream)
                            (- (now-ns) start)))
                        (iota 30))])
              (shut-down stream)
              (close-connection stream)
              (close-connection inputs)
              (list posts keys sizes quits reopens))))))))

;; Web lists a client whose stream the bench closed until a send to it
;; fails, so the measurement takes the client it opened.
(define (send-screen-ns same?)
  (let* ([before (web:clients)]
         [id (off-main-thread new-page)]
         [stream (off-main-thread (lambda () (open-stream id)))]
         [opened (lambda () (find (lambda (c) (not (memq c before))) (web:clients)))]
         [_ (wait-for opened)]
         [client (opened)]
         [screens (if same?
                      (vector (make-bytevector 28000 65) (make-bytevector 28000 65))
                      (vector (make-bytevector 28000 65) (half-changed 28000)))]
         [n 2000])
    (collect-rendezvous)
    (let ([elapsed (time-ns
                     (lambda ()
                       (do ([i 0 (fx+ i 1)]) ((fx= i n))
                         (web:send-screen! client (vector-ref screens (fxand i 1)) "Tuna"))))])
      (off-main-thread (lambda () (shut-down stream) (close-connection stream)))
      (/ elapsed n 1.0))))

;; A screen that differs from the other only halfway along, where a typed
;; character would.
(define (half-changed size)
  (let ([bytes (make-bytevector size 65)])
    (bytevector-u8-set! bytes (quotient size 2) 66)
    bytes))

;; Every thread stops for a full collection, since collect alone refuses
;; while other threads run.
(define (heap-bytes)
  (parameterize ([collect-request-handler (lambda () (collect (collect-maximum-generation)))])
    (collect-rendezvous))
  (bytes-allocated))

(define (wait-for done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (item-json-ns)
  (let ([item (string->utf8 "{\"type\":\"key\",\"key\":\"a\",\"code\":\"KeyA\",\"ctrlKey\":false,\"metaKey\":false,\"altKey\":false,\"shiftKey\":false,\"client\":\"0123456789abcdef0123456789abcdef\",\"seq\":1234}")]
        [n 10000])
    (median (map (lambda (k) (/ (time-ns (lambda () (do ([i 0 (fx+ i 1)]) ((fx= i n)) (bytevector->json item)))) n 1.0))
                 (iota 5)))))

;; What each connected client holds: its stream, the screen in flight,
;; the last given and the one waiting, of 28 KB each. The client's own
;; connections are made before the first count.
(define (client-memory-bytes)
  (let* ([n 50]
         [ids (off-main-thread (lambda () (map (lambda (i) (new-page)) (iota n))))]
         [connections (off-main-thread (lambda () (map (lambda (id) (connect port)) ids)))]
         [before (heap-bytes)]
         [streams (off-main-thread (lambda () (map open-stream-on connections ids)))])
    (wait-for (lambda () (= n (length (web:clients)))))
    (for-each
      (lambda (client)
        (web:send-screen! client (make-bytevector 28000 65) "Tuna")
        (web:send-screen! client (make-bytevector 28000 66) "Tuna"))
      (web:clients))
    (let ([after (heap-bytes)])
      (off-main-thread (lambda () (for-each (lambda (s) (shut-down s) (close-connection s)) streams)))
      (/ (- after before) n 1.0))))

(define (run)
  (wait-for (lambda () (guard (e [#t #f]) (off-main-thread (lambda () (close-connection (connect port)) #t)))))
  (show "item-json" (item-json-ns))
  (let ([results (off-main-thread client-measurements)])
    (let ([posts (list-ref results 0)] [keys (list-ref results 1)] [sizes (list-ref results 2)]
          [quits (list-ref results 3)] [reopens (list-ref results 4)])
      (show "post-to-204" (/ (median posts) 1000.0))
      (show "key-to-screen" (/ (median keys) 1000.0))
      (show "key-to-screen-p99" (/ (percentile keys 0.99) 1000.0))
      (show "screen-bytes" (median sizes))
      (show "screen-bytes-max" (apply max sizes))
      (show "quit" (/ (median quits) 1000.0))
      (show "reopen" (/ (median reopens) 1000.0))))
  (show "send-screen" (send-screen-ns #f))
  (show "send-screen-equal" (send-screen-ns #t))
  (show "client-memory" (/ (client-memory-bytes) 1024.0)))

(table-set! web:input-handlers "key"
  (lambda (client item) (set! typed (string-append typed (cdr (assoc "key" item))))))

(table-set! web:input-handlers "nothing" (lambda (client item) (void)))

(table-set! web:input-handlers "spin"
  (lambda (client item)
    (guard (e [(quit-condition? e) #f])
      (with-mutex spin-mutex
        (set! spinning? #t)
        (condition-signal spin-started))
      (let loop () (loop)))))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (for-each (lambda (client) (web:send-screen! client (screen-of typed) "Tuna")) (web:clients))))
