(import (tuna) (test) (test-runner) (web) (haml) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (titles sxml) (map web-test/http:element-text (web-test/http:elements-named sxml 'title)))

(define (patched-titles event)
  (and (eq? 'patch (car event)) (not (cadr event)) (titles (cadddr event))))

(define p (web-test/http:page))

(define c #f)

(test "a page served before any screen is titled with the program's name"
  (check-equal? '("Tuna") (titles (web-test/http:page-markup p))))

(test "a screen given with another title retitles the page without a reload, before the screen"
  (web-test/http:connect! p)
  (set! c (car (web:clients)))
  (web:send-screen! c (haml (:p "one")) "notes.org - Tuna")
  (let ([events (web-test/http:take p 2)])
    (check-equal? '("notes.org - Tuna") (patched-titles (car events)))
    (check-equal? '(screen 1 0 ((p "one"))) (cadr events)))
  (web-test/http:confirm! p 1))

(test "the same title again sends no title, whatever the screen"
  (web:send-screen! c (haml (:p "two")) "notes.org - Tuna")
  (check-equal? '(screen 2 0 ((p "two"))) (web-test/http:next p))
  (web-test/http:confirm! p 2))

(test "a new title goes even when the screen is the one last sent, as text, whatever it holds"
  (web:send-screen! c (haml (:p "two")) "<a> & b")
  (check-equal? '("<a> & b") (patched-titles (web-test/http:next p)))
  (check-equal? 'timeout (web-test/http:next p 0.2)))

(test "each client has its own title"
  (let ([q (web-test/http:page)])
    (web-test/http:connect! q)
    (let ([d (car (remq c (web:clients)))])
      (web:send-screen! d (haml (:p "two")) "mail - Tuna")
      (let ([events (web-test/http:take q 2)])
        (check-equal? '("mail - Tuna") (patched-titles (car events)))
        (check-equal? '(screen 1 0 ((p "two"))) (cadr events))))
    (check-equal? 'timeout (web-test/http:next p 0.2))))

(test "web:send-screen! takes a string as the title"
  (check-raises (lambda (e) (and (who-condition? e) (eq? 'web:send-screen! (condition-who e))))
    (web:send-screen! c (haml (:p "x")) 'title)))
