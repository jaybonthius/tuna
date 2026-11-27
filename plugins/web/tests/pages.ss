(import (tuna) (test) (test-runner) (web) (haml) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (named sxml name) (web-test/http:elements-named sxml name))

(define (screen-of sxml)
  (find (lambda (main) (equal? "screen" (web-test/http:element-attribute main "id"))) (named sxml 'main)))

(define (drawing ended)
  (ended)
  (for-each (lambda (client) (web:send-screen! client (haml (:p "drawn")) "drawn - Tuna")) (web:clients)))

(test "a page declares that it suits light and dark, so the browser paints the device's background first"
  (let ([meta (find (lambda (m) (equal? "color-scheme" (web-test/http:element-attribute m "name")))
                    (named (web-test/http:page-markup (web-test/http:page)) 'meta))])
    (check-equal? "light dark" (web-test/http:element-attribute meta "content"))))

(test "a page served before any screen carries an empty screen"
  (check-equal? '(main (\x40; (id "screen"))) (screen-of (web-test/http:page-markup (web-test/http:page)))))

(test "a page carries the screen and title the batch that added its client drew, and its stream sends neither again"
  (advice-add! batch-ended drawing)
  (let* ([p (web-test/http:page)] [sxml (web-test/http:page-markup p)])
    (check-equal? '("drawn") (map web-test/http:element-text (named (screen-of sxml) 'p)))
    (check-equal? '("drawn - Tuna") (map web-test/http:element-text (named sxml 'title)))
    (web-test/http:connect! p)
    (check-equal? 'timeout (web-test/http:next p 0.2)))
  (advice-remove! batch-ended drawing))

(test "a page ends its screen with the event tuna-first-screen, which an early script acts on before the first paint"
  (let* ([sxml (web-test/http:page-markup (web-test/http:page))]
         [body (car (named sxml 'body))]
         [after-screen (cdr (memq (screen-of sxml) body))])
    (check-equal? '(script) (map car after-screen))
    (check-equal? "document.dispatchEvent(new Event(\"tuna-first-screen\"))" (web-test/http:element-text (car after-screen)))))
