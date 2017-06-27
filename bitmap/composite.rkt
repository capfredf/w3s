#lang typed/racket

(provide (except-out (all-defined-out) make-append make-append* make-superimpose))
(provide (rename-out [bitmap-pin-over bitmap-pin]))

(require "digitama/digicore.rkt")
(require "digitama/composite.rkt")
(require "digitama/unsafe/source.rkt")
(require "digitama/unsafe/composite.rkt")
(require "constructor.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(require (only-in typed/racket/draw bitmap-dc% Bitmap-DC%))

(define bitmap-composite : (->* (Bitmap Real Real Bitmap) (Symbol Real Real) Bitmap)
  (lambda [bmp1 x1 y1 bmp2 [op 'over] [x2 0.0] [y2 0.0]]
    (bitmap_composite (or (bitmap-operator->integer op) (bitmap-operator->integer 'over))
                      (bitmap-surface bmp1) (real->double-flonum x1) (real->double-flonum y1)
                      (bitmap-surface bmp2) (real->double-flonum x2) (real->double-flonum y2)
                      (bitmap-density bmp1))))

(define bitmap-pin-over : (->* (Bitmap Real Real Bitmap) (Real Real) Bitmap)
  (lambda [bmp1 x1 y1 bmp2 [x2 0.0] [y2 0.0]]
    (bitmap-composite bmp1 x1 y1 bmp2 'over x2 y2)))

(define bitmap-pin-under : (->* (Bitmap Real Real Bitmap) (Real Real) Bitmap)
  (lambda [bmp1 x1 y1 bmp2 [x2 0.0] [y2 0.0]]
    (bitmap-composite bmp1 x1 y1 bmp2 'dest-over x2 y2)))

(define bitmap-pin* : (-> Real Real Real Real Bitmap Bitmap * Bitmap)
  (lambda [x1-frac y1-frac x2-frac y2-frac bmp0 . bmps]
    (define-values (x1% y1%) (values (real->double-flonum x1-frac) (real->double-flonum y1-frac)))
    (define-values (x2% y2%) (values (real->double-flonum x2-frac) (real->double-flonum y2-frac)))
    (define-values (over density) (values (bitmap-operator->integer 'over) (bitmap-density bmp0)))
    (define-values (bmp _who _cares)
      (for/fold ([bmp : Bitmap bmp0] [x : Flonum 0.0] [y : Flonum 0.0])
                ([bmp1 (in-list (cons bmp0 bmps))] [bmp2 (in-list bmps)])
        (define-values (w1 h1) (bitmap-flsize bmp1))
        (define-values (w2 h2) (bitmap-flsize bmp2))
        (define x1 : Flonum (fl+ x (fl- (fl* w1 x1%) (fl* w2 x2%))))
        (define y1 : Flonum (fl+ y (fl- (fl* h1 y1%) (fl* h2 y2%))))
        (values (bitmap_composite over (bitmap-surface bmp) x1 y1 (bitmap-surface bmp2) 0.0 0.0 density)
                (flmax 0.0 x1) (flmax 0.0 y1))))
    bmp))

(define make-append* : (-> Symbol (-> (Listof Bitmap) [#:gapsize Real] Bitmap))
  (lambda [alignment]
    (λ [bitmaps #:gapsize [delta 0.0]]
      (cond [(null? bitmaps) (bitmap-blank)]
            [(null? (cdr bitmaps)) (car bitmaps)]
            [else (let*-values ([(base others gap) (values (car bitmaps) (cdr bitmaps) (real->double-flonum delta))]
                                [(min-width min-height) (values (fx->fl (send base get-width)) (fx->fl (send base get-height)))])
                    (define-values (width0 height0 sllec)
                      (for/fold ([width : Flonum min-width]
                                 [height : Flonum min-height]
                                 [cells : (Listof Bitmap-Cell) (list (list base min-width min-height))])
                                ([child : Bitmap (in-list others)])
                        (define w : Flonum (fx->fl (send child get-width)))
                        (define h : Flonum (fx->fl (send child get-height)))
                        (define cells++ : (Listof Bitmap-Cell) (cons (list child w h) cells))
                        (case alignment
                          [(vl vc vr) (values (flmax width w) (fl+ height (fl+ h gap)) cells++)]
                          [(ht hc hb) (values (fl+ width (fl+ w gap)) (flmax height h) cells++)]
                          [else #|unreachable|# (values (flmax width w) (flmax height h) cells++)])))
                    
                    (define width : Flonum (flmax min-width width0))
                    (define height : Flonum (flmax min-height height0))
                    (define bmp : Bitmap (bitmap-blank width height #:density 2.0))
                    (define dc : (Instance Bitmap-DC%) (send bmp make-dc))
                    (send dc set-smoothing 'aligned)
                    
                    (let render : Void ([cells : (Listof Bitmap-Cell) (reverse sllec)]
                                        [xoff : Flonum (fl- 0.0 gap)]
                                        [yoff : Flonum (fl- 0.0 gap)])
                      (unless (null? cells)
                        (define w : Flonum (cadar cells))
                        (define h : Flonum (caddar cells))
                        (define this-x-if-use : Flonum (fl+ xoff gap))
                        (define this-y-if-use : Flonum (fl+ yoff gap))
                        (define-values (x y)
                          (case alignment
                            [(vl) (values 0.0                     this-y-if-use)]
                            [(vc) (values (fl/ (fl- width w) 2.0) this-y-if-use)]
                            [(vr) (values (fl- width w)           this-y-if-use)]
                            [(ht) (values this-x-if-use           0.0)]
                            [(hc) (values this-x-if-use           (fl/ (fl- height h) 2.0))]
                            [(hb) (values this-x-if-use           (fl- height h))]
                            [else #|unreachable|# (values this-x-if-use this-y-if-use)]))
                        (send dc draw-bitmap (caar cells) x y)
                        (render (cdr cells) (fl+ this-x-if-use w) (fl+ this-y-if-use h))))
                    bmp)]))))

(define make-append : (-> Symbol (-> [#:gapsize Real] Bitmap * Bitmap))
  (lambda [alignment]
    (define append-apply : (-> (Listof Bitmap) [#:gapsize Real] Bitmap) (make-append* alignment))
    (λ [#:gapsize [delta 0.0] . bitmaps] (append-apply #:gapsize delta bitmaps))))

(define make-superimpose : (-> Symbol (-> Bitmap * Bitmap))
  (lambda [alignment]
    (λ bitmaps
      (cond [(null? bitmaps) (bitmap-blank)]
            [(null? (cdr bitmaps)) (car bitmaps)]
            [(null? (cddr bitmaps))
             (let-values ([(base bmp) (values (car bitmaps) (cadr bitmaps))])
               (case alignment
                 [(lt) (bitmap_pin 0.0 0.0 0.0 0.0 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(lc) (bitmap_pin 0.0 0.5 0.0 0.5 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(lb) (bitmap_pin 0.0 1.0 0.0 1.0 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(ct) (bitmap_pin 0.5 0.0 0.5 0.0 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(cc) (bitmap_pin 0.5 0.5 0.5 0.5 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(cb) (bitmap_pin 0.5 1.0 0.5 1.0 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(rt) (bitmap_pin 1.0 0.0 1.0 0.0 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(rc) (bitmap_pin 1.0 0.5 1.0 0.5 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [(rb) (bitmap_pin 1.0 1.0 1.0 1.0 (bitmap-surface base) (bitmap-surface bmp) (bitmap-density base))]
                 [else (car bitmaps)]))]
            [else (let-values ([(width height sreyal) (superimpose alignment bitmaps)])
                    (define bmp : Bitmap (bitmap-blank width height #:density 2.0))
                    (define dc : (Instance Bitmap-DC%) (send bmp make-dc))
                    (send dc set-smoothing 'aligned)
                    (for ([bmp+fxy (in-list (reverse sreyal))])
                      (define-values (x y) ((cdr bmp+fxy) width height))
                      (send dc draw-bitmap (car bmp+fxy) x y))
                    bmp)]))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-combiner
  [make-append      "bitmap-~a-append"      (vl vc vr ht hc hb)]
  [make-append*     "bitmap-~a-append*"     (vl vc vr ht hc hb)]
  [make-superimpose "bitmap-~a-superimpose" (lt lc lb ct cc cb rt rc rb)])

(define bitmap-table : (->* (Positive-Integer (Listof Bitmap))
                            ((Listof Superimpose-Alignment)
                             (Listof Superimpose-Alignment)
                             (Listof Nonnegative-Real)
                             (Listof Nonnegative-Real))
                            Bitmap)
  (lambda [ncols bitmaps [col-aligns '(cc)] [row-aligns '(cc)] [col-gaps '(0)] [row-gaps '(0)]]
    (define-values (maybe-nrows extra-ncols) (quotient/remainder (length bitmaps) ncols))
    (define nrows : Natural (fx+ maybe-nrows (sgn extra-ncols)))
    (define alcols : (Vectorof Symbol) (list->n:vector col-aligns ncols 'cc))
    (define alrows : (Vectorof Symbol) (list->n:vector row-aligns nrows 'cc))
    (define gcols : (Vectorof Flonum) (list->n:vector (map real->double-flonum col-gaps) ncols 0.0))
    (define grows : (Vectorof Flonum) (list->n:vector (map real->double-flonum row-gaps) nrows 0.0))

    (define table-ref : (-> Integer Integer Bitmap-Cell)
      (let ([table : Bitmap-Tables (list->table bitmaps nrows ncols)])
        ;;; TODO: why (unsafe-vector-ref) makes it slower?
        (λ [c r] (vector-ref table (fx+ (fx* r ncols) c)))))
    (define pbcols : (Vectorof Pseudo-Bitmap*)
      (for/vector : (Vectorof Pseudo-Bitmap*) ([c (in-range ncols)])
        (superimpose* (vector-ref alcols c) (for/list ([r (in-range nrows)]) (table-ref c r)))))
    (define pbrows : (Vectorof Pseudo-Bitmap*)
      (for/vector : (Vectorof Pseudo-Bitmap*) ([r (in-range nrows)])
        (superimpose* (vector-ref alrows r) (for/list ([c (in-range ncols)]) (table-ref c r)))))
    
    (unless (zero? nrows)
      (vector-set! gcols (sub1 ncols) 0.0)
      (vector-set! grows (sub1 nrows) 0.0))

    (define-values (width height cells)
      (for/fold ([width : Flonum 0.0] [height : Flonum 0.0] [pbmps : (Listof (List Bitmap Flonum Flonum)) null])
                ([row : Integer (in-range nrows)])
        (define pbrow : Pseudo-Bitmap* (vector-ref pbrows row))
        (define hrow : Flonum (fl+ (cadr pbrow) (vector-ref grows row)))
        (define-values (wcols cells)
          (for/fold ([xoff : Flonum 0.0] [pbmps : (Listof (List Bitmap Flonum Flonum)) pbmps])
                    ([col : Integer (in-range ncols)])
            (define cell : Bitmap-Cell (table-ref col row))
            (define pbcol : Pseudo-Bitmap* (vector-ref pbcols col))
            (define wcol : Flonum (fl+ (car pbcol) (vector-ref gcols col)))
            (define-values (x _y) (find-xy cell pbcol))
            (define-values (_x y) (find-xy cell pbrow))
            (values (fl+ xoff wcol) (cons (list (car cell) (fl+ x xoff) (fl+ y height)) pbmps))))
        (values wcols (fl+ height hrow) cells)))

    (define bmp : Bitmap (bitmap-blank width height #:density 2.0))
    (define dc : (Instance Bitmap-DC%) (send bmp make-dc))
    (send dc set-smoothing 'aligned)
    (for ([cell : Bitmap-Cell (in-list cells)])
      (send dc draw-bitmap (car cell) (cadr cell) (caddr cell)))
    bmp))