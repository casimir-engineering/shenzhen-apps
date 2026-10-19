# Shenzhen PDF Reader website and search visibility

Public site: https://casimir-engineering.github.io/shenzhen-pdf/
Chinese page: https://casimir-engineering.github.io/shenzhen-pdf/zh/
Sitemap: https://casimir-engineering.github.io/shenzhen-pdf/sitemap.xml

The public descriptive name is **Shenzhen PDF Reader**; **ShenzhenPDF** remains
an alternate name and the app's name. The repository slug, bundle identifiers,
release asset names and updater URLs remain unchanged.

## Build and deploy

```sh
python3 website/build.py
python3 website/check.py
```

Output goes to ignored `portable/build/website/`. Only the two HTML pages,
stylesheet, explicitly selected public screenshots, sitemap and ownership files
are deployed. The build does not publish the repository's documentation tree.
The GitHub Pages workflow deploys after relevant master changes, including
release-version updates. Links always point to the latest stable download.

The site is static HTML, works without JavaScript, serves its fonts locally from
the OS, and has reciprocal English/Chinese alternate links, canonical URLs,
descriptions, Open Graph metadata and SoftwareApplication structured data.
No ratings or reviews are invented. Images have descriptive alt text and
intrinsic dimensions. The two pages and their assets total less than 500 KB.

The four screenshots in `website/assets/` are resized WebP copies of the native
README fixtures, including the window controls. Refresh both sets with
`portable/mac/tests/refresh-readme-images.py`; see
`portable/docs/journals/ai-reader/readme-comparison-demo.md` for fixture details.
The chat example is explicitly scripted. Optional AI sends retrieved content to
OpenRouter/providers; the site must not describe all app features as offline.

## Submission and remaining account steps

Crawlability, submission, indexing, and ranking are different things. Deployment
or a successful URL submission does not promise inclusion or a ranking date.

- **Bing:** the workflow submits the sitemap's URLs through IndexNow after Pages
  deployment. It first fetches the published ownership file and checks its
  contents. HTTP 200 means receipt; 202 means key validation is pending. The
  key file is a public ownership proof, not a private account API token. A failed
  notification is visible as a warning and does not undo a successful deployment.
  To retry manually: `python3 website/submit-indexnow.py`.
- **Google:** sign in to [Search Console](https://search.google.com/search-console/),
  add the exact site URL as a **URL-prefix** property, and choose HTML-file
  verification. Put the provided verification file in `website/verification/`,
  deploy, and verify ownership. Submit `sitemap.xml`, then request indexing of the
  English and Chinese URLs using URL Inspection. Do not use Google's restricted
  jobs/live-video Indexing API for these software pages.
- **Baidu:** sign in to [百度搜索资源平台](https://ziyuan.baidu.com/), add and verify
  the site, then use 普通收录 to submit its URLs/sitemap if available to the
  verified site. Never commit the private Baidu submission token. If Baidu's
  verification requires control of a host root instead of a project subpath,
  use a user-controlled custom domain; do not create a fake proof. Chinese
  content is present, but reachability from mainland China needs a regional
  check and is not guaranteed by GitHub Pages hosting.

Google and Baidu account access is required for those direct submission steps;
a public HTML page alone does not establish a verified webmaster account.
The initial setup reached sign-in pages, not verified ownership or submission.

At this GitHub Pages **project path**, `/shenzhen-pdf/robots.txt` would not control
the host's crawlers. The build intentionally does not pretend otherwise: it
links the sitemap from HTML, and webmaster tools accept its explicit URL.
When building at a custom host root, the generator emits a proper `/robots.txt`.
If moving domains, update Pages/DNS and canonical URLs together, keep redirects
where possible, and reverify ownership. Do not block existing pages prematurely.

## Official references

- [Google: request crawling and submit sitemaps](https://developers.google.com/search/docs/crawling-indexing/ask-google-to-recrawl)
- [IndexNow: ownership, subpath keys, and response codes](https://www.indexnow.org/documentation)
- [Bing: sitemap submission](https://www.bing.com/webmasters/help/sitemaps-3b5cf6ed)
- [Baidu: ordinary-submission verification requirements](https://ziyuan.baidu.com/college/articleinfo?id=3198)
- [GitHub: Pages publication sources](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
