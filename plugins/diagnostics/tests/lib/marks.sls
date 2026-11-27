#!tuna
(import (buffers) (document) (options) (diagnostics))

(define (text b) (document:text (buffers:document b)))

(define (mode! b on?) (buffers:with-buffer b (options:set-local! diagnostics:mode on?)))

(define (seen d)
  (let ([b (diagnostics:diagnostic-buffer d)])
    (list (if b
              (document:text (buffers:document b) (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d))
              (list (diagnostics:diagnostic-start d) (diagnostics:diagnostic-end d)))
          (diagnostics:diagnostic-severity d) (diagnostics:diagnostic-message d))))

(define (all-seen b) (map seen (diagnostics:in b)))

(define (marks b)
  (let ([doc (buffers:document b)])
    (apply append
      (map (lambda (type)
             (map (lambda (s) (list (document:text doc (car s) (cadr s)) (cdr (assq 'face (caddr s)))
                                    (cdr (assq 'title (caddr s)))))
                  (buffers:spans (buffers:layer b type) 0 (document:length doc))))
           (list diagnostics:error-marks diagnostics:warning-marks diagnostics:info-marks diagnostics:hint-marks)))))

(define (word b s)
  (let ([t (text b)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i (string-length s))) s) (+ i 1) (loop (+ i 1))))))

(define (warn b s message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) (diagnostics:severity warning) message))

(define (err b s message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) (diagnostics:severity error) message))

(define (info b s message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) (diagnostics:severity info) message))
