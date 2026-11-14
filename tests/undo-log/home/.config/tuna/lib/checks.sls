#!tuna
(import (buffers) (document) (commands) (undo) (undo-log))

(define (expand path)
  (if (and (>= (string-length path) 2) (string=? (substring path 0 2) "~/"))
      (string-append (getenv "HOME") (substring path 1 (string-length path)))
      path))

(define (write-text! path text)
  (call-with-port (open-file-output-port (expand path) (file-options no-fail))
    (lambda (p) (put-bytevector p (string->utf8 text)))))

(define (read-text path)
  (let ([bytes (call-with-port (open-file-input-port (expand path)) get-bytevector-all)])
    (if (eof-object? bytes) "" (utf8->string bytes))))

(define (exists? path) (file-exists? (expand path)))

(define (log-of path)
  (string-append (undo-log:%log-folder) (expand path) ".ss"))

(define (log-records path)
  (let ([file (log-of path)])
    (if (file-exists? file)
        (call-with-input-file file
          (lambda (p)
            (let loop ([acc '()])
              (let ([d (read p)])
                (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
        '())))

(define (end b) (fx- (document:length (buffers:document b)) 1))

(commands:define-command (type text)
  "Inserts TEXT at the end of the current buffer, joining the previous group as typing does."
  (undo:amalgamate!)
  (let ([b (buffers:current)])
    (buffers:replace! b (end b) (end b) text)))

(commands:define-command (insert position text)
  "Inserts TEXT at POSITION in the current buffer."
  (buffers:replace! (buffers:current) position position text))

(commands:define-command (delete start end)
  "Deletes from START to END in the current buffer."
  (buffers:replace! (buffers:current) start end ""))

(commands:define-command (insert-pausing text)
  "Inserts TEXT at the start, pauses, and inserts it again."
  (let ([b (buffers:current)])
    (buffers:replace! b 1 1 text)
    (sleep-for 0.01)
    (buffers:replace! b 1 1 text)))

(define (file-mode path) (number->string (get-mode path) 8))

(define (log-size path)
  (let ([file (log-of path)])
    (if (file-exists? file) (call-with-port (open-file-input-port file) port-length) 0)))

;; Every test file is under /tmp, where undo-log keeps no log by default;
;; the body sets this again whenever undo-log loads again with this
;; module. Logs go in a folder of a fixed name, so reports that name one
;; read the same in every run.
(set-option! undo-log:keep-log? (lambda (path) #t))
(set-saved! undo-log:%log-folder (string-append (getenv "HOME") "/undo-logs"))
