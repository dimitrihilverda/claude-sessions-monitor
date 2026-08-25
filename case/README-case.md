# Printable case for the CYD, with three buttons

Two variants, both produced by the same script. Pick one:

| | **deck-plat** (flat) | **deck-compact** |
|---|---|---|
| outer size | 94.5 × 103.8 × **29.4** mm | 94.5 × 89.1 × 50.1 mm |
| tilt | 9° | 26° |
| front edge | 14.6 mm | 9.2 mm |
| back | 20° off vertical, sloping away | 6°, nearly upright |
| character | a flat slab, stays low in your eyeline | a clear wedge, smaller footprint |

The trade-off is fixed by geometry: the same 9 cm control surface has to go
somewhere. Lay it flatter and the case gets lower but deeper; stand it up and it
gets shorter but taller. Getting under 30 mm therefore cost 15 mm of extra depth.

There is a second thing the flat variant ran into. At a shallow angle the front
of the case becomes thin, while an MX switch needs about 14 mm behind the plate.
The script therefore derives the front edge from your switch type — which is why
the flat variant has an 11.5 mm front edge and the compact one only 6.7 mm. If
you want it genuinely thin, set `SWITCH = "CHOC"` at the top: Kailh low-profile
needs only 7 mm, and the front edge can then come down to roughly 4 mm.

| File | What |
|---|---|
| `deck-plat-shell-print.stl` | the shell, already oriented for the printer |
| `deck-plat-shell.stl` | the same, upright (easier to inspect) |
| `deck-plat-bodem.stl` | the base plate — **1×** |
| `deck-plat-brace.stl` | the clamp bar that holds the board — **1×** |
| `deck-compact-*.stl` | the same for the steeper variant |
| `make_case.py` | the generator; every dimension is at the top |
| `preview.png` | views, underside, exploded parts and a cross-section |

## The base plate

The bottom edges are deliberately *not* rounded, so the plate sits flush. It
drops into the underside, disappears entirely into the shell (so the height stays
29.4 mm) and fastens with four M3 screws into four bosses in the corners. The
screw heads are countersunk, keeping the underside flat.

Plate size: 89.0 × 98.2 × 2.5 mm. Clearance all round is 0.35 mm; if it rubs,
raise `PLATE_CLR` and re-run the script.

There is no snap fit, and that is a decision rather than an oversight: a snap
over a perimeter this large needs test prints to dial in, which I could not do
here. Screws work the first time.

Note the trade-off this creates: a closed bottom costs height, because the MX
switches stick down at the front and now have to clear the base plate. That is
why the flat variant went from 11° to 9°. With `SWITCH = "CHOC"` the problem
disappears — those need only 7 mm.

## How the board is held

Two fixed hooks at the top take the upper edge of the CYD. At the bottom it is
clamped by a single bar on two posts. That saved having screw posts above the
screen, which is precisely why this case could be shorter than the first version.

There is a 45° chamfer around the screen opening, and every outer edge is
rounded — 3 mm on the side profile, 6 mm on the standing corners.

## Before you print: measure yours

The CYD dimensions come from the datasheets of the common ESP32-2432S028R, but
variants exist. Take a caliper and check `PCB_W`, `PCB_H`, `SCREEN_W`,
`SCREEN_H`, where the glass sits on the board (`SCREEN_OFF_U/V`), and how high
the USB connector sits on the left edge (`USB_V`). `PCB_BACK` is an estimate too:
how much room the components on the back need. Adjust and re-run:

    pip install trimesh manifold3d shapely
    python make_case.py

For each variant the script reports the height and the two tight spots: the room
under the buttons, and the room behind the top edge of the board. If it does not
print a warning, it fits.

**Print only the bottom 5 mm first** of the `-print.stl` (cut it off in your
slicer). Ten minutes of work, and you know whether the screen opening and the
three button holes are right before you commit hours to it.

## Print settings

PLA or PETG, 0.2 mm layers, 3 walls, 15–20% infill, **no supports**: in the
`-print.stl` the control surface lies flat on the bed and the rest prints itself.
A brim helps against lifting.

## What else you need

- 3× MX switch (or Choc, if you change `SWITCH`) plus keycaps
- 6× M3 × 10 self-tapping screws — two for the clamp bar, four for the base plate
  (the pilot holes are 2.6 mm and cut their own thread)
- 1× 10 kΩ resistor
- Thin wire, and preferably two JST 1.25 mm 4-pin pigtails

## Wiring

Each switch has one leg to GND and the other to a GPIO:

| Button | GPIO | Note |
|---|---|---|
| 1 | 22 | internal pull-up, nothing else needed |
| 2 | 27 | internal pull-up, nothing else needed |
| 3 | 35 | **input-only, no internal pull-up**: 10 kΩ between pin 35 and 3V3 |
| 4 | 0 | the CYD's own BOOT button, no wiring needed |

On the common revision the two 4-pin JST connectors carry GND/IO35/IO22/IO21 and
GND/IO22/IO27/3V3. Several versions are in circulation, so meter yours before you
solder. IO21 is the backlight — leave that one alone.

## Assembly

1. Solder the switches and click them into the three holes (the plate is 1.5 mm
   there).
2. Wires to the connectors, cable towards the left side.
3. Slide the top edge of the CYD under the two hooks, then lower the bottom into
   its recess.
4. Lay the clamp bar over the bottom edge — raised lip facing the board — and
   screw it down. Not too tight.
5. USB cable through the slot in the left wall.
6. Drop in the base plate and fasten it with four screws. Four rubber feet
   underneath stop it sliding around.
