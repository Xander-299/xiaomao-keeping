import json, math, sys

SRC = 'build/tmp/map/cn.json'
OUT = 'build/tmp/map/cn-map.json'
W = 1000.0
LON0, LON1 = 73.0, 135.5
LAT0, LAT1 = 53.8, 17.8
H = W * (LAT0 - LAT1) / ((LON1 - LON0) * math.cos(math.radians(35)))

ADCODE_TO_ISO = {
 11:'BJ',12:'TJ',13:'HE',14:'SX',15:'NM',21:'LN',22:'JL',23:'HL',31:'SH',32:'JS',
 33:'ZJ',34:'AH',35:'FJ',36:'JX',37:'SD',41:'HA',42:'HB',43:'HN',44:'GD',45:'GX',
 46:'HI',50:'CQ',51:'SC',52:'GZ',53:'YN',54:'XZ',61:'SN',62:'GS',63:'QH',64:'NX',
 65:'XJ',71:'TW',81:'HK',82:'MO',
}
SHORT = {'内蒙古自治区':'内蒙古','广西壮族自治区':'广西','西藏自治区':'西藏','宁夏回族自治区':'宁夏',
         '新疆维吾尔自治区':'新疆','香港特别行政区':'香港','澳门特别行政区':'澳门'}

def proj(lon, lat):
    x = (lon - LON0) / (LON1 - LON0) * W
    y = (LAT0 - lat) / (LAT0 - LAT1) * H
    return x, y

def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    def d(p, a, b):
        ax, ay = a; bx, by = b; px, py = p
        dx, dy = bx - ax, by - ay
        if dx == 0 and dy == 0:
            return math.hypot(px - ax, py - ay)
        t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
        t = max(0.0, min(1.0, t))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))
    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        dd = d(pts[i], pts[0], pts[-1])
        if dd > dmax:
            dmax, idx = dd, i
    if dmax > eps:
        left = rdp(pts[:idx + 1], eps)
        right = rdp(pts[idx:], eps)
        return left[:-1] + right
    return [pts[0], pts[-1]]

def ring_path(ring):
    pts = [(lon, lat) for lon, lat in ring]
    pts = rdp(pts, 0.05)          # 0.05° ≈ 5km，够用
    if len(pts) < 3:
        return ''
    out = []
    for i, (lon, lat) in enumerate(pts):
        x, y = proj(lon, lat)
        out.append(('M' if i == 0 else 'L') + f'{x:.1f},{y:.1f}')
    return ''.join(out) + 'Z'

data = json.load(open(SRC, encoding='utf-8'))
provinces = []
for f in data['features']:
    p = f['properties']
    name = p.get('name') or ''
    ad = p.get('adcode')
    if not name or not ad:
        continue
    code = ADCODE_TO_ISO.get(int(ad) // 10000)
    geom = f['geometry']
    if geom['type'] == 'Polygon':
        polys = [geom['coordinates']]
    elif geom['type'] == 'MultiPolygon':
        polys = geom['coordinates']
    else:
        continue
    d = ''.join(ring_path(r) for poly in polys for r in poly)
    if not d:
        continue
    provinces.append({'name': SHORT.get(name, name), 'full': name, 'code': code, 'd': d})

out = {'viewBox': f'0 0 {W:.0f} {H:.0f}', 'width': W, 'height': H, 'provinces': provinces}
json.dump(out, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
print('provinces', len(provinces), 'bytes', len(open(OUT, 'rb').read()))
print('missing code:', [p['name'] for p in provinces if not p['code']])
