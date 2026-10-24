"""Porsche 911 side profile as finger strokes (pad mm), for: TrackpadDraw --test-draw porsche.json"""
import json, math

def P(x, y):  # design units (car ~100 long, front on the right) -> pad mm
    return [round(12 + x * 1.0, 2), round(20 + y * 1.0, 2)]

def arc(cx, cy, r, a0, a1, n=40):
    return [P(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]

def smooth(pts, n=8):  # Catmull-Rom through control points
    out = []
    for i in range(len(pts) - 1):
        p0, p1, p2, p3 = pts[max(i - 1, 0)], pts[i], pts[i + 1], pts[min(i + 2, len(pts) - 1)]
        for k in range(n):
            t = k / n
            out.append(P(*[0.5 * (2 * p1[j] + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                                  + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t ** 3) for j in (0, 1)]))
    out.append(P(*pts[-1]))
    return out

RED, BLACK, GREY = 2, 0, 1
strokes = []
def add(tool, color, size, pts): strokes.append({"tool": tool, "color": color, "size": size, "points": pts})

# Ground shadow (grey highlighter), drawn first so everything sits on it
add("highlighter", GREY, 1, [P(4, 0.6), P(98, 0.6)])
# Body: rear bumper -> fastback roof -> windshield -> hood -> round nose (one red stroke)
add("pen", RED, 2, smooth([(13.5, 8), (5, 8), (3, 10.5), (3.5, 14.5), (6.5, 17.5), (13, 21.5), (22, 26), (32, 29.6),
                           (41, 31), (48, 30.8), (53.5, 28.8), (58, 25), (62, 21.6), (70, 20.4), (79, 19.6),
                           (86, 19.4), (92, 17.8), (96, 15), (97.2, 11.5), (95.5, 8.8), (86.5, 8)]))
# Wheel arches and the sill between them
add("pen", RED, 2, arc(78, 8, 8.5, 0, 180))
add("pen", RED, 2, [P(69.5, 8), P(30.5, 8)])
add("pen", RED, 2, arc(22, 8, 8.5, 0, 180))
# Side window and B-pillar
add("pen", BLACK, 1, smooth([(15, 21), (23, 25.4), (32, 28.2), (41, 29.4), (48, 29.2), (52.5, 27.6), (57.5, 22), (56, 21), (16.5, 20.4), (15, 21)]))
add("pen", BLACK, 1, [P(43.5, 20.6), P(44, 29.3)])
# Door shut line, handle, headlight bump, fender line
add("pen", RED, 1, smooth([(58, 21.2), (59.5, 15), (58.5, 9.5)]))
add("pen", RED, 1, smooth([(43.5, 20.6), (43, 15), (41.5, 9.2)]))
add("pen", BLACK, 1, [P(38, 17.6), P(41.5, 17.6)])
add("pen", BLACK, 1, arc(88.5, 18.6, 2.2, 200, 340, 16))
add("pen", RED, 1, smooth([(6.5, 13.5), (30, 13.8), (60, 14.2), (95, 13.6)]))
# Wheels: tyres (marker), rims, hubs
for cx in (22, 78):
    add("marker", BLACK, 2, arc(cx, 8, 6.6, 0, 360, 48))
    add("pen", GREY, 1, arc(cx, 8, 3.8, 0, 360, 32))
    add("marker", GREY, 3, [P(cx - 0.3, 8), P(cx + 0.3, 8)])   # hub cap: a solid dot
# Tail light
add("pen", RED, 3, [P(4, 15.5), P(6.5, 16.6)])
json.dump(strokes, open("porsche.json", "w"))
print(len(strokes), "strokes")
