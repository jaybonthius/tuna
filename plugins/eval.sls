#!tuna
;; The plugin's options take the names of Chez's printer parameters, so
;; Chez's go by others.
(import (tuna eval) (chez-scheme) (chez-scheme-completion) (buffers) (document) (views) (files) (commands) (keys)
        (editing) (echo-area) (minibuffer) (completion) (ask)
        (rename (only (chezscheme) print-length print-level)
                (print-length chez-print-length) (print-level chez-print-level)))

(define (%limit? v) (or (not v) (and (fixnum? v) (fx>= v 0))))

(define-option print-length 12 %limit?
  "The most elements of a list or vector eval:show-result writes; #f writes them all.")

(define-option print-level 4 %limit?
  "The deepest nesting of lists and vectors eval:show-result writes; #f writes every level.")

(define-saved expression-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-table expression-keymap "Added to the prompt of eval:expression.")

(define-hook expression-prompt-started
  "Called with the prompt of eval:expression in its setup, before minibuffer:prompt-started.")

(define (%write-values port vs)
  (unless (null? vs)
    (write (car vs) port)
    (for-each (lambda (v) (newline port) (write v port)) (cdr vs))))

;; Written whole first, since a port such as the echo area's may do work
;; for each write, and a large value is many small writes.
(define (%written vs length level)
  (parameterize ([print-graph #t] [chez-print-length length] [chez-print-level level])
    (call-with-string-output-port (lambda (port) (%write-values port vs)))))

(define (show-result port results)
  (unless (and (output-port? port) (textual-port? port))
    (assertion-violation 'eval:show-result "not a textual output port" port))
  (unless (list? results)
    (assertion-violation 'eval:show-result "not a list" results))
  (let ([shown (remq (void) results)])
    (if (and (null? shown) (not (and (port-has-port-position? port) (> (port-position port) 0))))
        (display "No value" port)
        (display (%written shown (print-length) (print-level)) port))))

(define (%definer? head)
  (let* ([s (symbol->string head)]
         [name (let loop ([i (fx- (string-length s) 1)])
                 (cond
                   [(fx< i 0) s]
                   [(char=? (string-ref s i) #\:) (substring s (fx+ i 1) (string-length s))]
                   [else (loop (fx- i 1))]))])
    (or (string=? name "define")
        (and (fx> (string-length name) 7) (string=? (substring name 0 7) "define-")))))

(define (%first-symbol x)
  (cond
    [(symbol? x) x]
    [(pair? x) (or (%first-symbol (car x)) (%first-symbol (cdr x)))]
    [else #f]))

(define (%definition-name form)
  (and (pair? form) (symbol? (car form)) (%definer? (car form)) (pair? (cdr form))
       (%first-symbol (cadr form))))

;; Only text that eval-text has read already comes here, so it reads.
(define (%last-form text)
  (let ([p (open-input-string text)])
    (let loop ([last #f])
      (let ([form (read p)])
        (if (eof-object? form) last (loop form))))))

;; A definition's value is void, where Emacs's defun returns the symbol
;; it defines, which M-: shows; so a definition shows its name.
(define (%shown text results)
  (let ([name (and (for-all (lambda (v) (eq? v (void))) results) (%definition-name (%last-form text)))])
    (if name (list name) results)))

;; Code that reads from the current input port would otherwise wait on
;; Tuna's standard input, in C, where no quit reaches it.
(define (%evaluate thunk)
  (let ([port (echo-area:open-output-port)])
    (let ([results (parameterize ([current-output-port port] [current-input-port (open-input-string "")])
                     (call-with-values thunk list))])
      (values port results))))

(define (%insert! who vs)
  (let ([view (views:current)])
    (unless view
      (error who "no view to insert in"))
    (let ([text (%written vs #f #f)])
      (views:set-point! view (buffers:insert! (views:buffer view) (views:point view) text)))))

(define (%show-or-insert who text path prefix)
  (let-values ([(port results) (%evaluate (lambda () (eval-text text path)))])
    (let ([shown (%shown text results)])
      (if (and prefix (not (eq? prefix '-)))
          (%insert! who shown)
          (show-result port shown)))))

(define %expression-prompts (make-weak-eq-hashtable))

(define (%read-expression)
  (minibuffer:call-with-setup
    (lambda (p)
      (eq-hashtable-set! %expression-prompts p #t)
      (minibuffer:add-keymap! p expression-keymap)
      (expression-prompt-started p))
    (lambda () (minibuffer:read "Eval: " expression-history #f))))

(commands:define-command (expression [text (%read-expression)] [prefix (commands:prefix-argument)])
  "Evaluates TEXT as (repl) and shows its values, or with a PREFIX other than - inserts them at point."
  (unless (string? text)
    (assertion-violation 'eval:expression "not a string" text))
  (%show-or-insert 'eval:expression text #f prefix))

;; Chez's reader ends its message with the position, in a format of its
;; own; the prompt shows the position by moving point there.
(define (%reader-message c)
  (let ([message (condition-message c)] [irritants (if (irritants-condition? c) (condition-irritants c) '())])
    (cond
      [(and (equal? message "~? at char ~a of ~s") (fx= (length irritants) 4))
       (apply format (car irritants) (cadr irritants))]
      [else (guard (e [(not (quit-condition? e)) message]) (apply format message irritants))])))

(define (%after-space text from)
  (let loop ([i from])
    (if (and (fx< i (string-length text)) (char-whitespace? (string-ref text i))) (loop (fx+ i 1)) i)))

(define (%expression-problem text)
  (let ([port (open-input-string text)]
        [sfd (make-source-file-descriptor "expression" (open-bytevector-input-port (string->utf8 text)))])
    (guard (c [(lexical-violation? c) (values (%reader-message c) (port-position port))])
      (let-values ([(first end) (get-datum/annotations port sfd 0)])
        (if (eof-object? first)
            (values "no expression" (string-length text))
            (guard (c [(lexical-violation? c) (values "text after the expression" (%after-space text end))])
              (let ([next (car (call-with-values (lambda () (get-datum/annotations port sfd end)) list))])
                (cond
                  [(eof-object? next) (values #f #f)]
                  [(annotation? next) (values "text after the expression" (source-object-bfp (annotation-source next)))]
                  [else (values "text after the expression" (%after-space text end))]))))))))

;; Emacs pushes a mark before moving point to the text after the
;; expression; in Tuna a mark makes an active region, so none is set.
(commands:define-command (exit-expression)
  "Ends the prompt of eval:expression with its input when it reads as one expression; otherwise says why and moves point to where reading stopped."
  (let ([p (minibuffer:current-prompt)])
    (unless p
      (assertion-violation 'eval:exit-expression "no prompt waits"))
    (let ([text (minibuffer:input p)])
      (let-values ([(problem at) (%expression-problem text)])
        (if problem
            (let ([v (minibuffer:prompt-view p)])
              (when v (views:set-point! v (fx+ (minibuffer:input-start p) at)))
              (minibuffer:message! p problem))
            (minibuffer:exit! p text))))))

;; Every prompt is a node of one buffer, so no local entry can tell M-:'s
;; prompt from another.
(define (%expression-name-region)
  (let ([p (minibuffer:current-prompt)] [v (views:current)])
    (and p v (eq-hashtable-ref %expression-prompts p #f)
         (minibuffer:buffer? (views:buffer v))
         (fx<= (minibuffer:input-start p) (views:point v) (minibuffer:input-end p))
         (chez-scheme-completion:name-region))))

(define (%current-region who)
  (let ([view (views:current)])
    (unless view
      (error who "no view"))
    (editing:check-regions who view)
    (let ([p (views:point view)] [m (views:mark view)])
      (values (views:buffer view) (fxmin p m) (fxmax p m)))))

(commands:define-command (region [(buffer start end) (%current-region 'eval:region)])
  "Evaluates the forms of BUFFER's text from START to END, in order, and shows the output and the last form's values."
  (unless (buffers:buffer? buffer)
    (assertion-violation 'eval:region "not a buffer" buffer))
  (let ([doc (buffers:document buffer)])
    (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end (document:length doc)))
      (assertion-violation 'eval:region "not a range of the buffer" (list start end)))
    (%show-or-insert 'eval:region (document:text doc start end) (files:path buffer) #f)))

(define %reported (make-thread-parameter #f))

;; A failure eval-file handles itself, such as a module's reload that
;; raised, reaches the user only through report; a warning counts too,
;; since the confirmation would replace it on the echo area's one line.
(define (%note-report report c)
  (let ([b (%reported)])
    (when b (set-box! b #t)))
  (report c))

(commands:define-command (buffer [buffer (buffers:current)])
  "Evaluates BUFFER whole, as its file when it visits one, asking to save it first, then says so when nothing was reported meanwhile."
  (unless (buffers:buffer? buffer)
    (assertion-violation 'eval:buffer "not a buffer" buffer))
  (let* ([path (files:path buffer)] [file? (and path (file-exists? path))] [reported (box #f)])
    (when (and file? (buffers:modified? buffer) (ask:y-or-n? (format "Save ~a first? " (buffers:name buffer))))
      (files:save-buffer buffer))
    (parameterize ([%reported reported])
      (%evaluate
        (lambda ()
          (if file?
              (eval-file path)
              (eval-text (document:text (buffers:document buffer)) path)))))
    (unless (unbox reported)
      (echo-area:message! "Evaluated the ~a buffer" (buffers:name buffer)))))

(keys:bind! keys:global "M-:" expression)
(keys:bind! chez-scheme:keymap "C-c C-r" region)
(keys:bind! chez-scheme:keymap "C-c C-k" buffer)
(keys:bind! expression-keymap "RET" exit-expression)
(keys:bind! expression-keymap "C-j" exit-expression)
(keys:bind! expression-keymap "TAB" completion:complete-at-point)
(keys:bind! completion:region-action-keymap "e" region)
(keys:bind! completion:expression-action-keymap "e" region)
(keys:bind! completion:expression-action-keymap "RET" region)
(keys:bind! completion:name-action-keymap "e" region)
(table-set! commands:region-commands region #t)
(add-hook! completion:find-region %expression-name-region)
(advice-add! report %note-report)
