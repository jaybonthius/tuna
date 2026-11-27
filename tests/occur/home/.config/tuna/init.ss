(import (hooks) (options) (tables) (timers) (saved))
(import (tuna) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin jump-history)
(use-plugin isearch)
(use-plugin replace)
(use-plugin occur)

(define client (web:add-client! 1))

(define other (web:add-client! 2))

(define (view) (layout:selected-view))

(define (press-in! c . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client c])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! c key)))))
    keys))

(define (press! . keys) (apply press-in! client keys))

;; A key whose command reads pauses its task, so it is pressed in a task
;; of its own.
(define (start! . keys)
  (spawn-task (lambda (restore) (apply press! keys)))
  (timers:sleep 0.05))

(define (type! text) (apply press! (map (lambda (c) (if (char=? c #\space) "SPC" (string c))) (string->list text))))

(define (show name text)
  (let ([b (buffers:make name text)])
    (layout:switch-to-buffer b)
    (views:set-point! (view) 1)
    b))

(define (prompt)
  (let ([p (keys:prompt client)])
    (cond
      [(not p) #f]
      [(string? p) (controls-shown p)]
      [else
       (apply string-append
         (map (lambda (part)
                (cond
                  [(string? part) (controls-shown part)]
                  [(car part) (string-append "{" (controls-shown (cdr part)) "}")]
                  [else (controls-shown (cdr part))]))
              p))])))

(define (controls-shown text)
  (apply string-append
    (map (lambda (c)
           (let ([n (char->integer c)])
             (if (or (< n 32) (= n 127)) (string #\^ (integer->char (fxlogxor n 64))) (string c))))
         (string->list text))))

(define (point) (views:point (view)))

(define (text-at a b) (buffers:text-between (buffers:document (views:buffer (view))) a b))

(define (here)
  (let* ([s (isearch:current client)] [m (and s (isearch:search-match s))])
    (list (point) (prompt) (and m (text-at (search:match-start m) (search:match-end m))))))

(define (wait-scan)
  (let ([s (isearch:current client)])
    (let loop ([n 0])
      (unless (or (not s) (= n 300) (search:scan-done? (isearch:search-scan s)))
        (timers:sleep 0.01)
        (loop (+ n 1))))))

;; A search's scan ends after the search itself may have.
(define (wait-drawn c)
  (let loop ([n 0])
    (when (and (< n 300) (null? (drawn c)))
      (timers:sleep 0.01)
      (loop (+ n 1)))))

(define (faced-text html)
  (let loop ([from 0] [acc '()])
    (let ([i (let find ([i from]) (cond [(> (+ i 11) (string-length html)) #f]
                                       [(string=? (substring html i (+ i 11)) "data-face=\"") i]
                                       [else (find (+ i 1))]))])
      (if i
          (let* ([name-end (let find ([j (+ i 11)]) (if (char=? (string-ref html j) #\") j (find (+ j 1))))]
                 [open (let find ([j i]) (if (char=? (string-ref html j) #\>) (+ j 1) (find (+ j 1))))]
                 [close (let find ([j open]) (if (char=? (string-ref html j) #\<) j (find (+ j 1))))])
            (loop close (cons (list (substring html (+ i 11) name-end) (substring html open close)) acc)))
          (reverse acc)))))

;; A cursor over the character at point is an element of its own, not a
;; face, so it is read as its text.
(define (without-cursors html)
  (let ([o (open-output-string)] [n (string-length html)])
    (let loop ([i 0])
      (cond
        [(>= i n) (get-output-string o)]
        [(and (<= (+ i 22) n) (string=? (substring html i (+ i 22)) "<span class=\"cursor-on"))
         (let* ([open (let find ([j i]) (if (char=? (string-ref html j) #\>) (+ j 1) (find (+ j 1))))]
                [close (let find ([j open]) (if (char=? (string-ref html j) #\<) j (find (+ j 1))))])
           (put-string o (substring html open close))
           (loop (+ close 7)))]
        [else (write-char (string-ref html i) o) (loop (+ i 1))]))))

(define (faced html) (faced-text (without-cursors html)))

(define (drawn c) (faced (html->string (views:draw (view) c))))
(import (console))

(define (text) (text-at 0 (document:length (buffers:document (views:buffer (view))))))

(define (session) (replace:current client))

(define (asked)
  (let* ([s (session)] [m (and s (replace:session-match s))])
    (list (point) (prompt) (and m (text-at (search:match-start m) (search:match-end m))))))

(define messages '())
(options:set! ask:message-writer (lambda (text) (set! messages (cons text messages))))
(define (last-message) (and (pair? messages) (car messages)))

;; Each prompt opens once the command's task has run on from the last.
(define (replace! command from . to)
  (start! command)
  (type! from)
  (press! "RET")
  (timers:sleep 0.05)
  (unless (null? to)
    (type! (car to))
    (press! "RET")
    (timers:sleep 0.05)))

(define (occur-buffer) (buffers:find "*Occur*"))

(define (listed)
  (let ([b (occur-buffer)])
    (buffers:text-between (buffers:document b) 0 (document:length (buffers:document b)))))

(define (wait-listed)
  (timers:sleep 0.3))

(define (wins)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (views:point v) (eq? v (view))))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define (occur-view) (find (lambda (v) (eq? (views:buffer v) (occur-buffer))) (layout:views)))

(define (in-occur!) (layout:select! (occur-view)))

(define (find-text b text)
  (let* ([doc (buffers:document b)] [n (document:length doc)] [k (string-length text)])
    (let loop ([p 0])
      (cond
        [(> (+ p k) n) #f]
        [(and (char? (document:token doc p)) (string=? (buffers:text-between doc p (+ p k)) text)) p]
        [else (loop (+ p 1))]))))

(define (where)
  (let* ([v (occur-view)] [doc (buffers:document (occur-buffer))] [p (views:point v)] [node (document:enclosing doc p)])
    (list (or (document:node-attribute node 'number) 'heading)
          (buffers:text-between doc (+ (document:node-start node) 1) p))))

(define (mouse! view button action at)
  (parameterize ([web:current-client client])
    ((tables:ref web:input-handlers "mouse") client
     `(("action" . ,action) ("at" . ,at) ("count" . 0) ("type" . "mouse") ("button" . ,button) ("clicks" . 1)
       ("modifiers" . #()) ("view" . ,(views:id view)) ("version" . ,(buffers:version (views:buffer view)))
       ("showing" . ,(views:shown-count view))))))

(define (click! view button at)
  (when (= button 1) (mouse! view 1 "down" at))
  (mouse! view button "click" at))

(define (occur! . args)
  (views:call-with-view (view) (lambda () (apply occur:occur args)))
  (wait-listed))

(define (src text)
  (let ([old (buffers:find "src")]) (when old (buffers:kill! old)))
  (let ([b (buffers:make "src" text)])
    (layout:switch-to-buffer b)
    (views:set-point! (view) 1)
    b))

(define (only!)
  (let ([keep (view)])
    (let loop ()
      (let ([other (find (lambda (v) (and (not (eq? v keep)) (not (buffers:internal-name? (buffers:name (views:buffer v))))))
                         (layout:views))])
        (when other
          (layout:select! other)
          (press! "C-x" "0")
          (loop))))
    (layout:select! keep)))

(define (question)
  (let* ([p (minibuffer:current-prompt)] [doc (buffers:document (views:buffer (minibuffer:prompt-view p)))])
    (buffers:text-between doc 0 (minibuffer:input-start p))))

(define (count-of s sub)
  (let ([k (string-length sub)])
    (let loop ([i 0] [n 0])
      (cond
        [(> (+ i k) (string-length s)) n]
        [(string=? (substring s i (+ i k)) sub) (loop (+ i 1) (+ n 1))]
        [else (loop (+ i 1) n)]))))

(define (occur-html) (html->string (views:draw (occur-view) client)))

(define (bound key)
  (parameterize ([web:current-client client])
    (views:call-with-view (view) (lambda () (commands:command-name (keys:lookup client key))))))

(define (marked)
  (let* ([html (occur-html)] [n (string-length html)]
         [i (let find ([i 0]) (cond [(> (+ i 5) n) #f] [(string=? (substring html i (+ i 5)) "=&gt;") i] [else (find (+ i 1))]))])
    (and i
         (let digits ([j (+ i 5)] [acc '()])
           (let ([c (string-ref html j)])
             (cond
               [(char=? c #\space) (digits (+ j 1) acc)]
               [(char-numeric? c) (digits (+ j 1) (cons c acc))]
               [else (string->number (list->string (reverse acc)))]))))))

(define (separator-start)
  (let ([doc (buffers:document (occur-buffer))] [found #f])
    (document:for-each-child (document:enclosing doc 1) 0 (document:length doc)
      (lambda (n at)
        (when (and (not found) (document:node? n)
                   (let ([k (symbol->string (document:node-kind n))])
                     (and (>= (string-length k) 9) (string=? (substring k (- (string-length k) 9) (string-length k)) "separator"))))
          (set! found (document:node-start n)))))
    found))
