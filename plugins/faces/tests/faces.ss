(import (tuna) (test) (test-user) (web) (tables) (buffers) (views) (faces))

(buffers:define-layer highlights)

(define buffer (buffers:make "greet.scm" "(define name \"Tuna\")\n"))

(define view (views:make buffer))

(define (faced)
  (let* ([c (test-user:client)] [id (number->string (views:id view))])
    (web:send-screen! c (views:draw view c) "faces")
    (let* ([drawn (find (lambda (e) (equal? id (test-user:element-attribute e "data-view"))) (test-user:elements (test-user:screen c) "view"))]
           [all (test-user:elements-with drawn "data-face")]
           [inner? (lambda (e) (exists (lambda (o) (and (not (eq? o e)) (memq e (test-user:elements-with o "data-face")))) all))])
      (map (lambda (e)
             (list (map (lambda (x) (test-user:element-attribute x "data-face")) (test-user:elements-with e "data-face"))
                   (test-user:element-text e)))
           (filter (lambda (e) (not (inner? e))) all)))))

(test "a face is a name, defined by the plugin as a value, so code names it by identifier"
  (check-equal? '(keyword keyword.return diagnostic.error function.builtin) (list faces:keyword faces:keyword.return faces:diagnostic.error faces:function.builtin))
  (check-equal? '(diagnostic.unnecessary diagnostic.deprecated) (list faces:diagnostic.unnecessary faces:diagnostic.deprecated))
  (check-equal? '(variable.definition string.documentation constructor label)
                (list faces:variable.definition faces:string.documentation faces:constructor faces:label)))

(test "a highlighter's spans name faces, and views draws each as data-face"
  (buffers:set-spans! (buffers:layer buffer highlights) 0 22
    (list (list 2 8 (list (cons 'face faces:keyword))) (list 14 20 (list (cons 'face faces:string)))))
  (check-equal? '((("keyword") "define") (("string") "\"Tuna\"")) (faced)))

(test "a list of faces draws as nested elements, the first innermost, so its rules win"
  (buffers:set-spans! (buffers:layer buffer highlights) 0 22
    (list (list 2 8 (list (cons 'face (list 'spell.misspelled faces:keyword))))
          (list 14 20 (list (cons 'face (list faces:markup.strong faces:markup.italic))))))
  (check-equal? '((("keyword" "spell.misspelled") "define") (("markup.italic" "markup.strong") "\"Tuna\"")) (faced)))

(test "a face the face entry draws as nothing adds no element, in a list as alone"
  (let* ([face-attributes (tables:ref views:span-properties 'face #f)]
         [quiet (lambda (face) (if (eq? face 'spell.misspelled) '() (face-attributes face)))])
    (tables:set! views:span-properties 'face quiet)
    (buffers:set-spans! (buffers:layer buffer highlights) 0 22
      (list (list 2 8 (list (cons 'face (list 'spell.misspelled faces:keyword)))) (list 14 20 (list (cons 'face 'spell.misspelled)))))
    (check-equal? '((("keyword") "define")) (faced))
    (tables:set! views:span-properties 'face face-attributes)))

(test "the plugin adds faces.css to the stylesheets; an unload takes the entry back, and a new instance registers its own"
  (check-equal? "faces/faces.css" (tables:ref web:stylesheets 'faces #f))
  (let ([old (module-owner '(faces))])
    (unload-owner! old)
    (check-equal? #f (tables:ref web:stylesheets 'faces #f))
    (load-module! '(faces))
    (check-equal? (list #f #t) (list (owner-live? old) (eq? (tables:owner web:stylesheets 'faces) (module-owner '(faces)))))))
