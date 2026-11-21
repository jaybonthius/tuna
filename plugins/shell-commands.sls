#!tuna
(import (runs) (processes) (minibuffer) (ask) (files) (layout) (views) (editing) (kill-ring) (buffers) (document)
        (modes) (commands) (keys) (completion))

(define-option compile-command "make -k " string?
  "The command line shell-commands:compile starts from, and the one shell-commands:recompile runs outside compile's buffers.")

(define-option compile-buffer-name (lambda () "*compilation*") procedure?
  "A procedure of no arguments that returns the name of the buffer builds run in.")

(define (%strings? v) (and (list? v) (for-all string? v)))

(define-saved compile-history '() %strings?)

(define-saved shell-command-history '() %strings?)

(define-table compilation-keymap "Keys in the buffers builds run in.")

(define-hook compilation-mode-hook
  "Called in each buffer that turns on shell-commands:compilation-mode or a mode derived from it.")

(modes:define-major-mode compilation-mode
  (parent runs:mode)
  (lighter "Compilation")
  (keymap compilation-keymap)
  (hook compilation-mode-hook)
  (plugin-only #t))

(define %output-buffer-name "*Shell Command Output*")

(define %async-buffer-name "*Async Shell Command*")

(define %text-kind (buffers:kind-name (buffers:constructor-kind buffers:text)))

(define (%read-line question initial history)
  (minibuffer:call-with-setup
    (lambda (p) (when initial (minibuffer:set-input! p initial)))
    (lambda () (minibuffer:read question history #f))))

(define (%check-line who line)
  (unless (string? line)
    (assertion-violation who "not a string" line))
  (when (for-all char-whitespace? (string->list line))
    (error who "no command line")))

(define (%here)
  (processes:options [directory (files:directory)]))

;; The view display-buffer gives may not have shown the buffer when the
;; run started, when runs placed the points of the views showing it.
(define (%show-run b)
  (let ([v (layout:display-buffer b)])
    (when (and (views:view? v) (eq? (views:buffer v) b) (buffers:with-buffer b (runs:follow-output?)))
      (views:set-point! v (fx- (document:length (buffers:document b)) 1)))
    b))

(define (save-buffers) (files:save-some-buffers (lambda (buffer) #t)))

(commands:define-command (compile [line (%read-line "Compile command: " (compile-command) compile-history)])
  "Runs LINE in the buffer shell-commands:compile-buffer-name names, after saving buffers, and offers it the next time."
  (%check-line 'shell-commands:compile line)
  (save-buffers)
  ;; A value that is neither the scope's own nor the setting is bound by
  ;; with-options, which would drop a new value at its end, as Emacs's
  ;; let drops what setq gives its binding; so it is left as it is.
  (unless (string=? line (compile-command))
    (cond
      [(option-local? compile-command) (set-option-local! compile-command line)]
      [(equal? (compile-command) (option-setting compile-command)) (set-option! compile-command line)]))
  (%show-run (runs:start-for-user ((compile-buffer-name)) line (%here) compilation-mode)))

(define (%compile-buffer? b)
  (and (runs:run-buffer? b) (modes:derived? (modes:major-mode b) compilation-mode)))

(commands:define-command (recompile [edit (commands:prefix-argument)])
  "Runs a build again: in compile's buffers their own run, elsewhere the current buffer's compile command; with a prefix argument, after editing the line."
  (save-buffers)
  (let ([b (buffers:current)])
    (if (%compile-buffer? b)
        (let ([line (if edit
                        (%read-line "Compile command: " (runs:command-text (runs:command b)) compile-history)
                        (runs:command b))])
          (%show-run (runs:start-for-user (buffers:name b) line (runs:options b) (modes:major-mode b))))
        (let* ([name ((compile-buffer-name))]
               [target (buffers:find name)]
               [line (if edit
                         (%read-line "Compile command: " (compile-command) compile-history)
                         (compile-command))])
          (%check-line 'shell-commands:recompile line)
          (%show-run
            (runs:start-for-user name line
              (if (and target (runs:run-buffer? target)) (runs:options target) (%here))
              compilation-mode))))))

(define (%output-root-line b)
  (let ([root (document:token (buffers:document b) 0)])
    (and (document:node? root) (eq? (document:node-kind root) %text-kind)
         (document:node-attribute root 'shell-command #f))))

(define (%output-directory b)
  (and (%output-root-line b)
       (document:node-attribute (document:token (buffers:document b) 0) 'directory #f)))

(define (%set-revert! b)
  (buffers:with-buffer b (set-option-local! buffers:revert-function shell-command-again)))

(define (%write-output! line directory text)
  (let ([datum (buffers:text (list (cons 'shell-command line) (cons 'directory directory)) text)]
        [b (buffers:find %output-buffer-name)])
    (let ([b (if b
                 (begin
                   (buffers:splice! b 0 (document:length (buffers:document b)) (document:from-datum datum))
                   b)
                 (buffers:make %output-buffer-name datum))])
      (buffers:set-modified! b #f)
      (%set-revert! b)
      b)))

(define (%no-output-message status)
  (cond
    [(eqv? status 0) "(Shell command succeeded with no output)"]
    [(> status 0) (format "(Shell command failed with code ~a and no output)" status)]
    [else (format "(Shell command killed by signal ~a and no output)" (- status))]))

;; One line goes to the echo area, which holds one; more show the buffer.
(define (%show-output! line directory text status)
  (let ([b (%write-output! line directory text)] [n (string-length text)])
    (define (one-line?)
      (let loop ([i 0])
        (cond
          [(fx= i n) #t]
          [(char=? (string-ref text i) #\newline) (fx= i (fx- n 1))]
          [else (loop (fx+ i 1))])))
    (cond
      [(fx= n 0) (ask:message (%no-output-message status))]
      [(one-line?)
       (ask:message (if (char=? (string-ref text (fx- n 1)) #\newline) (substring text 0 (fx- n 1)) text))]
      [else (layout:display-buffer b)])))

(define (%run-line line input)
  (let ([shell (runs:shell)])
    (let-values ([(status out err)
                  (processes:run (car shell) (append (cdr shell) (list line)) input
                    (processes:options [directory (files:directory)] [environment (runs:environment)]))])
      (values status (utf8->string out)))))

(define (%async-line line)
  (let loop ([i (fx- (string-length line) 1)])
    (cond
      [(fx< i 0) #f]
      [(char-whitespace? (string-ref line i)) (loop (fx- i 1))]
      [(char=? (string-ref line i) #\&) (substring line 0 i)]
      [else #f])))

(define (%check-takes-text who b ranges)
  (for-each
    (lambda (range)
      (when (buffers:refuses-text? b (car range) (cdr range))
        (error who "the buffer refuses the output" (buffers:name b))))
    ranges))

(define (%cursor-ranges view c)
  (let ([ranges (views:region-bounds view c)])
    (if (null? ranges) (let ([p (views:cursor-point c)]) (list (cons p p))) ranges)))

(define (%lines text)
  (let loop ([i 0] [from 0] [acc '()])
    (cond
      [(fx= i (string-length text)) (reverse (cons (substring text from i) acc))]
      [(char=? (string-ref text i) #\newline) (loop (fx+ i 1) (fx+ i 1) (cons (substring text from i) acc))]
      [else (loop (fx+ i 1) from acc)])))

(commands:define-command (shell-command [line (%read-line "Shell command: " #f shell-command-history)]
                                        [insert? (commands:prefix-argument)])
  "Runs LINE through the shell and shows its output, or with INSERT? puts it at each cursor; a line ending in & runs as shell-commands:async-shell-command."
  (%check-line 'shell-commands:shell-command line)
  (let ([async (%async-line line)])
    (if async
        (async-shell-command async)
        (let ([directory (files:directory)] [view (and insert? (views:current))])
          (when insert?
            (unless view
              (error 'shell-commands:shell-command "no view to insert in"))
            (%check-takes-text 'shell-commands:shell-command (views:buffer view)
              (map (lambda (c) (let ([p (views:cursor-point c)]) (cons p p))) (views:cursors view))))
          (let-values ([(status text) (%run-line line #f)])
            (if insert?
                (let ([b (views:buffer view)])
                  (editing:for-each-cursor view
                    (lambda (c p m)
                      (buffers:insert! b p text)
                      (editing:place-cursor! view c p #f))))
                (%show-output! line directory text status)))))))

(commands:define-command (shell-command-on-region [line (%read-line "Shell command on region: " #f shell-command-history)]
                                                  [replace? (commands:prefix-argument)])
  "Runs LINE once for each cursor's region, with the region as input, and shows the outputs, or with REPLACE? replaces each region with its own."
  (%check-line 'shell-commands:shell-command-on-region line)
  (let ([view (views:current)])
    (unless view
      (error 'shell-commands:shell-command-on-region "no view"))
    (editing:check-regions 'shell-commands:shell-command-on-region view)
    (let* ([b (views:buffer view)] [directory (files:directory)]
           [regions (map (lambda (c) (cons c (%cursor-ranges view c))) (views:cursors view))])
      (when replace?
        (%check-takes-text 'shell-commands:shell-command-on-region b (apply append (map cdr regions))))
      ;; A region of several ranges goes in with a final line break and
      ;; comes out with one taken off, so a rectangle's last line is a
      ;; line to the command and adds no empty line back, as Emacs does.
      (let* ([anchored (map (lambda (region)
                              (cons (car region)
                                    (map (lambda (r) (cons (buffers:anchor b (car r)) (buffers:anchor b (cdr r))))
                                         (cdr region))))
                            regions)]
             [results
              (map (lambda (region)
                     (let* ([ranges (map (lambda (r) (cons (buffers:anchor-position (car r)) (buffers:anchor-position (cdr r))))
                                         (cdr region))]
                            [several? (pair? (cdr ranges))]
                            [input (kill-ring:text (list (editing:extract-region view (car region) ranges)))])
                       (let-values ([(status text) (%run-line line (if several? (string-append input "\n") input))])
                         (list status text several?))))
                   anchored)])
        (if replace?
            (for-each
              (lambda (region result)
                (let* ([bounds (map (lambda (r) (cons (buffers:anchor-position (car r)) (buffers:anchor-position (cdr r))))
                                    (cdr region))]
                       [start (caar bounds)]
                       [text (cadr result)]
                       [text (if (and (caddr result) (fx> (string-length text) 0)
                                      (char=? (string-ref text (fx- (string-length text) 1)) #\newline))
                                 (substring text 0 (fx- (string-length text) 1))
                                 text)])
                  (for-each (lambda (r) (buffers:replace! b (car r) (cdr r) "")) (reverse bounds))
                  (editing:place-cursor! view (car region) (editing:insert-region! view (car region) start (%lines text)) #f)))
              anchored results)
            (let ([text (apply string-append (map cadr results))]
                  [failure (find (lambda (result) (not (eqv? (car result) 0))) results)])
              (%show-output! line directory text (if failure (car failure) 0))))))))

(define (async-shell-command-buffer)
  (let ([busy (buffers:find %async-buffer-name)])
    (cond
      [(not (and busy (runs:run-buffer? busy) (not (runs:status busy)))) %async-buffer-name]
      [(ask:yes-or-no? "A command is running in the default buffer. Use a new buffer? ")
       (buffers:free-name %async-buffer-name)]
      [else (error 'shell-commands:async-shell-command "a command is running in the default buffer")])))

(commands:define-command (async-shell-command [line (%read-line "Async shell command: " #f shell-command-history)])
  "Runs LINE through the shell as the user's run, in the buffer shell-commands:async-shell-command-buffer names."
  (%check-line 'shell-commands:async-shell-command line)
  (%show-run (runs:start-for-user (async-shell-command-buffer) line (%here))))

(commands:define-command (shell-command-again)
  "Runs the command line the current buffer's root holds again, as shell-commands:shell-command does."
  (let ([line (%output-root-line (buffers:current))])
    (unless line
      (error 'shell-commands:shell-command-again "the buffer holds no command line"))
    (shell-command line #f)))

(define (%set-recompile) (set-option-local! buffers:revert-function recompile))

(add-hook! compilation-mode-hook %set-recompile)
(add-hook! files:directory-finders %output-directory)
(table-set! commands:command-modes shell-command-again '())
(keys:bind! keys:global "M-!" shell-command)
(keys:bind! keys:global "M-|" shell-command-on-region)
(keys:bind! keys:global "M-&" async-shell-command)
(keys:bind! completion:region-action-keymap "|" shell-command-on-region)
(table-set! commands:region-commands shell-command-on-region #t)
;; Loading a module takes back its local values in every scope, and the
;; output buffer has no mode whose hook would set them again.
(for-each (lambda (b) (when (%output-root-line b) (%set-revert! b))) (buffers:all))
