HUGO ?= hugo
HUGO_ARGS ?=
PORT ?= 1313

.DEFAULT_GOAL := help
.PHONY: help preview serve build new drafts version

help:
	@printf '%s\n' \
	  'make preview             Serve locally with drafts and live reload' \
	  'make serve               Serve locally without drafts' \
	  'make build               Build the minified site in public/' \
	  'make new POST=my-title   Create content/blog/my-title.md' \
	  'make drafts              List draft content' \
	  'make version             Show the Hugo version' \
	  '' \
	  'Overrides: HUGO=hugo PORT=1313 HUGO_ARGS="..."'

preview:
	$(HUGO) server --buildDrafts --renderToMemory --port $(PORT) $(HUGO_ARGS)

serve:
	$(HUGO) server --renderToMemory --port $(PORT) $(HUGO_ARGS)

build:
	$(HUGO) build --gc --minify $(HUGO_ARGS)

new:
	@test -n "$(POST)" || { printf '%s\n' 'Usage: make new POST=my-post-title'; exit 1; }
	$(HUGO) new content "blog/$(POST).md" $(HUGO_ARGS)

drafts:
	$(HUGO) list drafts $(HUGO_ARGS)

version:
	$(HUGO) version
