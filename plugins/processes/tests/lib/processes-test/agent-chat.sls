#!tuna
(import (processes) (buffers) (document) (saved))

(saved:define-saved agent #f (lambda (v) (or (not v) (pair? v))))

(define %self (current-owner))
(define kept (buffers:find "*pi*"))
(define transcript (or kept (buffers:make "*pi*" "")))

(define (add-line! line end)
  (unless (eof-object? line)
    (let ([text-end (- (document:length (buffers:document transcript)) 1)])
      (buffers:replace! transcript text-end text-end (string-append line "\n")))
    (saved:set! agent (cons (car (agent)) end))))

(define (follow! process from)
  (processes:set-buffer! process transcript)
  (unless (= from (call-as-owner %self
                    (lambda ()
                      (processes:attach! process from (processes:line-receiver from add-line!)
                        (lambda (status) (saved:set! agent #f))))))
    (processes:send! process "{\"type\":\"get_messages\"}\n")))

(define (chat)
  (let ([process (processes:start-for-user "pi" '("--mode" "rpc")
                   (processes:options [separate-stderr #t]))])
    (saved:set! agent (cons (processes:id process) 0))
    (follow! process 0)))

(cond
  [(and (agent) (processes:find (car (agent))))
   => (lambda (process) (follow! process (if kept (cdr (agent)) 0)))])
