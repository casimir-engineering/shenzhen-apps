# Tab group palettes: changing the colours without a rebuild

ShenzhenPDF's palettes (Settings › Appearance › Tab group colors) can be changed or added to with one file:

    ~/Library/Application Support/ShenzhenPDF/tab-group-palettes.json

Save it and every open window repaints within a moment, and the Settings list shows the change. No restart is needed.

## Format

```json
{
  "palettes": [
    {
      "name": "Apple system",
      "colors": ["#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#2ed3b7", "#32ade6",
                 "#007aff", "#5856d6", "#af52de", "#af52de", "#ff2d55"]
    }
  ]
}
```

- `name`: a palette with the same name as a built-in one (Neon, Coolors vivid, Coolors pastel rainbow, Cyberpunk,
  Pastel, Pastel but vibrant, Apple system, Codex) replaces it. Any other name adds a new palette after the built-in
  ones. Names are on one line, at most 60 characters.
- `colors`: exactly 11 colours, `#rrggbb` (the `#` is optional), in this order: Coral, Orange, Amber, Green, Slate,
  Teal, Blue, Indigo, Purple, Plum, Rose. Groups keep their colour name, so the fifth colour is used for every Slate
  group, and so on. To use fewer colours, repeat one.
- Give only the palettes you change; the others stay as built in.

The app works out the rest from each colour, as for the built-in palettes: a white or near-black label, whichever
reads, with the colour deepened slightly for white labels, and an outline that stands out from the tab bar in light
and dark mode.

## When something is wrong

If the file is not valid (bad JSON, a missing name, not 11 colours, a colour that is not `#rrggbb`), the whole file is
ignored and the built-in palettes are shown. The reason is logged, so it shows in Console.app or with

    log show --last 5m --predicate 'process == "ShenzhenPDF"' | grep "tab group palettes"

Fix the file and save it again. Removing the file brings the built-in palettes back. If the palette chosen in Settings
was one the file added and it is gone, Neon is shown until it comes back.

The built-in palettes live in `portable/mac/SPDFMacTabGroups.mm` (`kBuiltIn`); move a palette there once it's final.
