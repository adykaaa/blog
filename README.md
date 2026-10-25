# adamtoth.github.io

Personal site built with [Hugo](https://gohugo.io), hosted on GitHub Pages.

## Local development

```bash
make preview
```

This starts Hugo with drafts and live reload enabled. Use `make serve` to
preview without drafts, `make build` to build the minified site in `public/`,
and `make drafts` to list draft content. Run `make help` for all commands.
Override the local port with `make preview PORT=1314` or pass extra Hugo flags
with `HUGO_ARGS="..."`.

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
make new POST=my-post-title
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

## Code copy buttons

To add a **Copy** button to `bash`, `python`, `yaml`, and `json` code blocks in an
article, set `copyCode: true` in its front matter. Readers get confirmation after
copying the code. Other blocks, including `text`, do not get a button.

## Article quizzes

Add a quiz at the end of an article with:

```text
## Test your understanding

{{< quiz id="inference-overview" >}}
```

Questions live in `data/quizzes/<id>.yaml`. Each quiz has a `title` and a
`questions` list. Each question defines `question`, four `options` (with `text`
and `correct: true` on the correct choices), `explanation`, and `section` (a
heading anchor such as `#prefill`). Set `multiple: true` for questions that
allow multiple answers. Question text, options, and explanations support inline
Markdown.

The quiz checks answers in the browser and awards one point per fully correct
question. Readers must answer every question before submitting. Explanations
and links back to the article appear after scoring, and **Try again** resets the
attempt. Quiz CSS and JavaScript load only on pages using the shortcode.
