(import (tuna) (test) (test-browser) (cdp page) (views) (layout) (buffers) (document) (indentation) (options))

(define page (test-browser:open (page-options [width 1200] [height 900] [color-scheme (color-scheme light)])))

(define b (buffers:make (buffers:free-name "tabbed") "\tx\n"))

(layout:switch-to-buffer b)

(define v (layout:selected-view))

(views:set-point! v 2)
(test-browser:wait-for-applied page)

(define (drawn)
  (test-browser:call
    (lambda ()
      (let ([lines (car (page-query page (format "#view-~a .view-lines" (views:id v))))]
            [cursor (car (page-query page (format "#view-~a .primary" (views:id v))))])
        (list (element-style lines "tab-size")
              (- (rectangle-x (element-box cursor)) (rectangle-x (element-box lines))))))))

(test "a view draws its buffer's tabs views:tab-width columns wide, read in the buffer's scope"
  (let ([eight (drawn)])
    (check-equal? "8" (car eight))
    (buffers:with-buffer b (options:set-local! views:tab-width 4))
    (test-browser:wait-for-applied page)
    (let ([four (drawn)])
      (check-equal? "4" (car four))
      (check (< (abs (- (* 2 (cadr four)) (cadr eight))) 2)))))

(test "a value set in one view draws that view's tabs at its width, and a column counted in that view, as a command run there counts it, agrees"
  (views:set-option! v views:tab-width 2)
  (views:set-point! v 1)
  (test-browser:wait-for-applied page)
  (check-equal? "2" (car (drawn)))
  (check-equal? '(2 4) (list (views:with-view v (indentation:column b 2)) (indentation:column b 2))))
