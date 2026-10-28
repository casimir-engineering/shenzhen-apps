# Opening a document in ShenzhenPDF from a web page

A link starting with `szpdf:` opens a document from the web in ShenzhenPDF: it starts the app, or, when ShenzhenPDF
is already open, opens the document in a new tab of its window and brings it forward. Clicking a link to a document
that is already open goes back to its tab.

A PDF shows page by page as it downloads: the first page appears as soon as its part of the file has arrived, the
other pages fill in, and a page the reader jumps to is fetched ahead of the rest. A thin bar along the top of the page
shows how far the download is. Once it has downloaded, the document is kept by ShenzhenPDF, opens again without a
connection, and can be saved to the Collection like any other.

## The link

Two forms name the same thing; use whichever is easier to write.

```
szpdf://open?url=<the document's address, percent-encoded>
szpdf://https/<host>/<path>
```

For `https://example.com/docs/spec.pdf`:

```
szpdf://open?url=https%3A%2F%2Fexample.com%2Fdocs%2Fspec.pdf
szpdf://https/example.com/docs/spec.pdf
```

Encode the address with `encodeURIComponent` (JavaScript) or `urllib.parse.quote(address, safe="")` (Python) for the
first form. The second form keeps the address's own query string (`szpdf://https/example.com/get?id=7`).

### Where it opens

| Add | Opens at | Works for |
|---|---|---|
| `&page=12` or `#page=12` | page 12 | every paged document; Markdown as ShenzhenPDF lays it out in pages |
| `&section=Pin%20map` or `#section=Pin%20map` | the outline entry with that title, or the named destination with that id | PDF (outline, bookmarks, named destinations), EPUB chapters |
| `&heading=Getting%20started` or `#heading=...` | that heading | Markdown |
| `#getting-started` | the heading with that slug, as GitHub forms them | Markdown |

`chapter=` is the same as `section=`, and a PDF's own `#nameddest=` works too. A title or heading is matched exactly
first, then ignoring case, then by its slug (lowercase, spaces as hyphens, punctuation dropped; a repeated heading
is `usage-1`, `usage-2`...). When nothing matches, the document opens at its start and a short note says the section
wasn't found.

```
szpdf://https/example.com/docs/spec.pdf#page=12
szpdf://open?url=https%3A%2F%2Fexample.com%2Fdocs%2Fspec.pdf&section=Pin%20map
szpdf://https/example.com/handbook/README.md#getting-started
szpdf://open?url=https%3A%2F%2Fexample.com%2Fbook.epub&chapter=Chapter%203
```

### What can be linked

Any document ShenzhenPDF opens: PDF, Markdown and text, EPUB, XPS, comic books, images. The type comes from the
address's file name; an address without an extension is taken to be a PDF. PDFs show page by page; Markdown and text
show what has arrived and grow as the rest comes; anything else opens once it has downloaded.

### Rules

- Only `https` addresses. Plain `http` works only for this computer (`localhost`, `127.0.0.1`, `[::1]`), so a site
  can be tried out locally. Other addresses (`http` elsewhere, `file:`, `ftp:`, `data:`, `javascript:`) and
  addresses with a user name or password in them are refused with a short message, and nothing is downloaded.
- A redirect may only lead to another `https` address.
- A link only ever names a document to download and show. Nothing in a link or a document is run.
- Documents up to 2 GB.
- The server should answer range requests (`Accept-Ranges: bytes`, as nginx, Apache, Caddy, S3 and most CDNs do)
  for the first page to show early. Without them a PDF downloads from its start; a linearized PDF may then show
  only when it has finished.

If the download fails, ShenzhenPDF says why in the reader's terms: the site couldn't be reached, there's no document
at that address (404), the site didn't allow the download (401, 403), or the link leads to something that isn't a
PDF. A download that stopped part way carries on from where it was when the link is clicked again, or when
ShenzhenPDF next starts with that tab open.

## A link on your page

The link alone works wherever ShenzhenPDF is installed. For visitors who don't have it, this offers the download
when nothing took the link: if the page is still in front a moment after the click, no app opened it.

```html
<a class="szpdf" href="szpdf://https/example.com/docs/spec.pdf#page=12">Open the spec in ShenzhenPDF</a>
<p class="szpdf-fallback" hidden>
  ShenzhenPDF didn't open?
  <a href="https://github.com/casimir-engineering/shenzhen-pdf/releases/latest/download/ShenzhenPDF-mac-arm64.dmg">Download ShenzhenPDF</a>
  (free, for Mac), or <a href="https://example.com/docs/spec.pdf">download the PDF</a>.
</p>
<script>
  for (const link of document.querySelectorAll("a.szpdf")) {
    link.addEventListener("click", () => {
      const fallback = link.nextElementSibling;
      let left = false;
      const away = () => { left = true; };
      window.addEventListener("blur", away, { once: true });
      document.addEventListener("visibilitychange", away, { once: true });
      setTimeout(() => { if (!left && document.hasFocus()) fallback.hidden = false; }, 1500);
    });
  }
</script>
```

The browser asks the first time whether to open ShenzhenPDF; that question takes the focus from the page, so the
fallback stays hidden.

## Platforms

- **macOS:** everything above.
- **Linux (GTK):** the desktop entry registers `x-scheme-handler/szpdf`. The document downloads whole (with `curl`)
  and then opens, at the page the link names.
- **Windows:** not yet.

For developers: the link is read by `portable/core/spdf_link.c` (tests in `portable/core/tests/SPDFCoreLinkTests.c`),
documents are read while they download through `portable/core/spdf_progressive.c`, and the macOS side is
`portable/mac/SPDFMacRemoteLinks.mm` and `SPDFMacRemoteDownload.mm`.
