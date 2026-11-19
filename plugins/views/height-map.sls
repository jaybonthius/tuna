(library (views height-map)
  (export make-height-map height-map? height-map-length height-map-total height-map-px height-map-position
          height-map-stretch height-map-measure! height-map-replace! height-map-set-metrics! height-map-stretches)
  (import (chezscheme))

  ;; An estimate keeps the px it was given when made, and a stretch cut in
  ;; two shares its px by tokens, so measuring some items never moves
  ;; another position's px: a browser scrolled into a spacer is told where
  ;; it is by the px the spacer was drawn with.
  (define-record-type stretch
    (sealed #t)
    (fields tokens px measured?))

  (define-record-type branch
    (sealed #t)
    (fields left right height tokens px))

  (define (tokens t) (if (stretch? t) (stretch-tokens t) (branch-tokens t)))
  (define (height t) (if (stretch? t) 0 (branch-height t)))
  (define (px-of t) (if (stretch? t) (stretch-px t) (branch-px t)))

  (define (make-node a b)
    (make-branch a b (fx+ 1 (fxmax (height a) (height b))) (fx+ (tokens a) (tokens b)) (fl+ (px-of a) (px-of b))))

  (define (rotate-left t)
    (let ([r (branch-right t)])
      (make-node (make-node (branch-left t) (branch-left r)) (branch-right r))))

  (define (rotate-right t)
    (let ([l (branch-left t)])
      (make-node (branch-left l) (make-node (branch-right l) (branch-right t)))))

  (define (balance a b)
    (let ([ha (height a)] [hb (height b)])
      (cond
        [(fx> ha (fx+ hb 1))
         (let ([a (if (fx> (height (branch-right a)) (height (branch-left a))) (rotate-left a) a)])
           (rotate-right (make-node a b)))]
        [(fx> hb (fx+ ha 1))
         (let ([b (if (fx> (height (branch-left b)) (height (branch-right b))) (rotate-right b) b)])
           (rotate-left (make-node a b)))]
        [else (make-node a b)])))

  (define (join a b)
    (cond
      [(not a) b]
      [(not b) a]
      [(fx> (height a) (fx+ (height b) 1)) (balance (branch-left a) (join (branch-right a) b))]
      [(fx> (height b) (fx+ (height a) 1)) (balance (join a (branch-left b)) (branch-right b))]
      [else (make-node a b)]))

  (define (split t at)
    (cond
      [(fx<= at 0) (values #f t)]
      [(fx>= at (tokens t)) (values t #f)]
      [(stretch? t)
       (let* ([n (stretch-tokens t)] [px (fl* (stretch-px t) (fl/ (fixnum->flonum at) (fixnum->flonum n)))])
         (values (make-stretch at px #f) (make-stretch (fx- n at) (fl- (stretch-px t) px) #f)))]
      [else
       (let* ([l (branch-left t)] [n (tokens l)])
         (if (fx<= at n)
             (let-values ([(a b) (split l at)])
               (values a (join b (branch-right t))))
             (let-values ([(a b) (split (branch-right t) (fx- at n))])
               (values (join l a) b))))]))

  (define-record-type (height-map new-height-map height-map?)
    (sealed #t)
    (fields (mutable tree) (mutable line-height) (mutable row-chars) (mutable whole-px) (mutable whole-count)))

  (define (node-advance m)
    (let ([n (height-map-whole-count m)])
      (if (fx= n 0) (height-map-line-height m) (fl/ (height-map-whole-px m) (fixnum->flonum n)))))

  ;; COUNT gives the newlines, characters of text, whole nodes and other
  ;; nodes from one position to another. Wrapped text takes a row for
  ;; each ROW-CHARS characters; lines shorter than half a row count a row
  ;; each, so short lines do not count their characters as well. A node
  ;; that opens into its children adds its margins and borders, about a
  ;; row.
  (define (estimate m count start end)
    (let-values ([(newlines chars nodes openings) (count start end)])
      (let* ([row-chars (height-map-row-chars m)]
             [newlines (fixnum->flonum newlines)]
             [rows (fl+ (fixnum->flonum openings)
                        (if row-chars
                            (fl+ newlines (flmax 0.0 (fl/ (fl- (fixnum->flonum chars) (fl* newlines (fl/ (fixnum->flonum row-chars) 2.0)))
                                                          (fixnum->flonum row-chars))))
                            newlines))])
        (make-stretch (fx- end start)
                      (fl+ (fl* rows (height-map-line-height m)) (fl* (fixnum->flonum nodes) (node-advance m)))
                      #f))))

  ;; ROW-CHARS is #f for text that does not wrap.
  (define (make-height-map length line-height row-chars count)
    (let ([m (new-height-map #f line-height row-chars 0.0 0)])
      (height-map-tree-set! m (estimate m count 0 length))
      m))

  ;; New estimates use them; those made before keep their px.
  (define (height-map-set-metrics! m line-height row-chars)
    (height-map-line-height-set! m line-height)
    (height-map-row-chars-set! m row-chars))

  (define (height-map-length m) (tokens (height-map-tree m)))

  (define (height-map-total m) (px-of (height-map-tree m)))

  (define (height-map-px m p)
    (let loop ([t (height-map-tree m)] [p (fxmax 0 p)] [above 0.0])
      (cond
        [(fx>= p (tokens t)) (fl+ above (px-of t))]
        [(stretch? t)
         (fl+ above (fl* (stretch-px t) (fl/ (fixnum->flonum p) (fixnum->flonum (stretch-tokens t)))))]
        [else
         (let ([l (branch-left t)])
           (if (fx< p (tokens l))
               (loop l p above)
               (loop (branch-right t) (fx- p (tokens l)) (fl+ above (px-of l)))))])))

  (define (height-map-position m px)
    (let loop ([t (height-map-tree m)] [px (flmax 0.0 px)] [start 0])
      (if (stretch? t)
          (let ([own (stretch-px t)] [n (stretch-tokens t)])
            (fx+ start
                 (if (fl> own 0.0)
                     (fxmin (fx- n 1) (fxmax 0 (flonum->fixnum (flfloor (fl* (fixnum->flonum n) (flmin 1.0 (fl/ px own)))))))
                     0)))
          (let* ([l (branch-left t)] [own (px-of l)])
            (if (fl< px own)
                (loop l px start)
                (loop (branch-right t) (fl- px own) (fx+ start (tokens l))))))))

  (define (height-map-stretch m p)
    (let loop ([t (height-map-tree m)] [p (fxmax 0 (fxmin p (fx- (height-map-length m) 1)))] [start 0])
      (if (stretch? t)
          (values start (fx+ start (stretch-tokens t)) (stretch-px t) (stretch-measured? t))
          (let ([l (branch-left t)])
            (if (fx< p (tokens l))
                (loop l p start)
                (loop (branch-right t) (fx- p (tokens l)) (fx+ start (tokens l))))))))

  ;; WHOLE? says the px are a whole node's, which later estimates of
  ;; whole nodes follow.
  (define (height-map-measure! m start end px whole?)
    (when (fx< start end)
      (let*-values ([(a rest) (split (height-map-tree m) start)]
                    [(old b) (split rest (fx- end start))])
        (height-map-tree-set! m (join (join a (make-stretch (fx- end start) px #t)) b))
        (when whole?
          (height-map-whole-px-set! m (fl+ (height-map-whole-px m) px))
          (height-map-whole-count-set! m (fx+ (height-map-whole-count m) 1))))))

  ;; A measured stretch the edit touches no longer measures anything, so it
  ;; goes whole; an estimate the edit cuts keeps the px of its untouched
  ;; parts, as split shares them, so an edit moves no position before it
  ;; and COUNT, which reads the document after the change, reads only what
  ;; changed.
  (define (height-map-replace! m start old-end new-end count)
    (let*-values ([(from first-end first-px first-measured?) (height-map-stretch m start)]
                  [(last-start to last-px last-measured?) (height-map-stretch m (fxmax start (fx- old-end 1)))]
                  [(cut-start) (if first-measured? from start)]
                  [(cut-end) (if last-measured? to old-end)]
                  [(a rest) (split (height-map-tree m) cut-start)]
                  [(old b) (split rest (fx- cut-end cut-start))])
      (let ([new-cut-end (fx+ cut-end (fx- new-end old-end))])
        (height-map-tree-set! m
          (if (fx> new-cut-end cut-start)
              (join (join a (estimate m count cut-start new-cut-end)) b)
              (join a b))))))

  (define (height-map-stretches m)
    (let loop ([t (height-map-tree m)] [start 0] [acc '()])
      (if (stretch? t)
          (cons (list start (fx+ start (stretch-tokens t)) (stretch-px t) (stretch-measured? t)) acc)
          (let ([l (branch-left t)])
            (loop l start (loop (branch-right t) (fx+ start (tokens l)) acc)))))))
