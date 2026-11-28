#!tuna
(import (modes) (test-user) (views) (buffers) (document) (chez-scheme) (editing-test scene))

;; A user reaches a new buffer by a command, which ends a run of kills or
;; yanks; C-g is one that changes nothing else.
(define show-in!
  (case-lambda
    [(mode marked) (show-in! mode marked #\| #\@)]
    [(mode marked cursor-char mark-char)
     (test-user:press! "C-g")
     (let loop ([cs (string->list marked)] [i 1] [acc '()] [points '()] [mark #f])
       (cond
         [(null? cs)
          (let ([b (buffers:make (buffers:free-name "case.ss") (list->string (reverse acc)))]
                [v (editing-test/scene:view)]
                [points (reverse points)])
            (modes:set-major-mode mode b)
            (views:set-buffer! v b)
            (views:set-point! v (car points))
            (when mark (views:set-mark! v mark))
            (for-each (lambda (p) (views:add-cursor! v p)) (cdr points))
            (test-user:settle)
            b)]
         [(char=? (car cs) cursor-char) (loop (cdr cs) i acc (cons i points) mark)]
         [(char=? (car cs) mark-char) (loop (cdr cs) i acc points i)]
         [else (loop (cdr cs) (+ i 1) (cons (car cs) acc) points mark)]))]))

(define show!
  (case-lambda
    [(marked) (show-in! chez-scheme:mode marked)]
    [(marked cursor-char mark-char) (show-in! chez-scheme:mode marked cursor-char mark-char)]))

(define shown
  (case-lambda
    [() (shown #\|)]
    [(cursor-char)
     (let* ([doc (buffers:document (views:buffer (editing-test/scene:view)))]
            [points (map views:cursor-point (views:cursors (editing-test/scene:view)))])
       (let loop ([p 1] [acc '()])
         (let ([acc (if (memv p points) (cons (string cursor-char) acc) acc)])
           (if (>= p (document:length doc))
               (apply string-append (reverse acc))
               (loop (+ p 1) (let ([t (document:token doc p)]) (if (char? t) (cons (string t) acc) acc)))))))]))

(define (after marked keys)
  (show! marked)
  (test-user:press! keys)
  (shown))

(define (mark) (views:mark (editing-test/scene:view)))
