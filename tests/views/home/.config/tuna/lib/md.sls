#!tuna
(import (buffers) (document) (views) (haml))

(define (draw-doc node view) (haml (:article (views:draw-children view node))))
(define (draw-heading node view) (haml (:div.heading (views:draw-children view node))))
(define (draw-link node view)
  (haml (:a ([href (document:node-attribute node 'href "")]) (views:draw-children view node))))
(define (draw-image node view) (haml (:img ([src (document:node-attribute node 'src "")]))))
(define (draw-broken node view) (car '()))

(buffers:define-kind doc (content nodes) (draw draw-doc))
(buffers:define-kind heading (draw draw-heading))
(buffers:define-kind para)
(buffers:define-kind link (inline) (sticky neither) (draw draw-link))
(buffers:define-kind image (content atom) (draw draw-image))
(buffers:define-kind broken (draw draw-broken))
