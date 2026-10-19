# Search discovery — 2026-10-08

Published the dedicated [Shenzhen PDF Reader site](https://casimir-engineering.github.io/shenzhen-pdf/)
and a [Simplified Chinese page](https://casimir-engineering.github.io/shenzhen-pdf/zh/).
The repository previously linked only to the general Casimir Engineering site
and had no GitHub Pages site. Public descriptions now use “Shenzhen PDF Reader”
with “ShenzhenPDF” retained as an alternate name. Binary names, application IDs,
repository slug, release downloads and updater addresses were not changed.

The generator publishes curated HTML/CSS, two existing public screenshots, a
sitemap and public ownership proof. No application code or private handoff docs
are published. Content is readable without JavaScript; canonical and reciprocal
language links, descriptive titles, metadata and SoftwareApplication JSON-LD
are present. The site avoids third-party fonts, analytics and tracking scripts.
GitHub Actions automatically rebuilds it after content or release-version edits.

## Verified results

- Local build and website checks passed. Both pages were inspected in the browser.
- GitHub Pages deployment [37740256491](https://github.com/casimir-engineering/shenzhen-pdf/actions/runs/37740256491) succeeded.
- English, Chinese, sitemap and CSS URLs returned HTTP 200 with no X-Robots-Tag restriction.
- Requests using Googlebot, bingbot and Baiduspider user-agent strings returned
  HTTP 200. This is a reachability check, not proof of real crawler visits.
- Bing IndexNow returned **202** for the two page URLs: received, with ownership
  key validation pending. This is not a claim that either page is indexed.
- Repository homepage, description and relevant topics were updated.
- Google Search Console reached its sign-in form. Baidu Search Resource Platform
  also requires sign-in. Neither has been verified or directly submitted through
  a webmaster account yet. The account question remains with the user.
- Mainland-China reachability has not been independently verified. GitHub Pages
  hosting alone cannot guarantee it. A custom domain/hosting may be needed if
  Baidu's ownership process or regional reachability prevents progress.

Setup and account-specific follow-up steps are in
[website/README.md](../../../website/README.md). Search engines determine crawling,
indexing and ranking; there is no promised date or ranking.
