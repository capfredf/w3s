#lang typed/racket/base

(provide (all-defined-out))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define <? : Symbol (string->uninterned-symbol "<?"))
(define ?> : Symbol (string->uninterned-symbol "?>"))
(define <! : Symbol (string->uninterned-symbol "<!"))
(define <!$ : Symbol (string->uninterned-symbol "<!["))
(define <!$CDATA$ : Symbol (string->uninterned-symbol "<![CDATA["))
(define $$> : Symbol (string->uninterned-symbol "]]>"))
(define </ : Symbol (string->uninterned-symbol "</"))
(define /> : Symbol (string->uninterned-symbol "/>"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define xml-delim-symbol? : (-> Symbol Boolean)
  (lambda [datum]
    (not (or (symbol-interned? datum)
             (symbol-unreadable? datum)))))