(in-package :mulm)

(defvar *hmm* nil)

(defparameter *estimation-cutoff* 0)

(defparameter *known-codes* (make-hash-table)) ;;fixme

(defstruct hmm
  tag-array
  beam-array
  tags
  ; model tag set size
  (n 0)
  transitions
  emissions
  trigram-table
  unigram-table
  tag-lm
  ; the number of tokens in the training corpus used
  (token-count 0)
  (lambda-1 0.0 :type single-float)
  (lambda-2 0.0 :type single-float)
  (lambda-3 0.0 :type single-float)
  (suffix-tries (make-hash-table :test #'equal))
  theta
  current-transition-table)

;; WARNING: this may add unseen tags to the tags list with the result that these tags codes
;; are above the models tag set size. Using such codes will result in out-of-bounds array
;; indexing in viterbi decoders.
(defun tag-to-code (hmm tag)
  "Transforms tag string to integer code based on index in the tags field of the hmm structure.
   If the tag is unseen it is added to the tags field and the resulting index returned."
  (let ((code (position tag (hmm-tags hmm) :test #'string=)))
    (unless code
      (setf (hmm-tags hmm) (append (hmm-tags hmm) (list tag)))
      (setf code (1- (length (hmm-tags hmm)))))
    code))

(defun bigram-to-code (hmm bigram)
  "Returns index of bigram data in "
  (let ((c1 (tag-to-code hmm (first bigram)))
        (c2 (tag-to-code hmm (second bigram))))
    (+ (* c1 (hmm-n hmm))
       c2)))

(defmethod print-object ((object hmm) stream)
  (format stream "<HMM with ~a states>" (hmm-n object)))

(defun transition-probability (hmm previous current &key (order 1) (smoothing :constant))
  (declare (type fixnum current order))
  (declare (type hmm hmm))
  ;;
  ;; give a tiny amount of probability to unseen transitions
  ;;
  (the single-float
    (log
     (float
      (cond ((and (eql order 1) (eql smoothing :constant))
             (or (aref (the (simple-array t (* *)) (hmm-transitions hmm)) previous current) 0.000001))
            ((and (= order 1) (eql smoothing :deleted-interpolation))
             (+
                  (* (the single-float (hmm-lambda-1 hmm))
                       (or (aref (the (simple-array t (*)) (hmm-unigram-table hmm)) current)
                           0.0))
                (the single-float
                  (* (hmm-lambda-2 hmm)
                     (or (aref (the (simple-array t (* *)) (hmm-transitions hmm)) previous current)
					     0.0)))))
            ((and (= order 2) (eql smoothing :simple-back-off))
               (or (aref (the (simple-array  t (* * *))
                           (hmm-trigram-table hmm))
                         (first previous) (second previous) current)
                   (aref (the (simple-array t (* *)) (hmm-transitions hmm))
                         (second previous) current)
                   (aref (the (simple-array t (*))
                           (hmm-unigram-table hmm))
                         current)
                   0.00000001))
            ((and (= order 2) (eql smoothing :deleted-interpolation))
             (+ (* (hmm-lambda-1 hmm)
                   (or (aref (the (simple-array t (*)) (hmm-unigram-table hmm)) current)
                       0.0))
                (* (hmm-lambda-2 hmm)
                   (or (aref (the (simple-array t (* *)) (hmm-transitions hmm)) (second previous) current)
                       0.0))
                (* (hmm-lambda-3 hmm)
                   (or (aref (the (simple-array t (* * *)) (hmm-trigram-table hmm)) (first previous) (second previous)
                             current)
                       0.0))))
            (t (error "What!")))))))

(defun make-transition-table (hmm order smoothing)
  (setf (hmm-current-transition-table hmm)
        (let ((tag-card (hmm-n hmm)))
          (cond
           ((= order 1)
            (let* ((table (make-array (list tag-card tag-card) :element-type 'single-float :initial-element 0.0)))
              (loop
               for i from 0 below tag-card
               do (loop
                   for j below tag-card do
                   (setf (aref table i j) (transition-probability hmm i j :order 1 :smoothing smoothing))))
              table))
           ((= order 2)
            (let* ((table (make-array (list tag-card tag-card tag-card) 
                                      :element-type 'single-float :initial-element most-negative-single-float)))
              (loop
               for i from 0 below tag-card
               do (loop 
                   for j  from 0 below tag-card
                   do (loop
                       for k from 0 below tag-card do
                       (setf (aref table i j k) 
                             (transition-probability hmm (list i j) k :order 2 :smoothing smoothing)))))
              table))))))

(defmacro bi-cached-transition (hmm from to)
  `(the single-float  
     (aref (the (simple-array single-float (* *)) (hmm-current-transition-table ,hmm)) ,from ,to)))

(defmacro tri-cached-transition (hmm t1 t2 to)
  `(the single-float
     (max -19.0
          (aref (the (simple-array single-float (* * *)) (hmm-current-transition-table ,hmm)) ,t1 ,t2 ,to))))

(defmacro emission-probability (hmm state form)
  `(the single-float (or (gethash ,form (aref (the (simple-array t (*)) (hmm-emissions ,hmm)) ,state)) -19.0)))

(defun emission-probability-slow (decoder hmm state form)
  (if (eql :unk (gethash form *known-codes* :unk))
    (let* ((cache (gethash :unknown-word (viterbi-decoder-caches decoder)))
           (cache-lookup (gethash form cache))
           (dist (or cache-lookup
                     (let ((dist (query-suffix-trie hmm form)))
                       (setf (gethash form cache) dist)
                       dist))))
      (aref dist state))
    (the single-float
         (gethash form
                  (aref (the (simple-array t (*)) (hmm-emissions hmm)) state)
                  -19.0))))

;; WARNING this function processes the entire corpus
(defun corpus-tag-set-size (corpus)
  "Returns the number of unique tags observed in the corpus."
  (let ((tag-map (make-hash-table :test #'equal)))
    (loop for sentence in corpus
          do (loop for token in sentence
                   do (if (not (gethash (second token) tag-map))
                        (setf (gethash (second token) tag-map) t))))
    (hash-table-count tag-map)))

;; WARNING does not fully initialize the hmm data structure.
;; Do not use this function to reuse hmm structs.
(defun setup-hmm (hmm n)
  "Initializes the basic (but not all) hmm model data structures.
   hmm - Instantiated hmm struct.
   n   - Model tag set size.
   Returns the passed hmm struct."
  ;; add start and end tags to tag set size
  (let ((n (+ n 2)))
    (setf (hmm-token-count hmm) 0)
    (setf (hmm-n hmm) n)
    ;; setup empty tables for probability estimates
    (setf (hmm-transitions hmm)
          (make-array (list n n) :initial-element nil))
    (setf (hmm-emissions hmm)
          (make-array n :initial-element nil))
    (setf (hmm-trigram-table hmm)
          (make-array (list n n n) :initial-element nil))
    (setf (hmm-unigram-table hmm)
          (make-array n :initial-element nil))
    (loop for i from 0 to (- n 1)
          do (setf (aref (hmm-emissions hmm) i) (make-hash-table))))
  hmm)

(defun setup-hmm-beam (hmm)
  "Initializes the hmm struct fields concerning the beam search.
   hmm - Instantiated hmm struct.
   Returns the passed hmm struct."
  (let ((n (hmm-n hmm)))
    (setf (hmm-beam-array hmm) (make-array n :fill-pointer t))
    (setf (hmm-tag-array hmm)
          (make-array n :element-type 'fixnum 
                      :initial-contents (loop for i from 0 to (1- n) collect i))))
  hmm)

(defun add-sentence-to-hmm (hmm sentence)
  "Adds emission, tag unigram, bigram and trigram counts to the appropriate fields
   in the hmm struct.
   hmm - Instantiated hmm struct.
   sentence - In list of lists format.
   Returns the passed hmm struct."
  ;; Add start and end tags
  (let* ((unigrams (append '("<s>")
                           (mapcar #'second sentence)
                           '("</s>")))
         (bigrams (partition unigrams 2))
         (trigrams (partition unigrams 3)))
    (loop for (code tag) in sentence
          do (incf (hmm-token-count hmm))
          do (setf (gethash code *known-codes*) t)
          do (incf (gethash code
                            (aref (hmm-emissions hmm)
                                  (tag-to-code hmm tag))
                            0)))

    (loop for unigram in unigrams
          for code = (tag-to-code hmm unigram)
          do (if (aref (hmm-unigram-table hmm) code)
               (incf (aref (hmm-unigram-table hmm) code))
               (setf (aref (hmm-unigram-table hmm) code) 1)))
             
    (loop for bigram in bigrams
          for previous = (tag-to-code hmm (first bigram))
          for current = (tag-to-code hmm (second bigram))
          do (if (aref (hmm-transitions hmm) previous current)
               (incf (aref (hmm-transitions hmm) previous current))
               (setf (aref (hmm-transitions hmm) previous current) 1)))

    (loop for trigram in trigrams
          do (let ((t1 (tag-to-code hmm (first trigram)))
                   (t2 (tag-to-code hmm (second trigram)))
                   (t3 (tag-to-code hmm (third trigram))))
               (if (aref (hmm-trigram-table hmm) t1 t2 t3)
                 (incf (aref (hmm-trigram-table hmm) t1 t2 t3))
                 (setf (aref (hmm-trigram-table hmm) t1 t2 t3) 1))))
    hmm))

(defun train (corpus &optional (n nil))
  "Trains a HMM model from a corpus (a list of lists of word/tag pairs).
   Returns a fully trained hmm struct."

  ;; determine tagset size if not specified by the n parameter
  (let ((hmm (setup-hmm (make-hmm) (or n (corpus-tag-set-size corpus)))))
    ;; collect counts from setences in the corpus
    (loop for sentence in corpus
          do (add-sentence-to-hmm hmm sentence))

    (setup-hmm-beam hmm)

    ;; These steps must be performed before counts are converted into
    ;; probability estimates
    (calculate-deleted-interpolation-weights hmm)
    (calculate-theta hmm)
    (build-suffix-tries hmm)

    (let ((n (hmm-n hmm)))
      (loop
       with transitions = (hmm-transitions hmm)
       for i from 0 to (- n 1)
       for total = (float (loop
                           for j from 0 to (- n 1)
                           for count = (aref transitions i j)
                           when (and count (> count *estimation-cutoff*))
                           sum count))
       do
       (loop
        for j from 0 to (- n 1)
        for count = (aref transitions i j)
        when (and count (> count *estimation-cutoff*))
        do (setf (aref transitions i j) (float (/ count total))))
          
       (make-good-turing-estimate (aref (hmm-emissions hmm) i)
                                  (hash-table-sum (aref (hmm-emissions hmm) i))
                                  (elt (hmm-tags hmm) i))
       (loop
        with map = (aref (hmm-emissions hmm) i)
        for code being each hash-key in map
        for count = (gethash code map)
        when (and count (> count *estimation-cutoff*))
        do (setf (gethash code map) (float (log (/ count total))))))
    
          
      ;;; this is quite hacky but count-trees will be abstracted nicely
      ;;; in the near future, however, this should estimate correct
      ;;; n-gram probabilities
      (loop
          with lm-root = (make-lm-tree-node)
          initially (build-model (mapcar (lambda (x)
                                           (append
                                            (list (tag-to-code hmm "<s>"))
                                            (mapcar (lambda (x)
                                                      (tag-to-code hmm x))
                                                    x)
                                            (list (tag-to-code hmm "</s>"))))
                                         (ll-to-tag-list corpus))
                                 3
                                 lm-root)
          for t1 from 0 below n
          for t1-node = (gethash t1 (lm-tree-node-children lm-root))
          when t1-node do
            (loop 
                for t2 from 0 below n 
                for t2-node = (gethash t2 (lm-tree-node-children t1-node))
                when t2-node do
                  (loop 
                      with total = (lm-tree-node-total t2-node)
                      for t3 from 0 below n
                      for t3-node = (gethash t3 (lm-tree-node-children t2-node))
                      when t3-node do
                        (let ((prob (/ (lm-tree-node-total t3-node)
                                       total)))
                          (setf (aref (hmm-trigram-table hmm) t1 t2 t3)
                            prob))))
          finally (setf (hmm-tag-lm hmm) lm-root))
      
      
      (loop for i from 0 below n
          for count = (aref (hmm-unigram-table hmm) i)
          with total = (hmm-token-count hmm)
          do (setf (aref (hmm-unigram-table hmm) i)
               (float (/ count total)))))

    hmm))

(defun calculate-theta (hmm)
   (let* ((total (loop for count across (hmm-unigram-table hmm)
                     summing count))
          (probs (loop for count across (hmm-unigram-table hmm)
                     collect (float (/ count total))))
          (mean (/ (loop for p in probs
                       summing p)
                   (hmm-n hmm))))
     (setf (hmm-theta hmm)
       (sqrt (float (* (/ 1.0 (1- (hmm-n hmm)))
                 (loop 
                     for p in probs
                     summing (expt (- p mean) 2))))))))

(defun add-to-suffix-tries (hmm  word tag count)
  (let* ((form (code-to-symbol word))
         (trie-key (capitalized-p form))
         (lookup (gethash trie-key (hmm-suffix-tries hmm))))
    (when (null lookup)
      (setf lookup (make-lm-tree-node))
      (setf (gethash trie-key (hmm-suffix-tries hmm))
            lookup))
    (add-word word tag  count lookup)))

(defun total-emissions (code hmm)
  (loop
      for table across (hmm-emissions hmm)
      summing (gethash code table 0)))

(defun build-suffix-tries (hmm)
  (loop 
      for state below (hmm-n hmm)
      for emission-map = (aref (hmm-emissions hmm) state)
       do
        (loop 
            for word being the hash-keys in emission-map
            for count = (gethash word emission-map)
            when (and (<= count 10) (<= (total-emissions word hmm) 10)
                      (not (eql word :unk)))                       
            do (add-to-suffix-tries hmm word state count)))
  (maphash (lambda (k v)
             (declare (ignore k))
             (compute-suffix-trie-weights v))
           (hmm-suffix-tries hmm)))

(defun calculate-deleted-interpolation-weights (hmm)
  (let ((lambda-1 0)
        (lambda-2 0)
        (lambda-3 0)
        (n (hmm-n hmm)))
    (loop 
	for i from 0 below n
	do 
	  (loop 
	      for j from 0 below n
	      do (loop 
		     for k from 0 below n
		     for tri-count = (aref (hmm-trigram-table hmm) i j k)
		     when tri-count
		     do 
		       (let* ((bi-count (aref (hmm-transitions hmm) j k))
			      (uni-count (aref (hmm-unigram-table hmm) k))
			      (c1 (let ((bi-count (aref (hmm-transitions hmm) i j)))
				    (if (and bi-count
					     (> bi-count 1)
					     (> bi-count *estimation-cutoff*))
					(/ (1- tri-count)
					   (1- bi-count))
                                              0)))
			      (c2 (let ((uni-count (aref (hmm-unigram-table hmm) j)))
				    (if (and uni-count
					     (> uni-count 1)
					     (> uni-count *estimation-cutoff*))
					(/ (1- bi-count)
					   (1- uni-count))
				      0)))
			      (c3 (/ (1- uni-count)
				     (1- (hmm-token-count hmm)))))
			 (cond ((and (>= c3 c2) (>= c3 c1))
				(incf lambda-3 tri-count))
			       ((and (>= c2 c3) (>= c2 c1))
				(incf lambda-2 tri-count))
			       ((and (>= c1 c3) (>= c1 c2))
                                        (incf lambda-1 tri-count))
			       (t (error "What!")))))))
    ;; i have no idea why inverting these makes everyhing so much better
    ;; is there a bug somewhere?
    (let ((total (+ lambda-1 lambda-2 lambda-3)))
      (setf (hmm-lambda-3 hmm) (float (/ lambda-1 total)))
      (setf (hmm-lambda-2 hmm) (float (/ lambda-2 total)))
      (setf (hmm-lambda-1 hmm) (float (/ lambda-3 total)))
      hmm)))


(defun code-to-bigram (hmm bigram)
  (list (elt (hmm-tags hmm) (floor (/ bigram (hmm-n hmm))))
        (elt (hmm-tags hmm) (mod bigram (hmm-n hmm)))))

