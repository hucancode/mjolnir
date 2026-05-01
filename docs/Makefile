MD := $(wildcard *.md)
HTML := $(patsubst %.md,%.html,$(MD))

doc: $(HTML)

%.html: %.md style.css mermaid.html
	pandoc $< -s -c style.css --include-in-header=mermaid.html -o $@
clean:
	rm *.html

.PHONY: doc clean
