#!tuna
(import (layout) (keys) (commands) (document) (haml))

(define-table box-keys)

(commands:define-command (box-command) "Does nothing." #f)

(define (draw-box node children focused draw-child client)
  (haml (:section.box (map draw-child children))))

(define (draw-broken node children focused draw-child client)
  (car '()))

(define (stray-neighbour node child direction)
  node)

(layout:define-container box (draw draw-box) (keymap box-keys))

(layout:define-container broken (draw draw-broken))

(layout:define-container stray (draw draw-box) (neighbour stray-neighbour))

(keys:bind! box-keys "C-c b" box-command)
