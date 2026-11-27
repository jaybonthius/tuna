(import (tuna) (test) (test-user) (web) (haml))

(define (raised-by who)
  (lambda (e) (and (who-condition? e) (eq? who (condition-who e)))))

(test "screen is the client's last screen, in which a plugin finds its own elements by class"
  (test-user:settle)
  (let ([screens (test-user:elements (test-user:screen) "layout-screen")])
    (check-equal? 1 (length screens))
    (check (string? (test-user:element-attribute (car screens) "data-view")))))

(test "elements are found by one of their classes, in document order, inside one another too"
  (let ([c (test-user:open-client)])
    (web:send-screen! c
      (haml (:div.outer.b (:p.b "one") (:section (:span ([class "x b"]) "two" (:em.b "three")))))
      "Title")
    (let ([found (test-user:elements (test-user:screen c) "b")])
      (check-equal? '(div p span em) (map car found))
      (check-equal? '("onetwothree" "one" "twothree" "three") (map test-user:element-text found))
      (check-equal? '() (test-user:elements (test-user:screen c) "outer b")))
    (web:close-client! c)))

(test "elements-with finds the elements that carry an attribute, whatever its value, in document order"
  (let ([c (test-user:open-client)])
    (web:send-screen! c
      (haml (:div ([data-face "outer"]) (:p "one") (:span ([data-face ""] [title "t"]) "two" (:em ([data-face "inner"]) "three"))))
      "Title")
    (let ([found (test-user:elements-with (test-user:screen c) "data-face")])
      (check-equal? '(div span em) (map car found))
      (check-equal? '("outer" "" "inner") (map (lambda (e) (test-user:element-attribute e "data-face")) found))
      (check-equal? '() (test-user:elements-with (test-user:screen c) "data-missing")))
    (check-raises (raised-by 'test-user:elements-with) (test-user:elements-with "text" "data-face"))
    (check-raises (raised-by 'test-user:elements-with) (test-user:elements-with '(p "x") 'data-face))
    (web:close-client! c)))

(test "what haml writes is read back: escapes, attributes with and without values, void elements and scripts"
  (let ([c (test-user:open-client)])
    (web:send-screen! c
      (haml (:div.all ([data-text "1 < 2 & \"q\" > 0"])
              (:p.text "x > y & z <w>")
              (:br)
              (:input.void ([disabled] [value ""]))
              (:img.void ([src "a.png"]))
              (:script.code "if (a < b && c > d) {}")
              (:style.code "p > em { color: red }")
              "after"))
      "Title")
    (let* ([sxml (test-user:screen c)] [all (car (test-user:elements sxml "all"))])
      (check-equal? "1 < 2 & \"q\" > 0" (test-user:element-attribute all "data-text"))
      (check-equal? #f (test-user:element-attribute all "missing"))
      (check-equal? "x > y & z <w>" (test-user:element-text (car (test-user:elements sxml "text"))))
      (check-equal? '(input img) (map car (test-user:elements sxml "void")))
      (check-equal? "" (test-user:element-attribute (car (test-user:elements sxml "void")) "disabled"))
      (check-equal? "" (test-user:element-attribute (car (test-user:elements sxml "void")) "value"))
      (check-equal? '("if (a < b && c > d) {}" "p > em { color: red }")
                    (map test-user:element-text (test-user:elements sxml "code")))
      (check-equal? "x > y & z <w>if (a < b && c > d) {}p > em { color: red }after" (test-user:element-text all)))
    (web:close-client! c)))

(test "markup haml does not write is refused"
  (let ([c (test-user:open-client)])
    (for-each
      (lambda (markup)
        (web:send-screen! c (string->utf8 markup) "Title")
        (check-raises (raised-by 'html->sxml) (test-user:screen c)))
      '("<p>a&nbsp;b</p>" "<!-- note --><p></p>" "<p>open" "<p class='x'></p>" "</p>" "<p></q>" "<br/>"
        "<script>never closed"))
    (web:close-client! c)))

(test "screen raises for a client given no screen, and the readers take only elements and strings"
  (let ([c (test-user:open-client)])
    (check-raises (raised-by 'test-user:screen) (test-user:screen c))
    (check-raises (raised-by 'test-user:screen) (test-user:screen 'client))
    (check-raises (raised-by 'test-user:title) (test-user:title c))
    (web:close-client! c))
  (check-raises (raised-by 'test-user:elements) (test-user:elements "text" "b"))
  (check-raises (raised-by 'test-user:elements) (test-user:elements '(p "x") 'b))
  (check-raises (raised-by 'test-user:element-text) (test-user:element-text 'p))
  (check-raises (raised-by 'test-user:element-attribute) (test-user:element-attribute '(p "x") 'class)))
