(library (console input)
  (export read-form-text)
  (import (chezscheme) (only (tuna) suspend))

  ;; Chez creates this library once per process, so every load of (console)
  ;; shares one port and one reading thread: a reload neither loses what
  ;; the port has buffered nor starts a second reader. The port lives as
  ;; long as the process, since collecting it would close standard input.
  ;; Chez's console port is not used: a read holds it while waiting, and
  ;; the main thread writes to it.
  (define in (transcoded-port (standard-input-port (buffer-mode block)) (native-transcoder)))
  (define mutex (make-mutex))
  (define asked (make-condition))
  (define asked? #f)
  (define next-form #f)
  (define waiting #f)
  (define reader #f)

  (define busy (list 'busy))

  ;; A cancel can land anywhere in code on the main thread, so the main
  ;; thread holds the mutex only with interrupts disabled. A blocked
  ;; acquire with interrupts disabled would keep a collection waiting for
  ;; the main thread, so it only tries the mutex, which the reader holds
  ;; for a few instructions at a time.
  (define-syntax with-mutex-on-main-thread
    (syntax-rules ()
      [(_ e1 e2 ...)
       (let retry ()
         (let ([v (with-interrupts-disabled
                    (if (mutex-acquire mutex #f)
                        (let ([v (begin e1 e2 ...)])
                          (mutex-release mutex)
                          v)
                        busy))])
           (if (eq? v busy) (retry) v)))]))

  ;; The form stays in next-form until a running task takes it, so a form
  ;; read for a console that unloads meanwhile goes to the next console
  ;; loaded. The reader starts on the first request, once the
  ;; configuration's task ends or pauses, so that it inherits the signal
  ;; mask the configuration set.
  (define (read-form-text)
    (suspend
      (lambda (resume)
        (unless reader (set! reader (fork-thread read-forms)))
        (when (with-mutex-on-main-thread
                (or next-form
                    (begin
                      (set! waiting resume)
                      (unless asked?
                        (set! asked? #t)
                        (condition-signal asked))
                      #f)))
          (resume void))))
    (let ([next (with-mutex-on-main-thread
                  (let ([next next-form])
                    (set! next-form #f)
                    next))])
      (if next (next) (read-form-text))))

  (define (read-forms)
    (let loop ()
      (with-mutex mutex
        (let wait ()
          (unless asked?
            (condition-wait asked mutex)
            (wait))))
      (let* ([next (guard (c [#t (lambda () (raise c))])
                     (let ([text (form-text (read in))]) (lambda () text)))]
             [resume (with-mutex mutex
                       (set! next-form next)
                       (set! asked? #f)
                       (let ([resume waiting])
                         (set! waiting #f)
                         resume))])
        (when resume (resume void)))
      (loop)))

  ;; The console reads the text back, so it must read as the same datum:
  ;; nothing elided, shared structure labelled, gensyms in full.
  (define (form-text x)
    (if (eof-object? x)
        x
        (parameterize ([print-graph #t] [print-level #f] [print-length #f] [print-gensym #t])
          (format "~s" x)))))
