#!tuna
(import (web) (keys) (processes) (test-user) (test-runner) (json) (cdp) (cdp page))

(define %browser #f)

(define %clients (make-weak-eq-hashtable))

;; chez-cdp's calls block their thread until Chromium answers, and Tuna's
;; main thread must go on serving the page meanwhile.
(define (call thunk)
  (unless (procedure? thunk)
    (assertion-violation 'test-browser:call "not a procedure" thunk))
  (test-runner:join (fork-task (lambda (restore) (thunk)))))

(define (%chromium)
  (or (processes:program-path "chromium") (errorf 'test-browser:open "no chromium on PATH")))

(define (%browser!)
  (unless %browser
    (let ([program (%chromium)] [home (getenv "HOME")])
      (set! %browser
        (call (lambda ()
                (launch-browser program
                  (browser-options [profile (string-append home "/chromium")]
                                   [log (string-append home "/chromium.log")])))))))
  %browser)

;; web listens once the batch it loads in has ended.
(define (%url)
  (or (web:url)
      (begin (test-user:settle) (web:url))
      (errorf 'test-browser:open "web listens on no port")))

(define open
  (case-lambda
    [() (open (page-options))]
    [(options)
     (unless (page-options? options)
       (assertion-violation 'test-browser:open "not page options" options))
     (let* ([browser (%browser!)]
            [url (%url)]
            [before (web:clients)]
            [page (call (lambda ()
                          (let ([page (open-page browser url options)])
                            (cdp-call (page-session page) "Network.enable")
                            page)))]
            [added (remp (lambda (c) (memq c before)) (web:clients))])
       (unless (fx= (length added) 1)
         (call (lambda () (page-close! page)))
         (errorf 'test-browser:open "~a clients came with the page, not one" (length added)))
       (hashtable-set! %clients page (car added))
       (wait-for-applied page)
       page)]))

(define (%client-of who page)
  (or (hashtable-ref %clients page #f)
      (assertion-violation who "not a page test-browser opened" page)))

(define (wait-for-applied page)
  (let ([c (%client-of 'test-browser:wait-for-applied page)])
    (test-user:settle)
    (web:wait-for-applied c)))

(define %named-keys
  '(("RET" . "Enter") ("SPC" . " ") ("TAB" . "Tab") ("ESC" . "Escape") ("DEL" . "Backspace")
    ("<delete>" . "Delete") ("<insert>" . "Insert") ("<left>" . "ArrowLeft") ("<right>" . "ArrowRight")
    ("<up>" . "ArrowUp") ("<down>" . "ArrowDown") ("<home>" . "Home") ("<end>" . "End")
    ("<prior>" . "PageUp") ("<next>" . "PageDown") ("<f1>" . "F1") ("<f2>" . "F2") ("<f3>" . "F3")
    ("<f4>" . "F4") ("<f5>" . "F5") ("<f6>" . "F6") ("<f7>" . "F7") ("<f8>" . "F8") ("<f9>" . "F9")
    ("<f10>" . "F10") ("<f11>" . "F11") ("<f12>" . "F12")))

(define %modifier-set (enum-set-constructor (modifiers)))

(define-record-type %browser-key
  (sealed #t)
  (fields key name held))

;; keys has checked the key, so its modifiers come first, in the order
;; C- M- S- s-, each followed by more of the key.
(define (%key->browser-key key)
  (let loop ([i 0] [held '()])
    (let ([modifier (and (fx< (fx+ i 2) (string-length key))
                         (char=? (string-ref key (fx+ i 1)) #\-)
                         (case (string-ref key i)
                           [(#\C) 'control]
                           [(#\M) 'alt]
                           [(#\S) 'shift]
                           [(#\s) 'meta]
                           [else #f]))])
      (if modifier
          (loop (fx+ i 2) (cons modifier held))
          (let ([base (substring key i (string-length key))])
            (make-%browser-key key
              (cond
                [(fx= (string-length base) 1) base]
                [(assoc base %named-keys) => cdr]
                [else (assertion-violation 'test-browser:press! "a key no keyboard has" key)])
              (%modifier-set held)))))))

(define (%field alist name) (cdr (assoc name alist)))

(define (%posted-to? event route)
  (and (string=? (event-method event) "Network.requestWillBeSent")
       (let ([url (%field (%field (event-params event) "request") "url")])
         (and (fx>= (string-length url) (string-length route))
              (string=? route (substring url (fx- (string-length url) (string-length route)) (string-length url)))))))

;; A page posts its views' scroll reports to /input too, so the request
;; awaited is told by the item it carries.
(define (%input-item event)
  (and (%posted-to? event "/input")
       (let ([data (assoc "postData" (%field (event-params event) "request"))])
         (and data (let ([item (string->json (cdr data))]) (and (pair? item) item))))))

;; The page reads no answer to an item, so Chromium ends each request
;; as cancelled once its answer has come.
(define (%answered-or-failed id)
  (lambda (event)
    (and (member (event-method event) '("Network.responseReceived" "Network.loadingFailed"))
         (equal? id (%field (event-params event) "requestId")))))

;; A page sends its items at once, and Tuna answers an item that came
;; before one sent earlier while holding it unrun, so the item awaited
;; has run only once every item sent up to it has been answered. An
;; answer to a question the page was asked, such as a drag's at its
;; release, resumes the command that holds the items after it.
(define (%send! who page act! sent? what)
  (call (lambda ()
          (with-events (events (page-session page) "Network.requestWillBeSent" "Network.responseReceived"
                               "Network.loadingFailed")
            (act!)
            (let loop ([ids '()])
              (let* ([event (events-wait events (lambda (e) (or (%input-item e) (%posted-to? e "/answer"))))]
                     [ids (cons (%field (event-params event) "requestId") ids)])
                (if (let ([item (%input-item event)]) (and item (sent? item)))
                    (for-each (lambda (id)
                                (when (string=? "Network.loadingFailed" (event-method (events-wait events (%answered-or-failed id))))
                                  (errorf who "the page could not send ~a to Tuna" what)))
                              ids)
                    (loop ids)))))))
  (wait-for-applied page))

;; A user presses a key once the screen shows what the one before did, so
;; the quit mark the page gives it is the one Tuna's state asks for.
(define (%press-key! page key)
  (%send! 'test-browser:press! page
          (lambda () (page-press! page (%browser-key-name key) (%browser-key-held key)))
          (lambda (item) (equal? "key" (%field item "type")))
          (%browser-key-key key)))

(define (press! page keys)
  (%client-of 'test-browser:press! page)
  (for-each (lambda (key) (%press-key! page key)) (map %key->browser-key (keys:sequence-keys keys))))

(define (%char-key c)
  (case c
    [(#\space) "SPC"]
    [(#\newline) "RET"]
    [(#\tab) "TAB"]
    [else (string c)]))

(define (type! page text)
  (%client-of 'test-browser:type! page)
  (unless (string? text)
    (assertion-violation 'test-browser:type! "not a string" text))
  (for-each (lambda (key) (%press-key! page key)) (map (lambda (c) (%key->browser-key (%char-key c))) (string->list text))))

;; A page posts a press and a release, and a click runs its command at
;; the release.
(define (click! page element)
  (%check-element 'test-browser:click! page element)
  (%send! 'test-browser:click! page
          (lambda () (element-click! element))
          (%mouse-action? "click")
          "the click"))

(define (%check-element who page element)
  (%client-of who page)
  (unless (and (element? element) (eq? page (element-page element)))
    (assertion-violation who "not an element of the page" element)))

(define (%mouse-action? action)
  (lambda (item) (and (equal? "mouse" (%field item "type")) (equal? action (%field item "action")))))

(define %held (make-weak-eq-hashtable))

(define (%centre element)
  (let ([box (call (lambda () (element-box element)))])
    (make-point (+ (rectangle-x box) (/ (rectangle-width box) 2)) (+ (rectangle-y box) (/ (rectangle-height box) 2)))))

;; chez-cdp moves, presses and releases a button only all in one call,
;; so a button held across a test's steps is driven event by event.
(define (%mouse! page type at buttons clicks)
  (cdp-call (page-session page) "Input.dispatchMouseEvent"
    (list (cons "type" type) (cons "x" (inexact (point-x at))) (cons "y" (inexact (point-y at)))
          (cons "button" (if (fx= buttons 0) (if (string=? type "mouseReleased") "left" "none") "left"))
          (cons "buttons" buttons) (cons "clickCount" clicks))))

(define (%press! who page at clicks)
  (when (hashtable-contains? %held page)
    (assertion-violation who "a button is already held" page))
  (hashtable-set! %held page at)
  (%send! who page
          (lambda () (%mouse! page "mouseMoved" at 0 0) (%mouse! page "mousePressed" at 1 clicks))
          (%mouse-action? "down")
          "the press"))

(define (%release! who page clicks)
  (let ([at (or (hashtable-ref %held page #f) (assertion-violation who "no button is held" page))])
    (%end-press! who page (lambda () (%mouse! page "mouseReleased" at 0 clicks)))))

(define (%end-press! who page act!)
  (hashtable-delete! %held page)
  (%send! who page act!
          (lambda (item) (or ((%mouse-action? "click") item) ((%mouse-action? "drag") item)))
          "the release"))

(define (press-button! page element)
  (%check-element 'test-browser:press-button! page element)
  (%press! 'test-browser:press-button! page (%centre element) 1))

(define (move-pointer! page at)
  (%client-of 'test-browser:move-pointer! page)
  (unless (point? at)
    (assertion-violation 'test-browser:move-pointer! "not a point" at))
  (unless (hashtable-contains? %held page)
    (assertion-violation 'test-browser:move-pointer! "no button is held" page))
  (hashtable-set! %held page at)
  (call (lambda () (%mouse! page "mouseMoved" at 1 0)))
  (void))

(define (release-button! page)
  (%client-of 'test-browser:release-button! page)
  (%release! 'test-browser:release-button! page 1))

;; A button released outside the window sends the page no release; the
;; next move, with no button down, ends the press.
(define (release-outside! page at)
  (%client-of 'test-browser:release-outside! page)
  (unless (point? at)
    (assertion-violation 'test-browser:release-outside! "not a point" at))
  (unless (hashtable-contains? %held page)
    (assertion-violation 'test-browser:release-outside! "no button is held" page))
  (%end-press! 'test-browser:release-outside! page (lambda () (%mouse! page "mouseMoved" at 0 0))))

;; Moved in steps, as a hand moves, so a page that follows the pointer
;; sees the way between.
(define (drag! page element to)
  (%check-element 'test-browser:drag! page element)
  (unless (point? to)
    (assertion-violation 'test-browser:drag! "not a point" to))
  (let ([from (%centre element)] [steps 10])
    (%press! 'test-browser:drag! page from 1)
    (do ([i 1 (fx+ i 1)]) ((fx> i steps))
      (move-pointer! page (make-point (+ (point-x from) (/ (* i (- (point-x to) (point-x from))) steps))
                                      (+ (point-y from) (/ (* i (- (point-y to) (point-y from))) steps)))))
    (release-button! page)))

(define (double-click! page element)
  (%check-element 'test-browser:double-click! page element)
  (let ([at (%centre element)])
    (%press! 'test-browser:double-click! page at 1)
    (%release! 'test-browser:double-click! page 1)
    (%press! 'test-browser:double-click! page at 2)
    (%release! 'test-browser:double-click! page 2)))

(define (close! page)
  (%client-of 'test-browser:close! page)
  (hashtable-delete! %clients page)
  (call (lambda () (page-close! page))))

(on-unload
  (lambda ()
    (when %browser
      (browser-close! %browser))))
