# -*- coding: utf-8 -*-
"""
make_case.py -- a case for the deck: a Cheap Yellow Display on a stand with a
row of three buttons underneath.

Two variants are produced:

  deck-plat-*.stl      flat and low (<= 30 mm), with the back sloping away.
                       Larger footprint: at a shallow angle the same control
                       surface simply needs more depth.
  deck-compact-*.stl   steeper and smaller in footprint, but taller.

Mind the trade-off: the shallower the angle, the thinner the front of the case
becomes -- and your switch bodies still have to fit in there. The script derives
the front edge from that and reports how much room is left for each variant.

    pip install trimesh manifold3d shapely
    python make_case.py
"""
import numpy as np, trimesh, math
from shapely.geometry import Polygon

# ------------------------------------------------------------------- variants
VARIANTEN = [
    dict(naam="deck-plat",    a_deg=9.0,  back_tilt=20.0, margin_top=10.0, max_h=30.0),
    dict(naam="deck-compact", a_deg=26.0, back_tilt=6.0,  margin_top=9.0,  max_h=99.0),
]

SWITCH     = "MX"    # "MX" (Cherry-like) or "CHOC" (Kailh low profile, much flatter)

WALL       = 2.4     # wall thickness
FACE_THK   = 3.0     # thickness of the control surface
BEZEL      = 1.8     # lip the board rests against
CLR        = 0.4     # clearance around the board
R_EDGE     = 3.0     # rounding of the side-profile edges
R_CORNER   = 6.0     # rounding of the four standing corners
R_SCREEN   = 2.5     # rounding of the screen opening's corners
CHAMFER    = 1.2     # chamfer around the screen opening

# CYD board (ESP32-2432S028R) -- measure yours!
PCB_W, PCB_H, PCB_THK = 86.5, 50.3, 1.6
PCB_BACK   = 8.0     # room the components on the back need
SCREEN_W, SCREEN_H = 57.6, 43.2
SCREEN_OFF_U = (PCB_W - SCREEN_W) / 2
SCREEN_OFF_V = (PCB_H - SCREEN_H) / 2

if SWITCH.upper() == "CHOC":
    CUT_U, CUT_V, PITCH, PLATE, SW_DEPTH, KEYCAP = 14.5, 13.8, 18.00, 1.3,  7.0, 17.5
else:
    CUT_U, CUT_V, PITCH, PLATE, SW_DEPTH, KEYCAP = 14.05, 14.05, 19.05, 1.5, 14.0, 18.0
RELIEF, N_KEYS = CUT_U + 1.55, 3

MARGIN_BOT = 5.5
KEY_BAND   = KEYCAP + 0.5
GAP        = 10.0    # between buttons and board; the two posts live here
SIDE_MARG  = 1.6
USB_V, USB_SLOT_V, USB_SLOT_W = PCB_H / 2, 15.0, 11.0
HOOK_OVER, HOOK_LEN, HOOK_THK = 2.5, 26.0, 2.0
BOSS_D, BOSS_H, BOSS_HOLE = 7.0, 6.0, 2.6

# Base plate: drops into the underside and screws into four corner bosses.
# The bottom edges are therefore not rounded -- the plate must sit flush.
PLATE_T    = 2.5     # thickness of the base plate
PLATE_CLR  = 0.35    # clearance all round, so it drops in without rubbing
PLATE_HOLE = 3.4     # M3 through hole
PLATE_CB_D = 6.4     # countersink for the screw head
PLATE_CB_T = 1.4
FOOT_HOLE  = 2.6     # pilot hole in the boss; M3 cuts its own thread there
FOOT_IN    = 6.5     # how far the bosses sit from the corner
FOOT_SZ    = 11.0    # diameter of the boss
FOOT_BACK  = 14.0    # the rear bosses sit further forward: the back wall
                     # slopes, so there is less room at the top than at
                     # the bottom


def export_solid(mesh, pad):
    """Export, then immediately check that the file really is closed.

       STL stores points in float32. Two points that are only just unequal in
       memory become two different points, and your slicer sees open edges. So
       snap to a 0.0001 mm grid and merge first -- and if that damages the model
       instead, export the original and say so."""
    kandidaat = mesh.copy()
    kandidaat.vertices = np.round(kandidaat.vertices, 4)
    kandidaat.merge_vertices()
    if kandidaat.is_watertight and abs(kandidaat.volume - mesh.volume) < 1.0:
        kandidaat.export(pad)
        m = kandidaat
    else:
        mesh.export(pad)
        m = mesh
    terug = trimesh.load(pad)
    if not terug.is_watertight:
        print("   NOTE: %s is not fully closed -- your slicer usually repairs this itself" % pad)
    return m


