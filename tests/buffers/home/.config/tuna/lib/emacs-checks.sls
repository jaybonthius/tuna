#!tuna
(import (buffers) (document))

(buffers:define-layer before (sticky before))
(buffers:define-layer after (sticky after))
(buffers:define-layer both (sticky both))
(buffers:define-layer neither (sticky neither))
(buffers:define-layer before-evaporating (sticky before) (evaporate))
(buffers:define-layer after-evaporating (sticky after) (evaporate))
(buffers:define-layer both-evaporating (sticky both) (evaporate))
(buffers:define-layer neither-evaporating (sticky neither) (evaporate))
(buffers:define-layer text-before (travels) (sticky before))
(buffers:define-layer text-after (travels) (sticky after))
(buffers:define-layer text-both (travels) (sticky both))
(buffers:define-layer text-neither (travels) (sticky neither))

(define (fixture name)
  (with-input-from-file (string-append (getenv "HOME") "/emacs/" name) read))

(define made 0)

(define (fresh-buffer size)
  (set! made (+ made 1))
  (buffers:make (format "emacs-~a" made) (make-string size #\x)))

(define (overlay-type mode evaporate)
  (if (= evaporate 1)
      (case mode [(before) before-evaporating] [(after) after-evaporating] [(both) both-evaporating] [else neither-evaporating])
      (case mode [(before) before] [(after) after] [(both) both] [else neither])))

(define (text-type mode)
  (case mode [(before) text-before] [(after) text-after] [(both) text-both] [else text-neither]))

(define (end-of b) (document:length (buffers:document b)))

;; Emacs counts positions from 1 within the text, and a buffer from 1 in
;; its root, so both differ from the recording's positions by one.
(define (overlays-match? recording)
  (let* ([run (car recording)] [b (fresh-buffer (car run))] [spans (cadr run)])
    (let loop ([spans spans] [k 0])
      (unless (null? spans)
        (let ([s (car spans)])
          (buffers:add-span! (buffers:layer b (overlay-type (caddr s) (cadddr s))) (+ (car s) 1) (+ (cadr s) 1) k)
          (loop (cdr spans) (+ k 1)))))
    (for-each
      (lambda (op)
        (case (car op)
          [(insert) (buffers:replace! b (+ (cadr op) 1) (+ (cadr op) 1) (make-string (caddr op) #\y))]
          [else (buffers:replace! b (+ (cadr op) 1) (+ (caddr op) 1) "")]))
      (caddr run))
    (let ([found (apply append (map (lambda (l) (buffers:spans l 0 (end-of b))) (buffers:layers b)))])
      (equal? (map (lambda (k)
                     (let ([s (memp (lambda (s) (= (caddr s) k)) found)])
                       (and s (list (- (car (car s)) 1) (- (cadr (car s)) 1)))))
                   (iota (length spans)))
              (cadr recording)))))

(define (text-properties-match? recording)
  (let* ([run (car recording)] [b (fresh-buffer (car run))] [l (buffers:layer b (text-type (cadr run)))])
    (for-each (lambda (s) (buffers:add-span! l (+ (car s) 1) (+ (cadr s) 1) (caddr s))) (caddr run))
    (let loop ([ops (cadddr run)] [kills '()])
      (unless (null? ops)
        (let ([op (car ops)])
          (case (car op)
            [(type)
             (buffers:replace! b (+ (cadr op) 1) (+ (cadr op) 1) (make-string (caddr op) #\y))
             (loop (cdr ops) kills)]
            [(insert)
             (buffers:replace! b (+ (cadr op) 1) (+ (cadr op) 1) (make-string (caddr op) #\y) '())
             (loop (cdr ops) kills)]
            [(cut)
             (let ([start (+ (cadr op) 1)] [end (+ (caddr op) 1)])
               (let ([kill (list start (- end start) (buffers:travelling-spans b start end))])
                 (buffers:replace! b start end "")
                 (loop (cdr ops) (cons kill kills))))]
            [(undo)
             (let ([kill (car kills)])
               (buffers:replace! b (car kill) (car kill) (make-string (cadr kill) #\y) (caddr kill))
               (loop (cdr ops) (cdr kills)))]
            [else
             (let ([kill (car kills)] [at (+ (cadr op) 1)])
               (buffers:replace! b at at (make-string (cadr kill) #\y) (caddr kill))
               (loop (cdr ops) kills))]))))
    (let ([spans (buffers:spans l 0 (end-of b))])
      (equal? (map (lambda (i)
                     (let ([s (memp (lambda (s) (and (<= (car s) (+ i 1)) (< (+ i 1) (cadr s)))) spans)])
                       (and s (caddr (car s)))))
                   (iota (- (end-of b) 2)))
              (cadr recording)))))

(define (overlay-results) (map overlays-match? (fixture "overlays.ss")))

(define (text-property-results) (map text-properties-match? (fixture "text-properties.ss")))
