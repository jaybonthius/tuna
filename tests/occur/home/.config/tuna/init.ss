(import (tuna) (tuna plugins) (document) (haml) (web))
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
  (spawn-task (lambda () (apply press! keys)))
  (sleep-for 0.05))

(define (type! text) (apply press! (map (lambda (c) (if (char=? c #\space) "SPC" (string c))) (string->list text))))

(define (show name text)
  (let ([b (buffers:make name text)])
    (layout:switch-to-buffer b)
    (views:set-point! (view) 1)
    b))

;; The prompt as the echo area shows it, a face's part in brackets.
(define (prompt)
  (let ([p (keys:prompt client)])
    (cond
      [(not p) #f]
      [(string? p) p]
      [else (apply string-append (map (lambda (part) (if (string? part) part (string-append "{" (car part) "}"))) p))])))

(define (point) (views:point (view)))

(define (text-at a b) (buffers:text-between (buffers:document (views:buffer (view))) a b))

(define (here)
  (let* ([s (isearch:current client)] [m (and s (isearch:search-match s))])
    (list (point) (prompt) (and m (text-at (search:match-start m) (search:match-end m))))))

(define (wait-scan)
  (let ([s (isearch:current client)])
    (let loop ([n 0])
      (unless (or (not s) (= n 300) (search:scan-done? (isearch:search-scan s)))
        (sleep-for 0.01)
        (loop (+ n 1))))))

;; A search's scan ends after the search itself may have.
(define (wait-drawn c)
  (let loop ([n 0])
    (when (and (< n 300) (null? (drawn c)))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (faced html)
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

(define (drawn c) (faced (html->string (views:draw (view) c))))
(import (console))

(define (text) (text-at 0 (document:length (buffers:document (views:buffer (view))))))

(define (session) (replace:current client))

(define (asked)
  (let* ([s (session)] [m (and s (replace:session-match s))])
    (list (point) (prompt) (and m (text-at (search:match-start m) (search:match-end m))))))

(define messages '())
(set-option! ask:message-writer (lambda (text) (set! messages (cons text messages))))
(define (last-message) (and (pair? messages) (car messages)))

;; Each prompt opens once the command's task has run on from the last.
(define (replace! command from . to)
  (start! command)
  (type! from)
  (press! "RET")
  (sleep-for 0.05)
  (unless (null? to)
    (type! (car to))
    (press! "RET")
    (sleep-for 0.05)))

(define (occur-buffer) (buffers:find "*Occur*"))

(define (listed)
  (let ([b (occur-buffer)])
    (buffers:text-between (buffers:document b) 0 (document:length (buffers:document b)))))

(define (wait-listed)
  (sleep-for 0.3))
