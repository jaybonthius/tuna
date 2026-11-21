(import (tuna) (tuna plugins) (tuna eval) (document) (haml) (web))
(use-plugin terminal)
(use-plugin editing)
(use-plugin layout)
(use-plugin undo)

(putenv "PATH" (string-append (getenv "HOME") "/bin:" (getenv "PATH")))

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))

(define (view) (layout:selected-view))

;; A wait that runs out says so, so the transcript fails.
(define (wait-until done?)
  (let loop ([n 0])
    (cond
      [(done?) (void)]
      [(= n 1000) (display "timed out\n")]
      [else (sleep-for 0.01) (loop (+ n 1))])))

(define (text b) (document:text (buffers:document b)))

(define (lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (if (< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (contains? s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s))
           (or (string=? (substring s i (+ i n)) part) (loop (+ i 1)))))))

(define (screen-has? b part) (contains? (terminal:screen-text b) part))

(define (wait-for b part) (wait-until (lambda () (screen-has? b part))))

;; A shell whose prompt is the same on every machine.
(define (shell!)
  (set-option! terminal:shell '("bash" "--norc" "--noprofile"))
  (set-option! terminal:environment '(("PS1" . "$ ") ("PS2" . "> ") ("HISTFILE" . #f)))
  (let ([t (terminal:start #f)])
    (wait-for t "$ ")
    t))

(define (screen-lines b)
  (let loop ([ls (reverse (lines (terminal:screen-text b)))])
    (if (and (pair? ls) (string=? (car ls) "")) (loop (cdr ls)) (reverse ls))))

;; A terminal started by a command the client's key ran.
(define (start-for-client command)
  (parameterize ([web:current-client client]) (terminal:start command)))

;; A program that reports the next n bytes it reads, after the shell
;; commands in setup.
(define (reader n . setup)
  (let ([t (start-for-client
             (list "sh" "-c"
               (format "stty raw -echo; ~aecho ready; dd bs=1 count=~a 2>/dev/null | od -An -tx1 | tr -s ' \\n' ' '; echo; echo end; read x"
                 (apply string-append setup) n)))])
    (wait-for t "ready")
    t))

(define (read-by t)
  (wait-for t "end")
  (let ([read (cadr (screen-lines t))])
    (let trim ([i 0])
      (if (char=? (string-ref read i) #\space)
          (trim (+ i 1))
          (substring read i (- (string-length read) 1))))))

(define (colors! background)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "terminal-colors") client
     `(("type" . "terminal-colors") ("foreground" . "#101010") ("background" . ,background) ("cursor" . "#ff0000")
       ("palette" . #("#000000" "#aa0000" "#00aa00" "#aaaa00" "#0000aa" "#aa00aa" "#00aaaa" "#aaaaaa"
                      "#555555" "#ff5555" "#55ff55" "#ffff55" "#5555ff" "#ff55ff" "#55ffff" "#ffffff"))))))

;; The bytes a program reads, in hexadecimal, after the shell commands
;; in setup, while the keys are typed in its terminal; a procedure in
;; keys is called instead.
(define (bytes-read keys n . setup)
  (let ([t (start-for-client
             (list "sh" "-c"
               (format "~astty raw -echo; echo ready; dd bs=1 count=~a 2>/dev/null | od -An -tx1 | tr -s ' \\n' ' '; echo; echo end; read x"
                 (apply string-append setup) n)))])
    (wait-for t "ready")
    (in-client (lambda () (layout:switch-to-buffer t)))
    (for-each (lambda (k) (if (procedure? k) (k) (press! k))) keys)
    (wait-for t "end")
    (let ([read (cadr (screen-lines t))])
      (buffers:kill! t)
      (let trim ([i 0])
        (if (char=? (string-ref read i) #\space)
            (trim (+ i 1))
            (substring read i (- (string-length read) 1)))))))

(define (paste! text)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "paste") client `(("type" . "paste") ("text" . ,text)))))

;; The HTML views draws for the line of buffer b's text that starts with
;; prefix, in the selected view.
(define (drawn-line b prefix)
  (let* ([html (html->string (views:draw (view) client))]
         [doc (buffers:document b)]
         [text (document:text doc)]
         [at (let loop ([i 0]) (if (string=? (substring text i (+ i (string-length prefix))) prefix) i (loop (+ i 1))))]
         [mark (format "data-at=\"~a\">" (+ at 4))]
         [start (let loop ([i 0]) (if (string=? (substring html i (+ i (string-length mark))) mark) (+ i (string-length mark)) (loop (+ i 1))))]
         [end (let loop ([i start]) (if (string=? (substring html i (+ i 6)) "</div>") i (loop (+ i 1))))])
    (substring html start end)))

;; What a browser of the given size reports for a view, so views knows
;; how many columns and rows fit.
(define (measure! v width height)
  (let* ([html (html->string (views:draw v client))]
         [number-after (lambda (key)
                         (let loop ([i 0])
                           (let ([n (string-length key)])
                             (if (string=? (substring html i (+ i n)) key)
                                 (let digits ([j (+ i n)])
                                   (if (char-numeric? (string-ref html j))
                                       (digits (+ j 1))
                                       (string->number (substring html (+ i n) j))))
                                 (loop (+ i 1))))))])
    (parameterize ([web:current-client client])
      ((table-ref web:input-handlers "scroll") client
       `(("type" . "scroll") ("view" . ,(views:id v)) ("placement" . ,(number-after "data-placement=\""))
         ("report" . 1) ("version" . ,(number-after "data-version=\"")) ("top" . null) ("fraction" . 0)
         ("spacer" . #f) ("left" . null) ("past" . 0) ("sides" . #()) ("start" . null) ("end" . null) ("atStart" . #f) ("atEnd" . #t)
         ("columns" . ,(quotient width 10)) ("rows" . ,(quotient height 20)) ("pointVisible" . #t)
         ("wanted" . (("aboveLines" . 100) ("aboveChars" . 20000) ("belowLines" . 100) ("belowChars" . 20000) ("side" . 2000))) ("hand" . #f) ("settled" . #f) ("edge" . "top"))))))
(import (console))
