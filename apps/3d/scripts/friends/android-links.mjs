// Friends links on Android (docs/FRIENDS.md § Tauri, Friends links): the intent filter that lets the system open
// shenzhen3d://friends/link#… in the app, written into the manifest of a Friends build by scripts/platform-build.mjs
// (which puts the committed manifest back afterwards). tauri-plugin-deep-link's build script writes the same block
// from phones.conf.json, but only when cargo runs it again, so a build after the manifest was put back would carry
// none; this writes it every time, between the plugin's own markers, so whichever runs last leaves one block.
const MARK = "<!-- DEEP LINK PLUGIN. AUTO-GENERATED. DO NOT REMOVE. -->";

/** The intent filter for each of `plugins.deep-link.mobile`'s custom schemes (no web links: nothing to verify). */
export function linkFilters(mobile) {
  return mobile.map((domain) =>
    [
      "<intent-filter>",
      '    <action android:name="android.intent.action.VIEW" />',
      '    <action android:name="org.chromium.arc.intent.action.VIEW" />',
      '    <category android:name="android.intent.category.DEFAULT" />',
      '    <category android:name="android.intent.category.BROWSABLE" />',
      ...domain.scheme.map(
        (scheme) => `    <data android:scheme="${scheme}" />`,
      ),
      ...(domain.host ? [`    <data android:host="${domain.host}" />`] : []),
      "</intent-filter>",
    ].join("\n"),
  );
}

/** `manifest` with the filters in its activity, replacing any block between the markers. */
export function withLinkFilters(manifest, mobile) {
  const lines = manifest.split("\n");
  const out = [];
  let inBlock = false;
  for (const line of lines) {
    if (line.includes(MARK)) {
      inBlock = !inBlock;
      continue;
    }
    if (inBlock) continue;
    const at = line.indexOf("</activity>");
    if (at >= 0) {
      const indent = " ".repeat(at + 4);
      out.push(indent + MARK);
      for (const filter of linkFilters(mobile))
        for (const filterLine of filter.split("\n"))
          out.push(indent + filterLine);
      out.push(indent + MARK);
    }
    out.push(line);
  }
  return out.join("\n");
}
