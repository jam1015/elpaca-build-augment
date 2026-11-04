EMACS ?= emacs
INFO  := elpaca-build-augment.info
TEXI  := elpaca-build-augment.texi
ORG   := README.org

.PHONY: doc clean

doc: $(INFO)

$(INFO): $(ORG)
	$(EMACS) -Q --batch \
	  --eval "(require 'ox-texinfo)" \
	  --eval "(find-file \"$(ORG)\")" \
	  --eval "(org-texinfo-export-to-info)"

clean:
	rm -f $(INFO) $(TEXI)
