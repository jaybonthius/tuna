#!tuna
(import (views) (web) (test-user) (views-test text))

(define-record-type %page
  (sealed #t)
  (fields client height (mutable answer) placements))

(define (open height)
  (letrec ([page (make-%page
                   (test-user:open-client (lambda (name value) ((%page-answer page) name value)))
                   height
                   (lambda (name value) 'null)
                   (make-eqv-hashtable))])
    page))

(define (client page) (%page-client page))

(define (set-answer! page answer) (%page-answer-set! page answer))

(define (number element name)
  (let ([v (test-user:element-attribute element name)])
    (and v (string->number v))))

(define (view-in sxml view)
  (let ([id (number->string (views:id view))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements sxml "view"))))

;; Drawing the view again, as a page would be sent it, rather than reading
;; the layout's screen, lets a test show a view the layout does not.
(define (view-element page view)
  (let ([c (%page-client page)])
    (web:send-screen! c (views:draw view c) "views")
    (view-in (test-user:screen c) view)))

(define (shown-element page view)
  (view-in (test-user:screen (%page-client page)) view))

(define (shown html)
  (let ([c (test-user:client)])
    (web:send-screen! c html "views")
    (test-user:screen c)))

(define (element-for-no-client view)
  (view-in (shown (views:draw view #f)) view))

(define (line-marks element)
  (map (lambda (l)
         (let ([line (number l "data-line")] [at (number l "data-at")])
           (cons line (if at (list (cons "at" at)) (list (cons "line" line))))))
       (filter (lambda (l) (equal? "line" (test-user:element-attribute l "class")))
               (test-user:elements element "line"))))

(define (spacer element side)
  (find (lambda (s) (equal? side (test-user:element-attribute s "data-spacer")))
        (test-user:elements element "view-spacer")))

(define (spacer-lines element side)
  (let ([s (spacer element side)])
    (if s (list (number s "data-lines")) '())))

(define (drawn page view)
  (let* ([e (view-element page view)] [ls (map car (line-marks e))])
    (list (car ls) (car (last-pair ls)) (length ls) (spacer-lines e "above") (spacer-lines e "below"))))

(define (placement page view)
  (let* ([e (view-element page view)]
         [n (number e "data-placement")]
         [last (hashtable-ref (%page-placements page) (views:id view) #f)]
         [kind (string->symbol (test-user:element-attribute e "data-place-kind"))]
         [item (number e "data-place-item")]
         [at (number e "data-place-at")]
         [place (cond [(and (memq kind '(top center bottom)) at) at] [item item] [else #f])])
    (hashtable-set! (%page-placements page) (views:id view) n)
    (list (if (eqv? last n) 'same 'new) kind (and place (views-test/text:line-of view place)))))

(define %reports 0)

;; The page lays out every line 20 px high: TOP is the line at its top
;; edge and OFFSET the px of it above the edge. A line not drawn lies in
;; a spacer, which names it by its counts, a line per row. The first and
;; last lines wholly in view keep a scroll margin of 2 lines.
(define (report! page view top offset settled? . overrides)
  (apply post-report! page view top offset settled? overrides)
  (test-user:settle))

(define (post-report! page view top offset settled? . overrides)
  (web:post-input! (%page-client page) (apply report-item page view top offset settled? overrides)))

(define (report-item page view top offset settled? . overrides)
  (let* ([e (view-element page view)]
         [marks (line-marks e)]
         [h (%page-height page)]
         [whole-from (+ (if (> offset 1/2) (+ top 1) top) 2)]
         [whole-to (- (+ top (quotient (+ h offset) 20)) 1 2)]
         [mark (lambda (line) (cond [(assv line marks) => cdr] [else (list (cons "line" line))]))]
         [screens (string->number (test-user:element-attribute e "data-drawn-screens"))]
         [wanted-lines (+ (exact (ceiling (/ (* screens h) 20))) 1)])
    (set! %reports (+ %reports 1))
    (map (lambda (field) (or (assoc (car field) overrides) field))
      `(("type" . "scroll") ("view" . ,(views:id view))
        ("placement" . ,(number e "data-placement")) ("report" . ,%reports)
        ("version" . ,(number e "data-version"))
        ("top" . ,(mark top)) ("spacer" . ,(not (assv top marks))) ("fraction" . ,(inexact (/ offset 20)))
        ("left" . ,(mark top)) ("past" . 0) ("sides" . #())
        ("start" . ,(append (mark whole-from) '(("count" . 0))))
        ("end" . ,(append (mark (max whole-from whole-to)) '(("count" . 0))))
        ("atStart" . ,(and (test-user:element-attribute e "data-run-at-start") (= top 1) (= offset 0) #t))
        ("atEnd" . ,(and (test-user:element-attribute e "data-run-at-end") (not (spacer e "below"))
                         (>= (+ top (quotient (+ h offset) 20)) (car (car (last-pair marks)))) #t))
        ("columns" . 80) ("rows" . ,(quotient h 20)) ("pointVisible" . #t) ("lost" . #f)
        ("wanted" . (("aboveLines" . ,wanted-lines) ("aboveChars" . ,(* wanted-lines 80))
                     ("belowLines" . ,wanted-lines) ("belowChars" . ,(* wanted-lines 80))
                     ("side" . ,(exact (ceiling (* screens 80))))))
        ("settled" . ,settled?) ("hand" . #t) ("edge" . "top")))))
