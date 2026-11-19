#!tuna

(define (%no-reader who)
  (lambda (question . folder) (error who "no reader is loaded")))

(define-option file-name-reader (%no-reader 'ask:file-name-reader) procedure?
  "A procedure of a question, and optionally the folder to start in, that reads a file name and returns it, as Emacs's read-file-name-function.")

(define-option line-reader (%no-reader 'ask:line-reader) procedure?
  "A procedure of a question that reads a line of text and returns it, as Emacs's read-string.")

(define-option yes-or-no-reader (%no-reader 'ask:yes-or-no-reader) procedure?
  "A procedure of a question that asks for yes or no and returns true for yes.")

(define-option y-or-n-reader (%no-reader 'ask:y-or-n-reader) procedure?
  "A procedure of a question that asks for y or n and returns true for y.")

(define-option message-writer
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

(define (line question)
  (%check-question 'ask:line question)
  ((line-reader) question))

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
