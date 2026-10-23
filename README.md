# adamtoth.github.io

Personal site built with [Hugo](https://gohugo.io), hosted on GitHub Pages.

## Local development

```bash
hugo server -D
```

## Editing in Obsidian

Open the repository root (`blog/`) as your vault so that both `content/` and
`static/` are inside it. Use Reading view or Live Preview to see images.

Image links use paths relative to the Markdown file, for example:

```markdown
![Description](../../static/images/llm-platform-engineering-overview/gpu-vs-cpu-blog.jpg)
```

Hugo's image render hook converts these file paths to published image URLs,
including the site's `/blog/` prefix. In Obsidian's **Files and links** settings,
disable **Use Wikilinks**, set **New link format** to **Relative path to file**,
and set the attachment folder to `static/images` to keep new images compatible.

## New post

```bash
hugo new content blog/my-post-title.md
```

Set `draft: false` when ready to publish, then push to `main`.

## Deploy

Push to `main` — GitHub Actions handles the build and deploy automatically.

The GitHub Pages base URL is `https://adykaaa.github.io/blog/`. Post permalinks
omit the `content/blog` section name, so posts appear at `/blog/<post-name>/`.
Existing posts have aliases that redirect their former `/blog/blog/<post-name>/`
URLs to the new addresses.

## Article navigation

Add `toc: true` to an article's front matter to show a linked table of contents
above its text. It updates automatically when section headings change.
