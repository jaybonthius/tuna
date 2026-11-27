#!tuna
(import (options))

(define (%no-reader who)
  (lambda (question . folder) (error who "no reader is loaded")))

(options:define-option file-name-reader (%no-reader 'ask:file-name-reader) procedure?
  "A procedure of a question, and optionally the folder to start in, that reads a file name and returns it, as Emacs's read-file-name-function.")

(options:define-option line-reader (%no-reader 'ask:line-reader) procedure?
  "A procedure of a question and a default or #f that reads a line of text and returns it, as Emacs's read-string.")

(options:define-option choice-reader (%no-reader 'ask:choice-reader) procedure?
  "A procedure of a question and a list of choices, each a pair of a label and a value or a vector of a label, a value and an annotation, that returns the value of the choice picked, as Emacs's completing-read with a required match.")

(options:define-option line-with-candidates-reader (%no-reader 'ask:line-with-candidates-reader) procedure?
  "A procedure of a question, the candidates and a default or #f that reads a line of text, offering the candidates, and returns it, as Emacs's completing-read without a required match.")

(options:define-option number-reader (%no-reader 'ask:number-reader) procedure?
  "A procedure of a question that reads a number and returns it, as Emacs's read-number.")

(options:define-option yes-or-no-reader (%no-reader 'ask:yes-or-no-reader) procedure?
  "A procedure of a question that asks for yes or no and returns true for yes.")

(options:define-option y-or-n-reader (%no-reader 'ask:y-or-n-reader) procedure?
  "A procedure of a question that asks for y or n and returns true for y.")

(options:define-option message-writer
  (lambda (text)
    (raise-continuable (condition (make-warning) (make-who-condition 'ask:message) (make-message-condition text))))
  procedure?
  "A procedure of a message's text that shows it to the user.")

(define (%check-question who question)
  (unless (string? question)
    (assertion-violation who "not a string" question)))

(define file-name
  (case-lambda
    [(question)
     (%check-question 'ask:file-name question)
     ((file-name-reader) question)]
    [(question folder)
     (%check-question 'ask:file-name question)
     (unless (string? folder)
       (assertion-violation 'ask:file-name "not a string" folder))
     ((file-name-reader) question folder)]))

(define (%check-default who default)
  (unless (or (not default) (string? default))
    (assertion-violation who "neither a string nor #f" default)))

(define line
  (case-lambda
    [(question) (line question #f)]
    [(question default)
     (%check-question 'ask:line question)
     (%check-default 'ask:line default)
     ((line-reader) question default)]))

(define (%choice? c)
  (or (and (pair? c) (string? (car c)))
      (and (vector? c) (fx= (vector-length c) 3) (string? (vector-ref c 0)) (string? (vector-ref c 2)))))

(define (choice question choices)
  (%check-question 'ask:choice question)
  (unless (and (list? choices) (for-all %choice? choices))
    (assertion-violation 'ask:choice "not a list of choices: pairs of a label and a value, or vectors of a label, a value and an annotation" choices))
  ((choice-reader) question choices))

(define line-with-candidates
  (case-lambda
    [(question candidates) (line-with-candidates question candidates #f)]
    [(question candidates default)
     (%check-question 'ask:line-with-candidates question)
     (unless (or (procedure? candidates) (and (list? candidates) (for-all string? candidates)))
       (assertion-violation 'ask:line-with-candidates "neither a list of strings nor a procedure" candidates))
     (%check-default 'ask:line-with-candidates default)
     ((line-with-candidates-reader) question candidates default)]))

(define (number question)
  (%check-question 'ask:number question)
  ((number-reader) question))

(define (yes-or-no? question)
  (%check-question 'ask:yes-or-no? question)
  ((yes-or-no-reader) question))

(define (y-or-n? question)
  (%check-question 'ask:y-or-n? question)
  ((y-or-n-reader) question))

(define (message text)
  (unless (string? text)
    (assertion-violation 'ask:message "not a string" text))
  ((message-writer) text))
