MD := $(wildcard *.md)
HTML := $(patsubst %.md,%.html,$(MD))

doc: $(HTML)

%.html: %.md style.css
	pandoc $< -s -c style.css -o $@
clean:
	rm *.html

.PHONY: doc clean
