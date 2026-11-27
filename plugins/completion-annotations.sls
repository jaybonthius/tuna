#!tuna
(import (completion) (commands) (keys) (buffers) (document) (files) (faces) (web) (tables))


;; A command defined at the top level is a plain procedure, with no
;; documentation the kernel keeps.
(define (%command-documentation command)
  (guard (c [(assertion-violation? c) #f])
    (definition-documentation command)))
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
    (lambda (cmd details)
      (let ([keys (or (eq-hashtable-ref found cmd #f)
                      (let ([k (if (commands:command? cmd)
                                   (let ([all (keys:where-is client cmd)]) (if (pair? all) (car all) ""))
                                   "")])
                        (eq-hashtable-set! found cmd k)
                        k))]
            [doc (and (commands:command? cmd) (%command-documentation cmd))])
        (list (cons faces:keyword keys) (cons faces:shadow (if doc (%first-line doc) "")))))))

(define (buffer session)
  (lambda (b details)
    (if (buffers:live? b)
        (list (cons faces:shadow (number->string (%characters b)))
              (cons faces:shadow (let ([path (files:path b)]) (if path (files:abbreviated-path path) ""))))
        '())))

(define (%characters b)
  (let ([doc (buffers:document b)])
    (document:offset doc (fx- (document:length doc) 1) (document:unit characters))))

;; As Emacs's file-size-human-readable, so sizes read as ls -lh writes
;; them.
(define (%size-text bytes)
  (let loop ([size (inexact bytes)] [units '("" "k" "M" "G" "T" "P" "E")])
    (if (and (>= size 1024.) (pair? (cdr units)))
        (loop (/ size 1024.) (cdr units))
        (let ([fraction (- size (floor size))])
          (if (and (< size 10.) (>= fraction .05) (< fraction .95))
              (format "~,1f~a" size (car units))
              (format "~a~a" (exact (round size)) (car units)))))))

(define %units
  (list (cons "Y" 31556952) (cons "M" 2629746) (cons "w" 604800) (cons "d" 86400) (cons "h" 3600)
        (cons "m" 60) (cons "s" 1)))

;; As Emacs's seconds-to-string with two abbreviated units, as
;; Marginalia writes an age.
(define (%age-text seconds)
  (if (< seconds 1/2)
      "0s ago"
      (let loop ([units %units])
        (let ([unit (car units)] [smaller (cdr units)])
          (if (and (pair? smaller) (< seconds (cdr unit)))
              (loop smaller)
              (let* ([whole (exact (floor (/ seconds (cdr unit))))]
                     [rest (and (pair? smaller)
                                (exact (round (/ (- seconds (* whole (cdr unit))) (cdar smaller)))))])
                (cond
                  [(not rest) (format "~a~a ago" (exact (round seconds)) (car unit))]
                  [(> rest 0) (format "~a~a ~a~a ago" whole (car unit) rest (caar smaller))]
                  [else (format "~a~a ago" whole (car unit))])))))))

(define %month-names '#("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (%two-digits n) (if (< n 10) (format "0~a" n) (number->string n)))

;; Marginalia's marginalia-max-relative-age.
(define %relative-age (* 14 86400))

(define (%time-text now seconds)
  (if (< (- now seconds) %relative-age)
      (%age-text (max 0 (- now seconds)))
      (let ([d (time-utc->date (make-time 'time-utc 0 seconds))]
            [year (date-year (time-utc->date (make-time 'time-utc 0 now)))])
        (if (> year (date-year d))
            (format "~a ~a ~a" (date-year d) (vector-ref %month-names (fx- (date-month d) 1)) (%two-digits (date-day d)))
            (format "~a ~a ~a:~a" (vector-ref %month-names (fx- (date-month d) 1)) (%two-digits (date-day d))
                    (%two-digits (date-hour d)) (%two-digits (date-minute d)))))))

(define (file session)
  (let ([now (time-second (current-time 'time-utc))])
    (lambda (path details)
      (if (pair? details)
          (list (cons faces:shadow (%size-text (car details))) (cons faces:shadow (%time-text now (cdr details))))
          '()))))

(define (kind session)
  (lambda (value details)
    (if (symbol? details) (list (cons faces:shadow (symbol->string details))) '())))

(tables:set! completion:annotators completion:command-category command)
(tables:set! completion:annotators completion:buffer-category buffer)
(tables:set! completion:annotators completion:file-category file)
(tables:set! completion:annotators completion:name-category kind)
(tables:set! completion:annotators completion:identifier-category kind)
