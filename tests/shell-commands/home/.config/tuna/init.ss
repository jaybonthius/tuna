(import (tuna) (testing) (tuna plugins) (web) (keys) (commands) (document) (buffers) (views) (modes) (processes))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin undo)
(use-plugin buffer-picker)
(use-plugin dired)
(use-plugin shell-commands
  (config
    (set-option! runs:shell '("/bin/sh" "-c"))))
(import (tuna eval))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (settle) (sleep-for 0.1))


;; A command that reads or waits pauses its task, so tests start it in a
;; task of its own.
(define (start! . keys)
  (spawn-task (lambda () (apply press! keys)))
  (settle))

(define (type! text) (apply press! (map (lambda (c) (if (char=? c #\space) "SPC" (string c))) (string->list text))))

;; Runs a command with its arguments in the selected view, in a task,
;; and waits for it.
(define (run! command . arguments)
  (let ([done #f])
    (spawn-task
      (lambda ()
        (guard (c [#t (set! done #t) (raise c)])
          (in-client (lambda () (apply commands:run command arguments)))
          (set! done #t))))
    (testing:wait-until (lambda () done))))

(define (ended? b) (testing:wait-until (lambda () (runs:status b))) (runs:status b))

(define (text b) (document:text (buffers:document b)))

(define (search s needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length s)) #f]
        [(string=? (substring s i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (output b)
  (let* ([s (text b)] [start (+ (search s "\n\n" 0) 2)] [start (+ (search s "\n" start) 1)]
         [end (let loop ([i (- (string-length s) 2)])
                (cond
                  [(< i start) (+ (string-length s) 1)]
                  [(and (char=? (string-ref s i) #\newline) (string=? (substring s (+ i 1) (+ i 5)) "Run ")) i]
                  [else (loop (- i 1))]))])
    (substring s start (max start (- end 1)))))

(define (header-folder b)
  (let* ([s (text b)] [i (+ (search s " in " 0) 4)]) (substring s i (search s "\n" i))))

(define (message) (echo-area:current-message))

(define (view) (layout:selected-view))

(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(define (folder! path) (mkdir (at path)))

(define (shown)
  (map (lambda (v) (buffers:name (views:buffer v)))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define library (getenv "TUNA_LIBRARY"))
(define (reload! name) (eval-file (string-append library "/" name ".sls")))

(define saved 0)
(set! shell-commands:save-buffers (lambda () (set! saved (+ saved 1))))
(import (console))
