#!tuna
(import (completion) (commands) (keys) (buffers) (document) (files) (faces) (web))

(define (%first-line s)
  (let ([n (string-length s)])
    (let loop ([i 0])
      (cond
        [(fx= i n) s]
        [(char=? (string-ref s i) #\newline) (substring s 0 i)]
        [else (loop (fx+ i 1))]))))

;; keys:where-is walks every keymap, so each command's keys are looked up
;; once per session, and only for the rows drawn.
(define (command session)
  (let ([client (web:current-client)] [found (make-eq-hashtable)])
    (lambda (cmd)
      (let ([keys (or (eq-hashtable-ref found cmd #f)
                      (let ([k (if (commands:command? cmd)
                                   (let ([all (keys:where-is client cmd)]) (if (pair? all) (car all) ""))
                                   "")])
                        (eq-hashtable-set! found cmd k)
                        k))]
            [doc (and (commands:command? cmd) (documentation cmd))])
        (list (cons faces:keyword keys) (cons faces:shadow (if doc (%first-line doc) "")))))))

(define (buffer session)
  (lambda (b)
    (if (buffers:live? b)
        (list (cons faces:shadow (number->string (%characters b)))
              (cons faces:shadow (let ([path (files:path b)]) (if path (files:abbreviated-path path) ""))))
        '())))

(define (%characters b)
  (let ([doc (buffers:document b)])
    (document:offset doc (fx- (document:length doc) 1) (document:unit characters))))

(table-set! completion:annotators completion:command-category command)
(table-set! completion:annotators completion:buffer-category buffer)
