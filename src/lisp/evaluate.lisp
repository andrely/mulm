(in-package :mulm)

(defun evaluate-hmm (hmm file)
  (with-open-file (stream file :direction :input)
    (loop with total = 0 with correct = 0
          with forms with tags
          for i from 1
          for line = (read-line stream nil)
          for tab = (position #\tab line)
          for form = (normalize-token (subseq line 0 tab))
          for code = (symbol-to-code form)
          for tag = (and tab (subseq line (+ tab 1)))
          while line
          when (and form tag)
          do (push code forms)
          and do (push tag tags)
          else do (loop for gold in (nreverse tags)
                        for tag in (viterbi hmm (nreverse forms))
                        do (incf total)
                        when (string= gold tag)
                        do (incf correct))
                        and do (setf forms nil)
                        and do (setf tags nil)
                        finally (return (/ correct total)))))