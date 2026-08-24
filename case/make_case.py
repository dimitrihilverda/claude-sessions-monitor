# -*- coding: utf-8 -*-
"""
make_case.py -- behuizing voor de Claude-deck: een Cheap Yellow Display op een
standaard met een rij van drie toetsen eronder.

Er worden twee varianten gemaakt:

  deck-plat-*.stl      vlak en laag (<= 30 mm), achterkant loopt schuin weg.
                       Grotere voetafdruk: bij een vlakke hoek heeft hetzelfde
                       bedieningsvlak nu eenmaal meer diepte nodig.
  deck-compact-*.stl   steiler en kleiner van voetafdruk, maar hoger.

Let op de wisselwerking: hoe vlakker de hoek, hoe dunner de voorkant van de
behuizing wordt -- en daar moet de body van je toetsen nog in passen. Het script
rekent de voorrand daarop uit en meldt per variant hoeveel ruimte er overblijft.

    pip install trimesh manifold3d shapely
    python make_case.py
"""
import numpy as np, trimesh, math
from shapely.geometry import Polygon

# ------------------------------------------------------------------ varianten
VARIANTEN = [
    dict(naam="deck-plat",    a_deg=9.0,  back_tilt=20.0, margin_top=10.0, max_h=30.0),
    dict(naam="deck-compact", a_deg=26.0, back_tilt=6.0,  margin_top=9.0,  max_h=99.0),
]

SWITCH     = "MX"    # "MX" (Cherry-achtig) of "CHOC" (Kailh low profile, veel platter)

WALL       = 2.4     # wanddikte
FACE_THK   = 3.0     # dikte van het bedieningsvlak
BEZEL      = 1.8     # lip waar de print tegenaan valt
CLR        = 0.4     # speling rondom de print
R_EDGE     = 3.0     # afronding van de zijprofiel-randen
R_CORNER   = 6.0     # afronding van de vier staande hoeken
R_SCREEN   = 2.5     # afronding van de hoeken van het schermgat
CHAMFER    = 1.2     # afschuining rondom het schermgat

# CYD-printplaat (ESP32-2432S028R) -- nameten!
PCB_W, PCB_H, PCB_THK = 86.5, 50.3, 1.6
PCB_BACK   = 8.0     # ruimte die de onderdelen op de achterkant nodig hebben
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
GAP        = 10.0    # tussen toetsen en print; hier zitten de twee pilaren
SIDE_MARG  = 1.6
USB_V, USB_SLOT_V, USB_SLOT_W = PCB_H / 2, 15.0, 11.0
HOOK_OVER, HOOK_LEN, HOOK_THK = 2.5, 26.0, 2.0
BOSS_D, BOSS_H, BOSS_HOLE = 7.0, 6.0, 2.6

# Grondplaat: valt in de onderkant en schroeft vast in vier hoekklossen.
# De onderranden zijn daarom niet afgerond -- de plaat moet vlak aansluiten.
PLATE_T    = 2.5     # dikte van de grondplaat
PLATE_CLR  = 0.35    # speling rondom, zodat hij er zonder schuren in valt
PLATE_HOLE = 3.4     # doorvoergat M3
PLATE_CB_D = 6.4     # verzinking voor de schroefkop
PLATE_CB_T = 1.4
FOOT_HOLE  = 2.6     # voorgat in de klos; M3 snijdt daar zijn eigen draad
FOOT_IN    = 6.5     # hoever de klossen uit de hoek liggen
FOOT_SZ    = 11.0    # doorsnede van de klos
FOOT_BACK  = 14.0    # de achterste klossen liggen verder naar voren: de
                     # achterwand loopt schuin, dus daar is bovenin minder
                     # ruimte dan onderin


def export_solid(mesh, pad):
    """Exporteren en meteen controleren of het bestand ook echt dicht is.

       STL slaat punten op in float32. Twee punten die in het geheugen net
       niet gelijk zijn, worden dan twee verschillende punten en je slicer ziet
       open randen. Daarom eerst op een raster van 0,0001 mm zetten en
       samenvoegen -- en als dat het model juist beschadigt, exporteren we het
       origineel en zeggen we dat erbij."""
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
        print("   LET OP: %s is niet volledig gesloten -- je slicer repareert dit meestal zelf" % pad)
    return m


