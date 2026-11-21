(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin views
  (config
    (set-option! views:scroll-margin 2
                 views:wrap-lines #f)))
(use-plugin modes)
(use-plugin files)
(use-plugin auto-mode)
(use-plugin python)
(use-plugin undo)
(use-plugin kill-ring)

(define home (getenv "HOME"))

(define (write-file path text)
  (let loop ([d (path-parent path)])
    (unless (or (string=? d "") (file-directory? d))
      (loop (path-parent d))
      (mkdir d)))
  (call-with-output-file path (lambda (p) (display text p)) 'replace))

(define (read-file path) (call-with-input-file path get-string-all))

(define (copy-file from to)
  (write-file to "")
  (let ([bytes (call-with-port (open-file-input-port from) get-bytevector-all)])
    (call-with-port (open-file-output-port to (file-options no-fail))
      (lambda (p) (put-bytevector p bytes)))))

;; treesit finds Python's grammar in Tuna's data folder; the tests build
;; it beside the executable, from the copy chez-treesitter vendors.
(define python-commit "293fdc02038ee2bf0e2e206711b69c90ac0d413f")
(define built-grammar
  (format "~a/test-grammars/libtree-sitter-python-~a.so"
    (path-parent (path-parent (car (command-line)))) (substring python-commit 0 12)))
(define installed-grammar
  (format "~a/.local/share/tuna/grammars/libtree-sitter-python-~a.so" home (substring python-commit 0 12)))
(copy-file built-grammar installed-grammar)

(use-plugin treesit)

;; Chez evaluates a call's arguments in no fixed order, and these read
;; what earlier ones waited for.
(define-syntax in-order
  (syntax-rules ()
    [(_) '()]
    [(_ e rest ...) (let ([v e]) (cons v (in-order rest ...)))]))

(define messages '())
(set-option! ask:message-writer (lambda (text) (set! messages (cons text messages))))
(define (told-messages) (let ([m (reverse messages)]) (set! messages '()) m))

(define (spans-of b)
  (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 (document:length (buffers:document b))))

;; Highlighting runs in a job, so a test waits until the spans have not
;; changed for a while. On a loaded machine a job's start or new input can
;; take longer than that before its first answer, so after one the wait
;; goes on until spans are set, or for longer when it may set none.
(define last-asked 0)
(define last-set 0)

(define (settle b)
  (let loop ([n 0] [same 0] [last #f])
    (let ([now (spans-of b)])
      (unless (or (= n 3000)
                  (and (>= same 15)
                       (or (> last-set last-asked) (> (- (real-time) last-asked) 1000))))
        (sleep-for 0.02)
        (loop (+ n 1) (if (equal? now last) (+ same 1) 0) now)))))

(define (face-of span) (cdr (assq 'face (caddr span))))

(define (faces-now b . range)
  (let ([doc (buffers:document b)])
    (filter (lambda (x) x)
      (map (lambda (s)
             (and (or (null? range) (and (< (car s) (cadr range)) (> (cadr s) (car range))))
                  (list (document:text doc (car s) (cadr s)) (face-of s))))
           (spans-of b)))))

;; Pieces can split one face's run in two spans, so colours are compared
;; as runs: spans clipped to a range, the touching ones of one face joined.
(define (face-runs b from to)
  (let loop ([spans (spans-of b)] [acc '()])
    (if (null? spans)
        (reverse acc)
        (let* ([s (car spans)] [start (max from (car s))] [end (min to (cadr s))] [face (face-of s)])
          (cond
            [(>= start end) (loop (cdr spans) acc)]
            [(and (pair? acc) (= (cadar acc) start) (equal? (caddar acc) face))
             (loop (cdr spans) (cons (list (caar acc) end face) (cdr acc)))]
            [else (loop (cdr spans) (cons (list start end face) acc))])))))

(define (all-runs b) (face-runs b 0 (document:length (buffers:document b))))

(define (as-fresh? b)
  (let ([fresh (python "fresh.py" (text-of b))])
    (settle b)
    (settle fresh)
    (let ([same? (equal? (all-runs b) (all-runs fresh))])
      (buffers:kill! fresh)
      same?)))

(define (faces b . range)
  (settle b)
  (apply faces-now b range))

(define (text-of b) (let ([d (buffers:document b)]) (document:text d 0 (document:length d))))

(define (python name text)
  (let ([b (buffers:make name text)])
    (modes:set-major-mode python:mode b)
    b))

(define (grown-text size)
  (let ([sample (read-file (string-append home "/python/sample.py"))] [out (open-output-string)])
    (let loop ([n 0])
      (if (>= n size)
          (get-output-string out)
          (begin (display sample out) (loop (+ n (string-length sample))))))))

(define %job-events '())
(define (note-job! event job)
  (when (equal? (format "~a" job) "#<job %highlighter>")
    (set! %job-events (cons event %job-events))))
(advice-add! jobs:start
  (lambda (start . args)
    (let ([job (apply start args)])
      (set! last-asked (real-time))
      (note-job! 'start job)
      job)))
(advice-add! jobs:send!
  (lambda (send job message)
    (set! last-asked (real-time))
    (send job message)))
(advice-add! jobs:stop!
  (lambda (stop job)
    (note-job! 'stop job)
    (stop job)))
(define (job-events)
  (let ([found (reverse %job-events)])
    (set! %job-events '())
    found))

;; Each batch ends by drawing every client's screen, as the layout does:
;; a screen here is the views drawn for one client.
(define screens '())
(define (show! client . vs)
  (set! screens (cons (cons client vs) (remp (lambda (s) (eq? (car s) client)) screens))))
(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (for-each (lambda (s) (for-each (lambda (v) (views:draw v (car s))) (cdr s)))
              screens)))

(define desktop (web:make-client 1))
(define phone (web:make-client 2))
(define (height-of client) (if (eq? client phone) 200 400))

(define (search text needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (numbers-after text needle)
  (let loop ([from 0] [acc '()])
    (let ([i (search text needle from)])
      (if i
          (let digits ([j (+ i (string-length needle))] [k 0])
            (if (char-numeric? (string-ref text j))
                (digits (+ j 1) (+ (* k 10) (- (char->integer (string-ref text j)) 48)))
                (loop j (cons k acc))))
          (reverse acc)))))

(define (html-of view client) (html->string (views:draw view client)))

(define (line-marks html)
  (let loop ([from 0] [acc '()])
    (let ([i (search html "<div class=\"line\"" from)])
      (if i
          (let* ([close (search html ">" i)] [tag (substring html i close)]
                 [line (car (numbers-after tag "data-line=\""))]
                 [at (let ([a (numbers-after tag "data-at=\"")]) (and (pair? a) (car a)))])
            (loop close (cons (cons line (if at (list (cons "at" at)) (list (cons "line" line)))) acc)))
          (reverse acc)))))

(define reports 0)

;; Stands for the page of a view that does not wrap, each line 20 px:
;; TOP is the line at the top edge. The first and last lines wholly in
;; view keep the configuration's scroll margin of 2 lines from the edges.
(define (report! client view top)
  (let* ([html (html-of view client)]
         [marks (line-marks html)]
         [h (height-of client)]
         [whole-from (+ top 2)]
         [whole-to (- (+ top (quotient h 20)) 1 2)]
         [mark (lambda (line) (or (cdr (or (assv line marks) '(#f . #f))) (list (cons "line" line))))])
    (set! reports (+ reports 1))
    ((table-ref web:input-handlers "scroll") client
     `(("type" . "scroll") ("view" . ,(views:id view))
       ("placement" . ,(car (numbers-after html "data-placement=\""))) ("report" . ,reports)
       ("version" . ,(car (numbers-after html "data-version=\"")))
       ("top" . ,(mark top)) ("spacer" . ,(not (assv top marks))) ("fraction" . 0)
       ("left" . ,(mark top)) ("past" . 0) ("sides" . #())
       ("start" . ,(append (mark whole-from) '(("count" . 0))))
       ("end" . ,(append (mark (max whole-from whole-to)) '(("count" . 0))))
       ("atStart" . ,(and (search html "data-run-at-start" 0) (= top 1) #t))
       ("atEnd" . #f)
       ("columns" . 80) ("rows" . ,(quotient h 20)) ("pointVisible" . #t) ("lost" . #f)
       ("wanted" . ,(let* ([screens (string->number (let ([i (search html "data-drawn-screens=\"" 0)])
                                                       (substring html (+ i 20) (search html "\"" (+ i 20)))))]
                           [lines (+ (exact (ceiling (/ (* screens h) 20))) 1)])
                      `(("aboveLines" . ,lines) ("aboveChars" . ,(* lines 80)) ("belowLines" . ,lines) ("belowChars" . ,(* lines 80))
                        ("side" . ,(exact (ceiling (* screens 80)))))))
       ("settled" . #t) ("hand" . #t) ("edge" . "top")))
    (void)))

(define (line-of b p) (document:line (buffers:document b) p))
(define (line-start b n) (document:line-start (buffers:document b) n))

(define (drawn-lines v)
  (map (lambda (r) (list (line-of (views:buffer v) (car r)) (line-of (views:buffer v) (- (cdr r) 1))))
       (views:drawn-ranges v)))

(define watched #f)
(define set-log '())
(define (watch! b) (set! watched b) (set! set-log '()))
(define (sets) (let ([l (reverse set-log)]) (set! set-log '()) l))
(define on-set #f)
(advice-add! buffers:set-spans!
  (lambda (set layer start end spans . version)
    (let ([result (apply set layer start end spans version)])
      (set! last-set (real-time))
      (when (and watched (buffers:live? watched) (eq? layer (buffers:layer watched syntax-highlighting:faces)))
        (set! set-log (cons (list start end) set-log))
        (when on-set (on-set start end)))
      result)))

(import (pyish))
(import (console))
