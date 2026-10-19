# Capture script: core reading flow (sourced by capture.sh).
# App is already open on the test PDF; window in $WIN, output in $OUT.

settle 600
snap 01-first-paint.png

# Page navigation via page entry (Ctrl+L focuses it)
key ctrl+l; type "5"; key Return; settle 500
snap 02-page-5.png

# Anchored zoom in three steps (ctrl+equal: the "plus" keysym needs shift on
# some layouts and XTEST+clearmodifiers garbles it; equal is a bound alias)
key ctrl+equal; key ctrl+equal; key ctrl+equal; settle 700
snap 03-zoomed-in.png
key ctrl+0; settle 400

# Scroll to the landscape page (mixed sizes) and to the end
key ctrl+l; type "7"; key Return; settle 600
snap 04-landscape-page.png
key End; settle 800
snap 05-end-of-doc.png
key Home; settle 500

# Fit modes
key ctrl+1; settle 400; snap 06-fit-page.png
key ctrl+2; settle 400; snap 07-fit-width.png