def finish(mesh):
    """Punten die op elkaar liggen samenvoegen voor het exporteren: STL slaat op
       in float32 en zonder deze stap meldt je slicer een 'open' model.

       Voorzichtig doen: bij een vlakke hoek levert de booleaanse bewerking
       flinterdunne driehoekjes op, en die opruimen kan juist gaatjes maken.
       Wordt het model er niet beter van, dan houden we het origineel."""
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

    # De voorrand precies zo hoog als de toetsen nodig hebben. De grondplaat
    # telt mee: de body van de schakelaars moet er bovenlangs passen.
    FRONT_H  = max(3.0, SW_DEPTH * COS + PLATE_T - V_KEYS * SIN + 0.6)
    D_FACE   = FACE_L * COS
    H        = FRONT_H + FACE_L * SIN
    BACK_RUN = H * math.tan(BT)
    D        = D_FACE + BACK_RUN

    clear_keys = (FRONT_H + V_KEYS * SIN - PLATE_T) / COS
    clear_back = margin_top * math.sin(math.pi - A - (math.pi / 2 - BT))

    print("\n%s: %.1f breed x %.1f diep x %.1f hoog mm" % (naam, W, D, H))
    print("   vlak %.1f mm bij %.0f graden, voorrand %.1f mm, achterkant %.0f graden uit het lood"
          % (FACE_L, a_deg, FRONT_H, back_tilt))
    print("   ruimte tussen de toetsen en de grondplaat %.1f mm (nodig %.1f voor %s)"
          % (clear_keys, SW_DEPTH, SWITCH.upper()))
    print("   ruimte achter de bovenrand van de print %.1f mm (nodig ~%.1f)" % (clear_back, PCB_BACK))
    if H > max_h:      print("   LET OP: hoger dan de gevraagde %.1f mm" % max_h)
    if clear_back < PCB_BACK - 0.2:
        print("   LET OP: krap achter de print -- margin_top omhoog of back_tilt omlaag")

    # ---- hulpjes in vlak-coordinaten (u = breedte, v = langs de helling,
    #      w = uit het vlak naar buiten)
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

    # ---- buitenvorm: wig met schuine achterkant, alle randen afgerond
    # Het profiel loopt bewust door tot onder nul en wordt op z = 0 afgesneden:
    # dan komen de afrondingen van de onderhoeken onder de snijlijn te liggen en
    # houd je een kaarsrechte onderrand waar de grondplaat tegenaan sluit.
    outer = side_prism(round_convex([(0, -R_EDGE - 1), (D, -R_EDGE - 1),
                                     (D_FACE, H), (0, FRONT_H)], R_EDGE), 0, W)
    outer = outer.intersection(plan_prism(0, W, 0, D, R_CORNER, 0, H + 1))

    # ---- binnenholte, open onderkant
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

    # ---- schermvenster met afgeronde hoeken en een afschuining van 45 graden.
    # Elk snijlichaam steekt door het buitenvlak heen: een snijvlak dat precies
    # samenvalt met het oppervlak laat de booleaanse bewerking ontsporen.
    su0, sv0 = U_PCB0 + SCREEN_OFF_U, V_PCB0 + SCREEN_OFF_V
    su1, sv1 = su0 + SCREEN_W, sv0 + SCREEN_H
    OVER = 0.5
    win_in  = rrect(su0, su1, sv0, sv1, R_SCREEN)
    win_out = rrect(su0 - CHAMFER - OVER, su1 + CHAMFER + OVER,
                    sv0 - CHAMFER - OVER, sv1 + CHAMFER + OVER, R_SCREEN + CHAMFER + OVER)
    shell = shell.difference(loft(win_in, -40.0, win_in, 5.0))
    shell = shell.difference(loft(win_in, -CHAMFER, win_out, OVER))

    # ---- uitsparing voor de print, met een lip van BEZEL
    shell = shell.difference(face_box(U_PCB0 - CLR, U_PCB0 + PCB_W + CLR,
                                      V_PCB0 - CLR, V_PCB1 + CLR, -40, -BEZEL))

    # ---- toetsen
    u_first = W / 2 - ((N_KEYS - 1) * PITCH) / 2
    for i in range(N_KEYS):
        u = u_first + i * PITCH
        shell = shell.difference(face_box(u - CUT_U / 2, u + CUT_U / 2,
                                          V_KEYS - CUT_V / 2, V_KEYS + CUT_V / 2, -40, 5))
        shell = shell.difference(face_box(u - RELIEF / 2, u + RELIEF / 2,
                                          V_KEYS - RELIEF / 2, V_KEYS + RELIEF / 2, -40, -PLATE))

    # ---- kabelsleuf in de linkerwand
    vc = V_PCB0 + USB_V
    shell = shell.difference(face_box(-6.0, WALL + 3.0, vc - USB_SLOT_V / 2, vc + USB_SLOT_V / 2,
                                      -(BEZEL + USB_SLOT_W), -BEZEL + 0.6))

    # ---- twee haken bovenaan: daar schuif je de bovenrand van de print onder
    hw = BEZEL + PCB_THK + 0.3
    for du in (-1, 1):
        cu = W / 2 + du * (PCB_W / 4)
        # De twee blokjes overlappen elkaar 0,8 mm. Laat je ze precies tegen
        # elkaar aan eindigen, dan vallen twee vlakken samen en houdt de
        # booleaanse bewerking daar een paar open randen over.
        shell = shell.union(face_box(cu - HOOK_LEN / 2, cu + HOOK_LEN / 2,
                                     V_PCB1 - HOOK_OVER, V_PCB1 + CLR + 0.8,
                                     -(hw + HOOK_THK), -hw))
        shell = shell.union(face_box(cu - HOOK_LEN / 2, cu + HOOK_LEN / 2,
                                     V_PCB1 + CLR, V_PCB1 + CLR + 3.0,
                                     -(hw + HOOK_THK), -FACE_THK + 0.01))

    # ---- twee pilaren onder de print voor het klembalkje
    boss_v = V_PCB0 - (BOSS_D / 2 + 1.0)
    boss_u = [W / 2 - 30.0, W / 2 + 30.0]
    for bu in boss_u:
        shell = shell.union(face_cyl(bu, boss_v, -(FACE_THK + BOSS_H), -FACE_THK + 0.01, BOSS_D))
        shell = shell.difference(face_cyl(bu, boss_v, -(FACE_THK + BOSS_H) - 0.01, -1.0, BOSS_HOLE))

    # ---- vier hoekklossen voor de grondplaat
    # Een blok in de hoek, doorsneden met de binnenholte: zo sluit de klos
    # vanzelf aan op beide wanden en op het schuine vlak, en print hij mee
    # omhoog zonder support.
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
    # Een schaaf die alles wegneemt boven het schuine vlak, 0,6 mm het materiaal
    # in. De klossen overlappen het vlak daardoor netjes: precies samenvallende
    # vlakken zijn wat een booleaanse bewerking laat ontsporen.
    klip = face_box(-200.0, 400.0, -200.0, 400.0, -300.0, -(FACE_THK - 0.6))

    for (fx, fy) in feet:
        klos = trimesh.creation.box(extents=[FOOT_SZ, FOOT_SZ, H + 60])
        klos.apply_translation([fx, fy, PLATE_T + (H + 60) / 2])
        shell = shell.union(klos.intersection(klip))
        # voorgat, maar niet door het schuine vlak heen
        top = min(z_inner(fy) - 1.2, PLATE_T + 11.0)
        gat = trimesh.creation.cylinder(radius=FOOT_HOLE / 2, height=top - PLATE_T + 1.0,
                                        sections=32)
        gat.apply_translation([fx, fy, (top + PLATE_T - 1.0) / 2])
        shell = shell.difference(gat)

    # Geen slotintersectie met de buitenvorm meer: die twee lichamen delen hun
    # hele buitenhuid en dat is precies het samenvallende geval waar een
    # booleaanse bewerking op stukloopt. Alles is nu zo gebouwd dat het binnen
    # de buitenvorm blijft; onderstaande controle bewaakt dat.
    # Nog een keer door de booleaanse motor met een blokje diep in de voorwand:
    # dat kost niets aan vorm, maar levert wel een schone, gesloten mesh op.
    # Zonder deze stap blijven er een paar flinterdunne driehoekjes staan die na
    # het exporteren als open randen terugkomen.
    kern = trimesh.creation.box(extents=[1.0, 1.0, 1.0])
    kern.apply_translation([W / 2, WALL / 2, FRONT_H / 2])
    try:
        shell = shell.union(kern)
    except Exception as e:
        print("   (opschonen overgeslagen: %s)" % e)

    shell = finish(shell)
    ob = outer.bounds
    sb = shell.bounds
    if (sb[0] < ob[0] - 0.01).any() or (sb[1] > ob[1] + 0.01).any():
        print("   LET OP: er steekt iets buiten de buitenvorm  %s vs %s"
              % (np.round(sb, 2).tolist(), np.round(ob, 2).tolist()))
    export_solid(shell, "%s-shell.stl" % naam)

    # Draaien voor de printplaat introduceert weer afrondverschillen, dus daarna
    # nog een keer door de booleaanse motor en pas dan exporteren.
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

    # ---- klembalkje
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

    # ---- grondplaat
    plate_poly = open_poly.buffer(-PLATE_CLR, join_style=1)
    plate = trimesh.creation.extrude_polygon(plate_poly, height=PLATE_T)
    for (fx, fy) in feet:
        door = trimesh.creation.cylinder(radius=PLATE_HOLE / 2, height=PLATE_T + 4, sections=40)
        door.apply_translation([fx, fy, PLATE_T / 2])
        plate = plate.difference(door)
        cb = trimesh.creation.cylinder(radius=PLATE_CB_D / 2, height=PLATE_CB_T * 2, sections=40)
        cb.apply_translation([fx, fy, 0.0])          # verzinking aan de onderkant
        plate = plate.difference(cb)
    plate = finish(plate)
    export_solid(plate, "%s-bodem.stl" % naam)

    print("   shell watertight=%s volume=%.0f mm3 | brace %s | bodem %s (%.1f x %.1f x %.1f mm)"
          % (shell.is_watertight, shell.volume, brace.is_watertight, plate.is_watertight,
             plate.extents[0], plate.extents[1], plate.extents[2]))
    return shell


for v in VARIANTEN:
    build(**v)
