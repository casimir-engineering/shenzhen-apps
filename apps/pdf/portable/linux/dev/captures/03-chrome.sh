# Capture script: tabs, palette, sidebar, properties, minimap, presentation.

# Second tab (open via palette recents would need a prior run; use Ctrl+O path
# is interactive — instead the harness pre-opens files passed as extra args).
key F9; settle 500
snap 20-sidebar-chapters.png

key ctrl+k; settle 400
snap 21-palette.png
type "rotate"; settle 400
snap 22-palette-commands.png
key Escape; settle 200

key ctrl+i; settle 500
snap 23-properties.png
key Escape; settle 200

key F5; settle 800
snap 24-presentation.png
key Escape; settle 500

key ctrl+shift+o; settle 600
snap 25-tab-overview.png
key Escape; settle 300

key F1; settle 500
snap 26-shortcuts-help.png
key Escape; settle 200
