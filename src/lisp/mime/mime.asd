(defsystem :mime
  :description "Mime Experiment Manager"
  :version "0.1"
  :author "Johan Benum Evensberget, André Lynum"
  :license "GPL"
  :components ((:file "mime")
               (:file "experimemt" :depends-on ("mime")))
  :depends-on ("mulm"))
