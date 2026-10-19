# WebP figure

MuPDF has no WebP decoder, so before this fixture worked the picture below was
replaced by the placeholder word its HTML engine draws for an image it cannot
load. The reader now transcodes the file through WIC into the Markdown image
cache and MuPDF loads a PNG instead.

The prose here deliberately never spells that placeholder word out: md_webp_test
counts it on this page, and a copy in the text would make the count a lie.

![A WebP screenshot](md-shot.webp "The WebP fixture, transcoded through WIC")

A PNG next to it, which never needed transcoding, for comparison:

![A PNG icon](md-icon.png "The PNG control")

An inline WebP ![inline](md-shot.webp) keeps its flow inside a sentence.
