(import (tuna) (test) (test-browser) (cdp page) (design-tokens) (faces) (buffers) (views) (layout) (layout-split) (editing)
        (echo-area) (status-line) (minibuffer) (completion) (completion-list) (completion-annotations) (files) (file-picker)
        (command-picker) (transient) (chat) (dired) (faces-test))

(define page (test-browser:open (page-options [width 1400] [height 1000] [color-scheme (color-scheme light)])))

(define (style-of shot text face property) (faces-test:style shot (faces-test:faced shot text face) property))

(define (classed shot class) (car (faces-test:with-class shot class)))

(define (message! face text)
  (parameterize ([echo-area:face face]) (echo-area:message! text))
  (test-browser:wait-for-applied page))

(define (message-look shot class face)
  (let ([e (find (lambda (i) (faces-test:has-class? shot i class)) (faces-test:with-face shot face))])
    (list (faces-test:style shot e "font-weight") (faces-test:style shot e "color"))))

(faces-test:show-fixture!)

(test "under Modus an error or a warning in the echo area, and in the minibuffer while a prompt waits, is semi-bold in its face's colour"
  (faces-test:set-case! page #t "")
  (let* ([shot (faces-test:snapshot page)]
         [colors (list (style-of shot "err" faces:error "color") (style-of shot "warn" faces:warning "color"))]
         [echoed (map (lambda (face text)
                        (message! face text)
                        (message-look (faces-test:snapshot page) "echo-area-message" face))
                      (list faces:error faces:warning) '("error" "warning"))])
    (test-browser:press! page "M-x")
    (faces-test:wait-for page ".minibuffer-question")
    (let ([prompted (map (lambda (face text)
                           (message! face text)
                           (message-look (faces-test:snapshot page) "minibuffer-message" face))
                         (list faces:error faces:warning) '("error" "warning"))])
      (faces-test:quit-prompt! page)
      (check (not (apply equal? colors)))
      (check-equal? (map (lambda (c) (list "600" c)) colors) echoed)
      (check-equal? echoed prompted))))

(test "the echo area's message draws in the code font at the text's size"
  (faces-test:set-case! page #f "")
  (message! faces:error "Error")
  (let* ([shot (faces-test:snapshot page)]
         [message (find (lambda (i) (faces-test:has-class? shot i "echo-area-message")) (faces-test:with-face shot faces:error))])
    (check-equal? (list "Fira Code" (style-of shot "if" faces:keyword "font-size"))
                  (list (faces-test:family shot message) (faces-test:style shot message "font-size")))))

(transient:define-menu faces-menu "Two entries whose keys the test reads.")

(transient:add! faces-menu "Files"
  (transient:command "a" "Find a file" file-picker:find-file)
  (transient:command "b" "Find another file" file-picker:find-file))

(test "a transient menu's keys draw in the code font and its labels in the interface font"
  (transient:show! faces-menu)
  (test-browser:wait-for-applied page)
  (let ([shot (faces-test:snapshot page)])
    (faces-test:run-command transient:quit)
    (check-equal? '("Fira Code" "Fira Code") (map (lambda (k) (faces-test:family shot k)) (faces-test:with-class shot "transient-key")))
    (check-equal? "Fira Sans"
                  (faces-test:family shot (find (lambda (i) (exists (lambda (a) (faces-test:has-class? shot a "transient-entry"))
                                                                    (faces-test:ancestors shot i)))
                                                (faces-test:with-class shot "ui-label"))))))

(test "a completion row's key and documentation draw in the interface font and size, and the list's count in size 1"
  (faces-test:set-case! page #f ":root { --tuna-font-size-ui: 13px; --tuna-font-size-1: 11px; }")
  (let* ([shot (faces-test:completion-rows page)]
         [column (lambda (face) (find (lambda (i) (faces-test:has-class? shot i "completion-column")) (faces-test:with-face shot face)))]
         [font (lambda (i) (list (faces-test:family shot i) (faces-test:style shot i "font-size")))])
    (check-equal? '(("Fira Sans" "13px") ("Fira Sans" "13px") ("Fira Sans" "11px"))
                  (list (font (column faces:keyword)) (font (column faces:shadow)) (font (classed shot "completion-list-count"))))))

(test "a chat notice draws in the interface font and size, and an added line in diff.plus's background"
  (layout:switch-to-buffer
    (buffers:make "*chat-fixture*"
      '(chat:transcript () (chat:notice ((level . error)) "Failed") (chat:diff () (chat:removed () "old") (chat:added () "new")))))
  (faces-test:set-case! page #f ":root { --tuna-font-size-ui: 13px; --faces-diff-plus-background: rgb(1, 2, 3); }")
  (let* ([shot (faces-test:snapshot page)] [notice (classed shot "chat-notice")])
    (check-equal? '("Fira Sans" "13px" "rgb(1, 2, 3)")
                  (list (faces-test:family shot notice) (faces-test:style shot notice "font-size")
                        (faces-test:style shot (classed shot "chat-added") "background-color"))))
  (faces-test:show-fixture!))

;; A block's text decoration is drawn through its children whatever their
;; own style, so the summary must sit outside the header's face.
(test "dired's header tokens style the folder line alone; the summary beside it keeps its look"
  (faces-test:set-case! page #f "")
  (let* ([header-face (lambda (shot) (car (faces-test:with-face shot 'dired.header)))]
         [header-line (lambda (shot) (find (lambda (i) (faces-test:has-class? shot i "line"))
                                           (faces-test:descendants shot (header-face shot))))]
         [summary-look (lambda (shot) (let ([s (classed shot "dired-summary")])
                                        (map (lambda (p) (faces-test:style shot s p)) '("color" "font-size" "font-weight"))))]
         [plain (faces-test:dired-shot page)])
    (faces-test:set-case! page #f
      ":root { --dired-header-color: rgb(7, 8, 9); --dired-header-font-size: 1.4em; --dired-header-text-decoration: underline; }")
    (let ([shot (faces-test:dired-shot page)])
      (check-equal? '("rgb(7, 8, 9)" "underline")
                    (list (faces-test:style shot (header-line shot) "color")
                          (faces-test:style shot (header-face shot) "text-decoration-line")))
      (check (not (equal? (faces-test:style shot (header-line shot) "font-size") (faces-test:style plain (header-line plain) "font-size"))))
      (check (not (faces-test:inside? shot (classed shot "dired-summary") (header-face shot))))
      (check-equal? (summary-look plain) (summary-look shot)))))
