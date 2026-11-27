(import (tuna) (test) (options) (buffers) (commands) (ask))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (reader answer asked)
  (lambda (question . rest) (set-box! asked (cons question (unbox asked))) answer))

(test "until a plugin fills its reader, each question raises"
  (check-raises (raised? 'ask:file-name-reader "no reader is loaded") (ask:file-name "Find file: "))
  (check-raises (raised? 'ask:line-reader "no reader is loaded") (ask:line "Rename session to: "))
  (check-raises (raised? 'ask:number-reader "no reader is loaded") (ask:number "Columns: "))
  (check-raises (raised? 'ask:yes-or-no-reader "no reader is loaded") (ask:yes-or-no? "Exit anyway? "))
  (check-raises (raised? 'ask:y-or-n-reader "no reader is loaded") (ask:y-or-n? "Save it? "))
  (check-raises (raised? 'ask:choice-reader "no reader is loaded") (ask:choice "Action: " (list (cons "Rename" 'rename))))
  (check-raises (raised? 'ask:line-with-candidates-reader "no reader is loaded")
    (ask:line-with-candidates "Identifier: " (list "car" "cdr"))))

(test "each question calls its reader with the question and returns its answer"
  (let ([asked (box '())])
    (options:with ([ask:file-name-reader (reader "/tmp/notes.txt" asked)]
                   [ask:line-reader (reader "notes" asked)]
                   [ask:number-reader (reader 80 asked)]
                   [ask:yes-or-no-reader (reader #t asked)]
                   [ask:y-or-n-reader (reader #f asked)])
      (check-equal? "/tmp/notes.txt" (ask:file-name "Find file: "))
      (check-equal? "notes" (ask:line "Rename session to: "))
      (check-equal? 80 (ask:number "Columns: "))
      (check-equal? #t (ask:yes-or-no? "Exit anyway? "))
      (check-equal? #f (ask:y-or-n? "Save it? ")))
    (check-equal? '("Save it? " "Exit anyway? " "Columns: " "Rename session to: " "Find file: ") (unbox asked))))

(test "a line's reader gets its default, or #f"
  (options:with ([ask:line-reader (lambda (question default) (list question default))])
    (check-equal? '("Rename to: " "notes") (ask:line "Rename to: " "notes"))
    (check-equal? '("Rename to: " #f) (ask:line "Rename to: "))))

(test "a choice's reader gets the choices as given, annotated ones included, and its answer is the value picked"
  (let ([choices (list (cons "Rename" 'rename) (vector "Extract" 'extract "method"))])
    (options:with ([ask:choice-reader (lambda (question choices) (list question choices))])
      (check-equal? (list "Action: " choices) (ask:choice "Action: " choices)))
    (options:with ([ask:choice-reader (lambda (question choices) (cdr (car choices)))])
      (check-equal? 'rename (ask:choice "Action: " choices)))))

(test "a line with candidates gets its reader the candidates, a list or a procedure, and its default or #f"
  (options:with ([ask:line-with-candidates-reader list])
    (check-equal? '("Identifier: " ("car" "cdr") #f) (ask:line-with-candidates "Identifier: " (list "car" "cdr")))
    (check-equal? '("Identifier: " ("car" "cdr") "car") (ask:line-with-candidates "Identifier: " (list "car" "cdr") "car"))
    (let ([candidates (lambda (input) (list input))])
      (check-equal? (list "Identifier: " candidates #f) (ask:line-with-candidates "Identifier: " candidates)))))

(test "ask:file-name passes a starting folder to its reader when given one"
  (options:with ([ask:file-name-reader (lambda (question . folder) (cons question folder))])
    (check-equal? '("Copy notes.txt to: " "/home/ada/archive/") (ask:file-name "Copy notes.txt to: " "/home/ada/archive/"))
    (check-equal? '("Find file: ") (ask:file-name "Find file: "))))

(test "arguments are checked before any reader is called"
  (check-raises (raised? 'ask:y-or-n? "not a string") (ask:y-or-n? 'save))
  (check-raises (raised? 'ask:yes-or-no? "not a string") (ask:yes-or-no? 'save))
  (check-raises (raised? 'ask:number "not a string") (ask:number 'columns))
  (check-raises (raised? 'ask:line "not a string") (ask:line 'name))
  (check-raises (raised? 'ask:line "neither a string nor #f") (ask:line "Name: " 'notes))
  (check-raises (raised? 'ask:choice "not a list of choices: pairs of a label and a value, or vectors of a label, a value and an annotation")
    (ask:choice "Action: " (list 'rename)))
  (check-raises (raised? 'ask:choice "not a list of choices: pairs of a label and a value, or vectors of a label, a value and an annotation")
    (ask:choice "Action: " (list (vector "Extract" 'extract))))
  (check-raises (raised? 'ask:line-with-candidates "neither a list of strings nor a procedure")
    (ask:line-with-candidates "Identifier: " (vector "car")))
  (check-raises (raised? 'ask:file-name "not a string") (ask:file-name "Copy to: " 'home))
  (check-raises (raised? 'ask:file-name "not a string") (ask:file-name 'question)))

(test "with no writer set, ask:message is a warning that report writes, after which the caller goes on"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (check-equal? 'went-on (begin (ask:message "Copied 2 files") 'went-on))
    (advice-remove! report keep)
    (check-equal? 1 (length reported))
    (check ((raised? 'ask:message "Copied 2 files") (car reported)))
    (check (warning? (car reported)))))

(test "ask:message tells the user a text through ask:message-writer"
  (let ([told '()])
    (options:with ([ask:message-writer (lambda (text) (set! told (cons text told)))])
      (ask:message "Deleted 1 file"))
    (check-equal? '("Deleted 1 file") told))
  (check-raises (raised? 'ask:message "not a string") (ask:message 'text)))

(test "a plugin fills a reader when it loads, and its unload takes the reader back"
  (load-module! '(ask-test reader))
  (check-equal? #t (ask:y-or-n? "Save it? "))
  (unload-owner! (module-owner '(ask-test reader)))
  (check-raises (raised? 'ask:y-or-n-reader "no reader is loaded") (ask:y-or-n? "Save it? ")))

(test "the page's commands ask through ask, whichever plugin answers"
  (load-module! '(ask-test scratch))
  (let ([scratch (buffers:make "*scratch*" "")])
    (options:with ([ask:line-reader (lambda (question default) "notes")])
      (commands:run (commands:command-named 'ask-test/scratch:rename-scratch)))
    (check-equal? "notes" (buffers:name scratch))
    (buffers:rename! scratch "*scratch*")
    (options:with ([ask:y-or-n-reader (lambda (question) #f)])
      (commands:run (commands:command-named 'ask-test/scratch:kill-scratch)))
    (check (buffers:find "*scratch*"))
    (options:with ([ask:y-or-n-reader (lambda (question) #t)])
      (commands:run (commands:command-named 'ask-test/scratch:kill-scratch)))
    (check-equal? #f (buffers:find "*scratch*"))))
