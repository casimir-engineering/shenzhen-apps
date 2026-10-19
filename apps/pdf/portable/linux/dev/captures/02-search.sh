# Capture script: search subsystem (sourced by capture.sh).

# Type-anywhere opens the search bar prefilled
type "connector"
settle 900
snap 10-type-anywhere-search.png

# Counter + next/prev
key ctrl+g; key ctrl+g; settle 400
snap 11-find-next.png

# Regex search
key ctrl+f; settle 200
key ctrl+a; type "SZP-00[0-9]+"; settle 300
# toggle regex via its button would need coords; keyboard path only if bound
settle 800
snap 12-search-query.png

# Escape clears
key Escape; settle 300
snap 13-search-cleared.png

# Chapter-grouped results sidebar (F9 sidebar, search results pane)
type "page"
settle 900
key F9; settle 500
snap 14-results-sidebar.png
key F9; key Escape; settle 300
