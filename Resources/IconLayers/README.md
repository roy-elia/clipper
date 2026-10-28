Full-bleed layers of the Fan app icon for Icon Composer, back to front: `background.svg` (white ground),
`clip-back.svg`, `clip-middle.svg` and `clip-front.svg` (the three clips, light to deep blue). No shadows or rims:
Icon Composer adds those. The shipped .icns is drawn in code by `ClipperMark.appIcon`, which bakes in a soft shadow
and rim instead and has its own two-clip drawing at 32 and 16 px; keep the large size of the two in step.
