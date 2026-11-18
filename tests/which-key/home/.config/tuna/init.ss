(import (tuna) (tuna plugins) (web) (keys) (commands) (haml) (harpo))
(use-plugin layout)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin file-picker)
(use-plugin which-key
  (config
    (set-option! which-key:delay 0.5)
    (table-set! which-key:labels "C-c a" "agents")
    (table-set! which-key:labels "C-c b" "buffers")
    (table-set! which-key:labels "C-c e" "workspaces")
    (table-set! which-key:labels "C-c f" "files")
    (table-set! which-key:labels "C-c g" "AI / system")
    (table-set! which-key:labels "C-c l" "language")
    (table-set! which-key:labels "C-c n" "notes")
    (table-set! which-key:labels "C-c o" "open")
    (table-set! which-key:labels "C-c p" "completion")
    (table-set! which-key:labels "C-c s" "search")
    (table-set! which-key:labels "C-c t" "TODO")
    (table-set! which-key:labels "C-c w" "windows")))

(keys:bind! keys:global "C-c f f" files:find-file)
(keys:bind! keys:global "C-c l r" harpo:honk)
(keys:bind! keys:global "C-c h" harpo:keymap)
(keys:bind! keys:global "C-c q z" harpo:squeak)
(keys:bind! keys:global "C-c RET" harpo:honk)
(keys:bind! keys:global "C-c SPC" harpo:honk)
(keys:bind! keys:global "C-c z" harpo:honk)
(keys:bind! keys:global "C-c A" harpo:honk)
(keys:bind! keys:global "C-c <f10>" harpo:honk)
(keys:bind! keys:global "C-c <f2>" harpo:honk)
(keys:bind! keys:global "C-c <home>" harpo:honk)
(keys:bind! keys:global "C-c C-z" harpo:honk)
(keys:bind! keys:global "C-c M-a" harpo:honk)
(keys:bind! keys:global "C-c C-M-a" harpo:honk)
(keys:bind! keys:global "<mouse-3> a" harpo:honk)

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (in-client-of c thunk)
  (parameterize ([web:current-client c])
    (layout:call-with-frame (layout:frame c) thunk)))

(define (press-in! c . keys)
  (for-each (lambda (key) (in-client-of c (lambda () (keys:press! c key)))) keys))

(define (press! . keys) (apply press-in! client keys))

(define (in-client thunk) (in-client-of client thunk))

;; A command's prompt pauses its task, so tests run it in a task of its
;; own and wait for the prompt.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t) (join-task t) 'waiting))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (screen-of c) (html->string (layout:screen c)))

(define (search text needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (text-between text open close from)
  (let ([i (search text open from)])
    (and i
         (let* ([start (+ i (string-length open))] [end (search text close start)])
           (cons (substring text start end) end)))))

;; Keys such as <f2> are written escaped.
(define (unescaped s)
  (let loop ([s s] [pairs '(("&lt;" . "<") ("&gt;" . ">") ("&amp;" . "&"))])
    (if (null? pairs)
        s
        (let ([i (search s (caar pairs) 0)])
          (if i
              (loop (string-append (substring s 0 i) (cdar pairs) (substring s (+ i (string-length (caar pairs))) (string-length s))) pairs)
              (loop s (cdr pairs)))))))

(define (popup-of c)
  (let* ([html (screen-of c)] [at (search html "<div class=\"which-key\"" 0)])
    (and at
         (let ([header (text-between html "<header class=\"which-key-prefix\"><kbd>" "</kbd>" at)])
           (cons (car header)
                 (let loop ([from (cdr header)])
                   (let ([key (text-between html "<dt><kbd>" "</kbd>" from)])
                     (if key
                         (let* ([dd (search html "<dd" (cdr key))]
                                [label? (string=? (substring html dd (+ dd 4)) "<dd ")]
                                [text (text-between html ">" "</dd>" dd)])
                           (cons (append (list (unescaped (car key)) (unescaped (car text))) (if label? '(label) '()))
                                 (loop (cdr text))))
                         '()))))))))

(define (popup) (popup-of client))

(define (shows?) (and (popup) #t))

;; Long enough for which-key:delay set to 0.5 to run out.
(define (wait-out) (sleep-for 0.7))
(import (console))
