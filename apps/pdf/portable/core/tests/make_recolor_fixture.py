"""Builds the recolor fixture PDF used by SPDFRecolorProbe: black body text on white paper, a colored
vector figure, and an embedded continuous-tone photograph. One page exercises
all three cases a document-agnostic dark mode has to get right."""
import os
import sys
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor

out, photo = sys.argv[1], sys.argv[2]

if not os.path.exists(photo):
    # A synthetic but continuous-tone stand-in: a warm sky-to-ground gradient
    # with a sun and soft foreground shapes. What matters for the probe is that
    # it has smooth luminance ramps and real hues, so a lightness inversion is
    # visibly wrong on it -- not that it is a photograph of anything.
    import numpy as np
    from PIL import Image

    n = 512
    yy, xx = np.mgrid[0:n, 0:n] / float(n - 1)
    sky = np.stack([0.15 + 0.55 * yy, 0.35 + 0.50 * yy, 0.70 + 0.25 * yy], axis=-1)
    ground = np.stack([0.45 - 0.20 * yy, 0.32 - 0.12 * yy, 0.16 - 0.06 * yy], axis=-1)
    horizon = 1.0 / (1.0 + np.exp(-(yy - 0.62) * 60.0))
    img = sky * (1.0 - horizon[..., None]) + ground * horizon[..., None]
    sun = np.exp(-(((xx - 0.72) ** 2 + (yy - 0.28) ** 2) / 0.006))
    img += sun[..., None] * np.array([0.95, 0.80, 0.45])
    hill = np.exp(-(((xx - 0.30) ** 2) / 0.10)) * 0.22
    img *= 1.0 - 0.45 * (yy > (0.66 - hill))[..., None]
    img += (np.random.default_rng(7).random((n, n, 1)) - 0.5) * 0.02
    Image.fromarray((np.clip(img, 0.0, 1.0) * 255.0).astype("uint8")).save(photo, quality=88)
    print("wrote", photo)

c = canvas.Canvas(out, pagesize=A4)
W, H = A4

c.setFillColor(HexColor("#FFFFFF"))
c.rect(0, 0, W, H, stroke=0, fill=1)

c.setFillColor(HexColor("#000000"))
c.setFont("Helvetica-Bold", 20)
c.drawString(20 * mm, H - 30 * mm, "Dark Reading Theme Fixture")
c.setFont("Helvetica", 10.5)
body = (
    "This page carries three kinds of content that a document-agnostic dark mode has to",
    "handle differently. The paragraph you are reading is plain black text on white paper:",
    "it must come out light on dark. Below it sits a saturated vector figure whose hues must",
    "survive the transform instead of rotating to their complements. At the bottom is a",
    "continuous-tone photograph, the case that a naive inversion turns into a negative.",
)
y = H - 40 * mm
for line in body:
    c.drawString(20 * mm, y, line)
    y -= 5.5 * mm

c.setFont("Helvetica", 10.5)
c.setFillColor(HexColor("#0969DA"))
c.drawString(20 * mm, y - 3 * mm, "A hyperlink-blue line of text.")
c.setFillColor(HexColor("#CF222E"))
c.drawString(75 * mm, y - 3 * mm, "A warning-red line of text.")

swatches = ["#E4002B", "#FF8C00", "#F5C400", "#1E9E52", "#0969DA", "#7F3FBF", "#00A5B5", "#8B4513"]
x = 20 * mm
sy = y - 22 * mm
for s in swatches:
    c.setFillColor(HexColor(s))
    c.rect(x, sy, 18 * mm, 18 * mm, stroke=0, fill=1)
    x += 20 * mm

c.setStrokeColor(HexColor("#1E9E52"))
c.setLineWidth(2)
c.rect(20 * mm, sy - 30 * mm, 170 * mm, 22 * mm, stroke=1, fill=0)
c.setFillColor(HexColor("#1E9E52"))
c.setFont("Helvetica-Bold", 12)
c.drawString(24 * mm, sy - 22 * mm, "Vector figure with a colored stroke and label")

c.drawImage(photo, 20 * mm, 20 * mm, width=110 * mm, height=110 * mm)
c.setFillColor(HexColor("#000000"))
c.setFont("Helvetica-Oblique", 9)
c.drawString(135 * mm, 25 * mm, "Figure 1. Photograph.")

c.showPage()
c.save()
print("wrote", out)
