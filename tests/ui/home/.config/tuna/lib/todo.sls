#!tuna
(import (ui) (buffers) (document) (commands))

(define-saved todos '("Buy milk" "Write the plan") list?)

(buffers:define-kind todo (content nodes))
(buffers:define-kind item)

(define todo-buffer
  (or (buffers:find "*todo*") (buffers:make "*todo*" (todo '()))))

(define (item-datum title)
  (item (list (cons 'key title)) title " " (done (list (cons 'title title)) "Done") "\n"))

(define (show-todos!)
  (let ([doc (buffers:document todo-buffer)])
    (buffers:reconcile! todo-buffer (document:enclosing doc 1) (map item-datum (todos)))))

(commands:define-command (mark-done [button (ui:pushed-button)])
  "Removes the todo whose Done button was pushed."
  (set-saved! todos (remove (document:node-attribute button 'title) (todos)))
  (show-todos!))

(ui:define-button done mark-done)

(show-todos!)
