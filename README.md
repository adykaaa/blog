# adamtoth.github.io

Personal site built with [Hugo](https://gohugo.io), hosted on GitHub Pages.

## Local development

```bash
hugo server -D
```

## New post

```bash
hugo new content posts/my-post-title.md
```

Set `draft: false` when ready to publish, then push to `main`.

## Deploy

Push to `main` — GitHub Actions handles the build and deploy automatically.

## Article navigation

Add `toc: true` to an article's front matter to show a linked table of contents
above its text. It updates automatically when section headings change.