def finish(mesh):
    """Merge coincident points before exporting: STL stores float32, and without
       this step your slicer reports an 'open' model.

       Do it carefully: at a shallow angle the boolean operation produces
       paper-thin triangles, and cleaning those up can create holes instead. If
       the model does not improve, keep the original."""
    m = mesh.copy()
    m.merge_vertices()
    m.fix_normals()
    if mesh.is_watertight and not m.is_watertight:
        return mesh
    return m


def build(naam, a_deg, back_tilt, margin_top, max_h):
    A = math.radians(a_deg); COS, SIN = math.cos(A), math.sin(A)
    BT = math.radians(back_tilt)

    FACE_L = MARGIN_BOT + KEY_BAND + GAP + PCB_H + margin_top
    W      = max(PCB_W + 2 * SIDE_MARG, (N_KEYS - 1) * PITCH + CUT_U) + 2 * WALL
    V_KEYS = MARGIN_BOT + KEY_BAND / 2
    V_PCB0 = MARGIN_BOT + KEY_BAND + GAP
    U_PCB0 = (W - PCB_W) / 2
    V_PCB1 = V_PCB0 + PCB_H

    # Make the front edge exactly as tall as the buttons need. The base plate
    # counts: the switch bodies have to clear it.
    FRONT_H  = max(3.0, SW_DEPTH * COS + PLATE_T - V_KEYS * SIN + 0.6)
    D_FACE   = FACE_L * COS
    H        = FRONT_H + FACE_L * SIN
    BACK_RUN = H * math.tan(BT)
    D        = D_FACE + BACK_RUN

    clear_keys = (FRONT_H + V_KEYS * SIN - PLATE_T) / COS
    clear_back = margin_top * math.sin(math.pi - A - (math.pi / 2 - BT))

    print("\n%s: %.1f wide x %.1f deep x %.1f high mm" % (naam, W, D, H))
    print("   surface %.1f mm at %.0f degrees, front edge %.1f mm, back %.0f degrees off vertical"
          % (FACE_L, a_deg, FRONT_H, back_tilt))
    print("   room between the buttons and the base plate %.1f mm (need %.1f for %s)"
          % (clear_keys, SW_DEPTH, SWITCH.upper()))
    print("   room behind the top edge of the board %.1f mm (need ~%.1f)" % (clear_back, PCB_BACK))
    if H > max_h:      print("   NOTE: taller than the requested %.1f mm" % max_h)
    if clear_back < PCB_BACK - 0.2:
        print("   NOTE: tight behind the board -- raise margin_top or lower back_tilt")

    # ---- helpers in surface coordinates (u = width, v = along the slope,
    #      w = out of the surface)
    def face_T():
        T = np.eye(4)
        T[:3, :3] = np.array([[1, 0, 0], [0, COS, -SIN], [0, SIN, COS]])
        T[:3, 3] = [0.0, 0.0, FRONT_H]
        return T

    def face_box(u0, u1, v0, v1, w0, w1):
        b = trimesh.creation.box(extents=[u1 - u0, v1 - v0, w1 - w0])
        M = np.eye(4); M[:3, 3] = [(u0 + u1) / 2, (v0 + v1) / 2, (w0 + w1) / 2]
        return b.apply_transform(face_T() @ M)

    def face_cyl(u, v, w0, w1, d):
        c = trimesh.creation.cylinder(radius=d / 2, height=w1 - w0, sections=48)
        M = np.eye(4); M[:3, 3] = [u, v, (w0 + w1) / 2]
        return c.apply_transform(face_T() @ M)

    def round_convex(pts, r):
        return Polygon(pts).buffer(-r, join_style=1).buffer(r, join_style=1)

    def side_prism(poly, x0, x1):
        m = trimesh.creation.extrude_polygon(poly, height=x1 - x0)
        R = np.array([[0, 0, 1, x0], [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 1]], float)
        return m.apply_transform(R)

    def plan_prism(x0, x1, y0, y1, r, z0, z1):
        poly = Polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
        poly = poly.buffer(-r, join_style=1).buffer(r, join_style=1)
        m = trimesh.creation.extrude_polygon(poly, height=z1 - z0)
        m.apply_translation([0, 0, z0]); return m

    def rrect(u0, u1, v0, v1, r, n=10):
        pts, cs = [], [(u1 - r, v1 - r, 0), (u0 + r, v1 - r, 90),
                       (u0 + r, v0 + r, 180), (u1 - r, v0 + r, 270)]
        for cu, cv, a0 in cs:
            for k in range(n + 1):
                a = math.radians(a0 + 90.0 * k / n)
                pts.append((cu + r * math.cos(a), cv + r * math.sin(a)))
        return pts

    def loft(pa, wa, pb, wb):
        n = len(pa)
        verts = [(u, v, wa) for u, v in pa] + [(u, v, wb) for u, v in pb]
        faces = []
        for i in range(n):
            j = (i + 1) % n
            faces += [[i, j, n + j], [i, n + j, n + i]]
        ca, cb = len(verts), len(verts) + 1
        verts.append((float(np.mean([p[0] for p in pa])), float(np.mean([p[1] for p in pa])), wa))
        verts.append((float(np.mean([p[0] for p in pb])), float(np.mean([p[1] for p in pb])), wb))
        for i in range(n):
            j = (i + 1) % n
            faces += [[j, i, ca], [n + i, n + j, cb]]
        m = trimesh.Trimesh(vertices=np.array(verts, float), faces=np.array(faces))
        m.fix_normals()
        return m.apply_transform(face_T())

    def z_inner(y):
        return FRONT_H + y * math.tan(A) - FACE_THK / COS

    # ---- outer shape: a wedge with a sloping back, every edge rounded
    # The profile deliberately runs below zero and is cut off at z = 0: that puts
    # the roundings of the bottom corners below the cut line, leaving a dead
    # straight bottom edge for the base plate to seat against.
    outer = side_prism(round_convex([(0, -R_EDGE - 1), (D, -R_EDGE - 1),
                                     (D_FACE, H), (0, FRONT_H)], R_EDGE), 0, W)
    outer = outer.intersection(plan_prism(0, W, 0, D, R_CORNER, 0, H + 1))

    # ---- inner cavity, open at the bottom
    r_in   = max(R_EDGE - WALL, 0.8)
    tan_bt = math.tan(BT)
    C_in   = D - WALL / math.cos(BT)
    z_top  = (FRONT_H + C_in * math.tan(A) - FACE_THK / COS) / (1.0 + tan_bt * math.tan(A))
    y_top  = C_in - z_top * tan_bt
    inner = side_prism(round_convex([(WALL, -8), (C_in + 8 * tan_bt, -8),
                                     (y_top, z_top), (WALL, z_inner(WALL))], r_in),
                       WALL, W - WALL)
    inner = inner.intersection(plan_prism(WALL, W - WALL, WALL, D - WALL,
                                          max(R_CORNER - WALL, 0.8), -9, H + 1))
    shell = outer.difference(inner)

    # ---- screen window with rounded corners and a 45 degree chamfer.
    # Every cutting body pokes through the outer surface: a cutting face that
    # coincides exactly with the surface derails the boolean operation.
    su0, sv0 = U_PCB0 + SCREEN_OFF_U, V_PCB0 + SCREEN_OFF_V
    su1, sv1 = su0 + SCREEN_W, sv0 + SCREEN_H
    OVER = 0.5
    win_in  = rrect(su0, su1, sv0, sv1, R_SCREEN)
    win_out = rrect(su0 - CHAMFER - OVER, su1 + CHAMFER + OVER,
                    sv0 - CHAMFER - OVER, sv1 + CHAMFER + OVER, R_SCREEN + CHAMFER + OVER)
    shell = shell.difference(loft(win_in, -40.0, win_in, 5.0))
    shell = shell.difference(loft(win_in, -CHAMFER, win_out, OVER))

    # ---- recess for the board, with a lip of BEZEL
    shell = shell.difference(face_box(U_PCB0 - CLR, U_PCB0 + PCB_W + CLR,
                                      V_PCB0 - CLR, V_PCB1 + CLR, -40, -BEZEL))

    # ---- buttons
    u_first = W / 2 - ((N_KEYS - 1) * PITCH) / 2
    for i in range(N_KEYS):
        u = u_first + i * PITCH
        shell = shell.difference(face_box(u - CUT_U / 2, u + CUT_U / 2,
                                          V_KEYS - CUT_V / 2, V_KEYS + CUT_V / 2, -40, 5))
        shell = shell.difference(face_box(u - RELIEF / 2, u + RELIEF / 2,
                                          V_KEYS - RELIEF / 2, V_KEYS + RELIEF / 2, -40, -PLATE))

    # ---- cable slot in the left wall
    vc = V_PCB0 + USB_V
    shell = shell.difference(face_box(-6.0, WALL + 3.0, vc - USB_SLOT_V / 2, vc + USB_SLOT_V / 2,
                                      -(BEZEL + USB_SLOT_W), -BEZEL + 0.6))

    # ---- two hooks at the top: slide the board's top edge under these
    hw = BEZEL + PCB_THK + 0.3
    for du in (-1, 1):
        cu = W / 2 + du * (PCB_W / 4)
        # The two blocks overlap by 0.8 mm. Let them end exactly against each
        # other and two faces coincide, which leaves the boolean operation with
        # a few open edges there.
        shell = shell.union(face_box(cu - HOOK_LEN / 2, cu + HOOK_LEN / 2,
                                     V_PCB1 - HOOK_OVER, V_PCB1 + CLR + 0.8,
                                     -(hw + HOOK_THK), -hw))
        shell = shell.union(face_box(cu - HOOK_LEN / 2, cu + HOOK_LEN / 2,
                                     V_PCB1 + CLR, V_PCB1 + CLR + 3.0,
                                     -(hw + HOOK_THK), -FACE_THK + 0.01))

    # ---- two posts under the board for the clamp bar
    boss_v = V_PCB0 - (BOSS_D / 2 + 1.0)
    boss_u = [W / 2 - 30.0, W / 2 + 30.0]
    for bu in boss_u:
        shell = shell.union(face_cyl(bu, boss_v, -(FACE_THK + BOSS_H), -FACE_THK + 0.01, BOSS_D))
        shell = shell.difference(face_cyl(bu, boss_v, -(FACE_THK + BOSS_H) - 0.01, -1.0, BOSS_HOLE))

    # ---- four corner bosses for the base plate
    # A block in the corner, intersected with the inner cavity: that way the boss
    # meets both walls and the sloping surface by itself, and it prints along
    # upwards without support.
    r_plan = max(R_CORNER - WALL, 0.8)
    open_poly = Polygon([(WALL, WALL), (W - WALL, WALL),
                         (W - WALL, D - WALL), (WALL, D - WALL)])
    open_poly = open_poly.buffer(-r_plan, join_style=1).buffer(r_plan, join_style=1)
    open_poly = open_poly.intersection(Polygon([(-50, -50), (W + 50, -50),
                                                (W + 50, C_in), (-50, C_in)]))

    feet = [(WALL + FOOT_IN, WALL + FOOT_IN),
            (W - WALL - FOOT_IN, WALL + FOOT_IN),
            (WALL + FOOT_IN, C_in - FOOT_BACK),
            (W - WALL - FOOT_IN, C_in - FOOT_BACK)]
    # A plane that removes everything above the sloping surface, biting 0.6 mm
    # into the material. The bosses therefore overlap the surface cleanly:
    # exactly coincident faces are what derails a boolean operation.
    klip = face_box(-200.0, 400.0, -200.0, 400.0, -300.0, -(FACE_THK - 0.6))

    for (fx, fy) in feet:
        klos = trimesh.creation.box(extents=[FOOT_SZ, FOOT_SZ, H + 60])
        klos.apply_translation([fx, fy, PLATE_T + (H + 60) / 2])
        shell = shell.union(klos.intersection(klip))
        # pilot hole, but not through the sloping surface
        top = min(z_inner(fy) - 1.2, PLATE_T + 11.0)
        gat = trimesh.creation.cylinder(radius=FOOT_HOLE / 2, height=top - PLATE_T + 1.0,
                                        sections=32)
        gat.apply_translation([fx, fy, (top + PLATE_T - 1.0) / 2])
        shell = shell.difference(gat)

    # No final intersection with the outer shape any more: those two bodies share
    # their entire outer skin, and that is exactly the coincident case a boolean
    # operation breaks on. Everything is now built to stay inside the outer shape;
    # the check below enforces that.
    # One more pass through the boolean engine with a small block deep in the front
    # wall: that costs nothing in shape, but yields a clean, closed mesh.
    # Without this step a few paper-thin triangles remain, which come back as open
    # edges after exporting.
    kern = trimesh.creation.box(extents=[1.0, 1.0, 1.0])
    kern.apply_translation([W / 2, WALL / 2, FRONT_H / 2])
    try:
        shell = shell.union(kern)
    except Exception as e:
        print("   (cleanup skipped: %s)" % e)

    shell = finish(shell)
    ob = outer.bounds
    sb = shell.bounds
    if (sb[0] < ob[0] - 0.01).any() or (sb[1] > ob[1] + 0.01).any():
        print("   NOTE: something pokes outside the outer shape  %s vs %s"
              % (np.round(sb, 2).tolist(), np.round(ob, 2).tolist()))
    export_solid(shell, "%s-shell.stl" % naam)

    # Rotating for the print bed introduces rounding differences again, so run it
    # through the boolean engine once more and only then export.
    pr = shell.copy()
    Rp = np.eye(4); Rp[:3, :3] = np.array([[1, 0, 0], [0, COS, SIN], [0, -SIN, COS]])
    pr.apply_transform(Rp); pr.apply_translation([0, 0, -pr.bounds[0][2]])
    kern2 = trimesh.creation.box(extents=[1.0, 1.0, 1.0])
    kern2.apply_translation(pr.bounds.mean(axis=0) * [1, 1, 0] + [0, 0, 0.8])
    try:
        pr = pr.union(kern2)
    except Exception:
        pass
    pr = finish(pr)
    export_solid(pr, "%s-shell-print.stl" % naam)

    # ---- clamp bar
    BR_L, BR_W, BR_T = (boss_u[1] - boss_u[0]) + 14.0, 13.0, 3.6
    PAD_W, PAD_L = 3.0, 44.0
    PAD_H = FACE_THK + BOSS_H - (BEZEL + PCB_THK)
    bar = trimesh.creation.box(extents=[BR_L, BR_W, BR_T])
    bar.apply_translation([0, 0, BR_T / 2])
    bar = bar.intersection(plan_prism(-BR_L / 2, BR_L / 2, -BR_W / 2, BR_W / 2, 3.0, -1, BR_T + 1))
    pad = trimesh.creation.box(extents=[PAD_L, PAD_W, PAD_H])
    pad.apply_translation([0, (BR_W / 2 - PAD_W / 2), -PAD_H / 2])
    brace = bar.union(pad)
    for du in (-(BR_L / 2 - 7.0), (BR_L / 2 - 7.0)):
        hole = trimesh.creation.cylinder(radius=1.7, height=30, sections=40)
        hole.apply_translation([du, 0, 0])
        brace = brace.difference(hole)
    brace.apply_translation([0, 0, PAD_H])
    brace = finish(brace)
    export_solid(brace, "%s-brace.stl" % naam)

    # ---- base plate
    plate_poly = open_poly.buffer(-PLATE_CLR, join_style=1)
    plate = trimesh.creation.extrude_polygon(plate_poly, height=PLATE_T)
    for (fx, fy) in feet:
        door = trimesh.creation.cylinder(radius=PLATE_HOLE / 2, height=PLATE_T + 4, sections=40)
        door.apply_translation([fx, fy, PLATE_T / 2])
        plate = plate.difference(door)
        cb = trimesh.creation.cylinder(radius=PLATE_CB_D / 2, height=PLATE_CB_T * 2, sections=40)
        cb.apply_translation([fx, fy, 0.0])          # countersink on the underside
        plate = plate.difference(cb)
    plate = finish(plate)
    export_solid(plate, "%s-bodem.stl" % naam)

    print("   shell watertight=%s volume=%.0f mm3 | brace %s | base %s (%.1f x %.1f x %.1f mm)"
          % (shell.is_watertight, shell.volume, brace.is_watertight, plate.is_watertight,
             plate.extents[0], plate.extents[1], plate.extents[2]))
    return shell


for v in VARIANTEN:
    build(**v)
