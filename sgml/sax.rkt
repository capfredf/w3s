#lang typed/racket/base

(provide (all-defined-out) read-xml-datum sax-stop-with)
(provide XML-Event-Handler xml-event-handler? make-xml-event-handler)
(provide XML-Prolog-Handler XML-Doctype-Handler XML-PI-Handler)
(provide XML-Element-Handler XML-Attribute-Handler XML-AttrList-Handler)
(provide XML-PCData-Handler XML-Comment-Handler)


(require "digitama/plain/sax.rkt")
(require "digitama/plain/prompt.rkt")