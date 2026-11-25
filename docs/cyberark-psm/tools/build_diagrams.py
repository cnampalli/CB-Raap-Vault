#!/usr/bin/env python3
"""Build the impact assessment diagrams as SVG (standard library only).

Usage:  python3 docs/cyberark-psm/tools/build_diagrams.py
Output: docs/cyberark-psm/images/*.svg

Every diagram is laid out by hand on a grid, in a Visio-like style:
zone containers with a coloured header band, component shapes by type,
right-angle connectors with labelled callouts, and a legend.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'images')
FONT = "Segoe UI, Inter, 'Helvetica Neue', Arial, sans-serif"

# Palette (header, fill) by zone family
Z = {
    'user':   ('#5B6B7F', '#F3F5F8'),
    'access': ('#0F7C8C', '#EAF6F7'),
    'session':('#1F5FA8', '#EAF1FA'),
    'cnd':    ('#3A4FA0', '#ECEEF8'),
    'core':   ('#9B2C2C', '#FBEDED'),
    'mgmt':   ('#6B4FA0', '#F2EEF8'),
    'admin':  ('#4A2E7A', '#EFEAF6'),
    'target': ('#2E7D4F', '#ECF6F0'),
    'ent':    ('#6E6E6E', '#F4F4F4'),
    'site':   ('#33475B', '#FFFFFF'),
    'class':  ('#33475B', '#FBFBFB'),
    'np':     ('#B26B00', '#FFF6E8'),
}
# Component fill by type
C = {
    'new':      ('#FFFFFF', '#1F5FA8'),
    'existing': ('#FFFFFF', '#7A869A'),
}
INK = '#1D2733'
MUTED = '#5C6B7A'
LINE = '#3D4B5C'
RED = '#B3261E'


class SVG:
    def __init__(self, w, h, title):
        self.w, self.h, self.title = w, h, title
        self.el = []
        self.defs = []

    def add(self, s):
        self.el.append(s)

    # ---------- primitives
    def text(self, x, y, s, size=12, weight='normal', color=INK, anchor='start', italic=False):
        lines = s.split('\n')
        dy0 = -(len(lines) - 1) * size * 0.6
        for i, ln in enumerate(lines):
            st = ' font-style="italic"' if italic else ''
            self.add(f'<text x="{x}" y="{y + dy0 + i * size * 1.2:.1f}" font-family="{FONT}" font-size="{size}" '
                     f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}" dominant-baseline="middle"{st}>'
                     f'{escape(ln)}</text>')

    def zone(self, x, y, w, h, title, kind, sub=None, dashed=False):
        hc, fc = Z[kind]
        dash = ' stroke-dasharray="6 4"' if dashed else ''
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fc}" stroke="{hc}" stroke-width="1.4"{dash}/>')
        self.add(f'<path d="M{x},{y + 6} a6,6 0 0 1 6,-6 h{w - 12} a6,6 0 0 1 6,6 v18 h{-w} z" fill="{hc}"/>')
        self.text(x + 10, y + 12, title, 12, 'bold', '#FFFFFF')
        if sub:
            self.text(x + w - 10, y + 12, sub, 10.5, 'normal', '#FFFFFF', 'end')

    def box(self, x, y, w, h, label, sub=None, kind='new', icon=None, accent=None):
        fill, stroke = C[kind]
        accent = accent or stroke
        dash = ' stroke-dasharray="5 3"' if kind == 'existing' else ''
        self.add(f'<rect x="{x + 2}" y="{y + 2}" width="{w}" height="{h}" rx="4" fill="#000" opacity="0.06"/>')
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="{fill}" stroke="{stroke}" stroke-width="1.2"{dash}/>')
        self.add(f'<rect x="{x}" y="{y}" width="5" height="{h}" rx="2" fill="{accent}"/>')
        tx = x + 12
        if icon:
            self.icon(icon, x + 22, y + h / 2, accent)
            tx = x + 40
        if sub:
            self.text(tx, y + h / 2 - 7, label, 12, '600')
            self.text(tx, y + h / 2 + 9, sub, 10.5, 'normal', MUTED)
        else:
            self.text(tx, y + h / 2, label, 12, '600')

    def icon(self, kind, cx, cy, col):
        if kind == 'server':
            for i in range(3):
                self.add(f'<rect x="{cx - 9}" y="{cy - 10 + i * 7}" width="18" height="6" rx="1" fill="none" stroke="{col}" stroke-width="1.2"/>')
                self.add(f'<circle cx="{cx + 5}" cy="{cy - 7 + i * 7}" r="1" fill="{col}"/>')
        elif kind == 'db':
            self.add(f'<ellipse cx="{cx}" cy="{cy - 7}" rx="9" ry="3.5" fill="none" stroke="{col}" stroke-width="1.2"/>')
            self.add(f'<path d="M{cx - 9},{cy - 7} v14 a9,3.5 0 0 0 18,0 v-14" fill="none" stroke="{col}" stroke-width="1.2"/>')
            self.add(f'<path d="M{cx - 9},{cy} a9,3.5 0 0 0 18,0" fill="none" stroke="{col}" stroke-width="1"/>')
        elif kind == 'user':
            self.add(f'<circle cx="{cx}" cy="{cy - 6}" r="4.5" fill="none" stroke="{col}" stroke-width="1.3"/>')
            self.add(f'<path d="M{cx - 9},{cy + 10} a9,8 0 0 1 18,0" fill="none" stroke="{col}" stroke-width="1.3"/>')
        elif kind == 'lb':
            self.add(f'<circle cx="{cx}" cy="{cy}" r="9" fill="none" stroke="{col}" stroke-width="1.3"/>')
            self.add(f'<path d="M{cx - 5},{cy} h10 M{cx + 2},{cy - 3} l3,3 l-3,3 M{cx - 5},{cy - 4} l4,0 M{cx - 5},{cy + 4} l4,0" fill="none" stroke="{col}" stroke-width="1.2"/>')
        elif kind == 'shield':
            self.add(f'<path d="M{cx},{cy - 10} l8,3 v6 c0,6 -4,9 -8,11 c-4,-2 -8,-5 -8,-11 v-6 z" fill="none" stroke="{col}" stroke-width="1.3"/>')
        elif kind == 'cloud':
            self.add(f'<path d="M{cx - 9},{cy + 5} a5,5 0 0 1 1,-9 a6,6 0 0 1 11,-2 a5,5 0 0 1 6,6 a4,4 0 0 1 -1,5 z" fill="none" stroke="{col}" stroke-width="1.2"/>')
        elif kind == 'doc':
            self.add(f'<path d="M{cx - 7},{cy - 9} h9 l5,5 v13 h-14 z M{cx + 2},{cy - 9} v5 h5" fill="none" stroke="{col}" stroke-width="1.2"/>')
        elif kind == 'gear':
            self.add(f'<circle cx="{cx}" cy="{cy}" r="5" fill="none" stroke="{col}" stroke-width="1.3"/>')
            for a in range(0, 360, 45):
                import math
                r1, r2 = 7, 10
                x1, y1 = cx + r1 * math.cos(math.radians(a)), cy + r1 * math.sin(math.radians(a))
                x2, y2 = cx + r2 * math.cos(math.radians(a)), cy + r2 * math.sin(math.radians(a))
                self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{col}" stroke-width="2"/>')

    def edge(self, pts, label=None, lpos=None, color=LINE, dashed=False, arrow='end', width=1.4, lsize=10.5):
        d = 'M' + ' L'.join(f'{x},{y}' for x, y in pts)
        dash = ' stroke-dasharray="5 4"' if dashed else ''
        m = ''
        mid = 'a' + color.replace('#', '')
        if mid not in self.defs:
            self.defs.append(mid)
        if arrow in ('end', 'both'):
            m += f' marker-end="url(#{mid})"'
        if arrow == 'both':
            m += f' marker-start="url(#{mid}s)"'
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{dash}{m}/>')
        if label:
            if lpos is None:
                (x1, y1), (x2, y2) = pts[len(pts) // 2 - 1], pts[len(pts) // 2]
                lpos = ((x1 + x2) / 2, (y1 + y2) / 2)
            self.callout(lpos[0], lpos[1], label, color, lsize)

    def callout(self, x, y, s, color=LINE, size=10.5):
        lines = s.split('\n')
        w = max(len(l) for l in lines) * size * 0.56 + 10
        h = len(lines) * size * 1.2 + 6
        self.add(f'<rect x="{x - w / 2:.1f}" y="{y - h / 2:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" fill="#FFFFFF" stroke="{color}" stroke-width="0.8"/>')
        self.text(x, y, s, size, 'normal', color, 'middle')

    def diamond(self, cx, cy, w, h, label, col='#1F5FA8'):
        self.add(f'<path d="M{cx},{cy - h / 2} L{cx + w / 2},{cy} L{cx},{cy + h / 2} L{cx - w / 2},{cy} z" fill="#FFFFFF" stroke="{col}" stroke-width="1.4"/>')
        self.text(cx, cy, label, 11.5, '600', INK, 'middle')

    def pill(self, x, y, w, h, label, fill, color='#FFFFFF', size=12):
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h / 2}" fill="{fill}"/>')
        self.text(x + w / 2, y + h / 2, label, size, '600', color, 'middle')

    def legend(self, x, y, items, title='Legend'):
        h = 26 + 22 * len(items)
        w = 250
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="#FFFFFF" stroke="#C9D1DB"/>')
        self.text(x + 10, y + 13, title, 11, 'bold', INK)
        for i, (kind, label) in enumerate(items):
            yy = y + 34 + i * 22
            if kind == 'new':
                self.add(f'<rect x="{x + 10}" y="{yy - 8}" width="26" height="16" rx="3" fill="#fff" stroke="#1F5FA8"/><rect x="{x + 10}" y="{yy - 8}" width="4" height="16" fill="#1F5FA8"/>')
            elif kind == 'existing':
                self.add(f'<rect x="{x + 10}" y="{yy - 8}" width="26" height="16" rx="3" fill="#fff" stroke="#7A869A" stroke-dasharray="5 3"/>')
            elif kind == 'flow':
                self.add(f'<line x1="{x + 10}" y1="{yy}" x2="{x + 36}" y2="{yy}" stroke="{LINE}" stroke-width="1.4" marker-end="url(#a3D4B5C)"/>')
            elif kind == 'dash':
                self.add(f'<line x1="{x + 10}" y1="{yy}" x2="{x + 36}" y2="{yy}" stroke="{LINE}" stroke-width="1.4" stroke-dasharray="5 4" marker-end="url(#a3D4B5C)"/>')
            elif kind == 'deny':
                self.add(f'<line x1="{x + 10}" y1="{yy}" x2="{x + 36}" y2="{yy}" stroke="{RED}" stroke-width="1.4" stroke-dasharray="5 4" marker-end="url(#aB3261E)"/>')
            elif kind.startswith('#'):
                self.add(f'<rect x="{x + 10}" y="{yy - 8}" width="26" height="16" rx="3" fill="{kind}"/>')
            self.text(x + 46, yy, label, 10.5, 'normal', INK)
        if 'a3D4B5C' not in self.defs:
            self.defs.append('a3D4B5C')
        if 'aB3261E' not in self.defs and any(k == 'deny' for k, _ in items):
            self.defs.append('aB3261E')

    def save(self, name):
        markers = ''
        for mid in self.defs:
            col = '#' + mid[1:]
            markers += (f'<marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
                        f'<path d="M0,0 L10,5 L0,10 z" fill="{col}"/></marker>')
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" '
               f'role="img" aria-label="{escape(self.title)}">'
               f'<title>{escape(self.title)}</title><defs>{markers}</defs>'
               f'<rect width="100%" height="100%" fill="#FFFFFF"/>' + ''.join(self.el) + '</svg>')
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, name), 'w') as f:
            f.write(svg)


# =====================================================================
def fig_overview():
    s = SVG(1180, 560, 'Solution overview')
    s.text(20, 530, 'One production classification shown; OFFICIAL, PROTECTED and SECRET are identical. Each pool is split across the primary and secondary sites.', 11, 'normal', MUTED)
    s.zone(20, 45, 200, 300, 'Users', 'user')
    s.box(35, 85, 170, 50, 'Administrators', 'smart card (PKIPN)', icon='user', accent='#5B6B7F')
    s.box(35, 150, 170, 50, 'CND analysts', '15, own pools', icon='user', accent='#5B6B7F')
    s.box(35, 215, 170, 50, 'Auditors', 'recordings, monitoring', icon='user', accent='#5B6B7F')
    s.zone(260, 45, 300, 300, 'PAM access and session', 'session')
    s.box(280, 85, 260, 46, 'PVWA', 'existing, 4 nodes', kind='existing', icon='server')
    s.box(280, 150, 260, 46, 'F5 load balancing', 'LTM per site + F5 DNS', icon='lb', accent='#0F7C8C')
    s.box(280, 215, 125, 50, 'PSM pool', 'Windows', icon='server')
    s.box(415, 215, 125, 50, 'PSMP pool', 'RHEL, SSH', icon='server')
    s.box(280, 280, 260, 46, 'CND PSM and PSMP pools', 'separate zone', icon='server', accent='#3A4FA0')
    s.zone(600, 45, 230, 300, 'PAM core and management', 'core')
    s.box(615, 85, 200, 50, 'Vault + DR Vault', 'existing', kind='existing', icon='db', accent='#9B2C2C')
    s.box(615, 150, 200, 46, 'CPM', 'existing; rotates passwords', kind='existing', icon='gear', accent='#6B4FA0')
    s.box(615, 210, 200, 46, 'PTA', 'threat analytics', icon='shield', accent='#6B4FA0')
    s.box(615, 270, 200, 50, 'Vault administration', '2 VMs, one per site', icon='server', accent='#4A2E7A')
    s.zone(870, 45, 290, 300, 'Targets', 'target')
    for i, (a, b) in enumerate([('Windows servers', 'RDP'), ('Linux / Unix, network', 'SSH'),
                                ('SQL Server, PostgreSQL', 'SSMS, pgAdmin'), ('Web consoles, OOB', 'browser')]):
        s.box(885, 85 + i * 62, 260, 48, a, b, icon='server', accent='#2E7D4F')
    s.zone(260, 380, 570, 110, 'Enterprise services', 'ent')
    s.box(280, 420, 160, 50, 'ServiceNow', 'ticket validation', kind='existing', icon='doc', accent='#6E6E6E')
    s.box(455, 420, 175, 50, 'Cribl, Splunk, DSOC', 'logs, use cases', kind='existing', icon='shield', accent='#6E6E6E')
    s.box(645, 420, 170, 50, 'AD, PKI, DNS', 'identity, certificates', kind='existing', icon='server', accent='#6E6E6E')
    # flows
    s.edge([(205, 110), (280, 108)], '1 log in, ticket', (242, 96))
    s.edge([(410, 131), (410, 150)])
    s.edge([(205, 175), (245, 175), (245, 172), (280, 172)], '2 RDP / SSH', (242, 190))
    s.edge([(340, 196), (340, 215)])
    s.edge([(470, 196), (470, 215)])
    s.edge([(360, 131), (360, 140), (230, 140), (230, 445), (280, 445)], '3 validate\nticket', (230, 365))
    s.edge([(540, 240), (580, 240), (580, 110), (615, 110)], None)
    s.callout(580, 185, '4 credential,\nrecording', LINE)
    s.edge([(540, 232), (560, 232), (560, 30), (1015, 30), (1015, 45)], '5 isolated, recorded session', (790, 30))
    s.edge([(815, 173), (885, 173)], 'rotate', (850, 160))
    s.edge([(715, 320), (715, 420)], 'logs, alerts', (715, 360))
    s.legend(870, 380, [('new', 'New component'), ('existing', 'Existing component'), ('flow', 'Flow, in step order')])
    s.save('fig01-solution-overview.svg')


def fig_classification():
    s = SVG(1180, 330, 'Classification boundaries')
    xs = [20, 410, 800]
    cw = 340
    names = ['OFFICIAL network', 'PROTECTED network', 'SECRET network']
    for i, x in enumerate(xs):
        s.zone(x, 70, cw, 240, names[i], 'class')
        s.box(x + 20, 110, cw - 40, 52, 'Production PAM stack', 'Vault, PVWA, CPM, PSM, PSMP, PTA', icon='server')
        s.box(x + 20, 175, cw - 40, 52, 'Enterprise services', 'AD, ServiceNow, Cribl, Splunk, DSOC', kind='existing', icon='server', accent='#6E6E6E')
    s.box(430, 240, cw - 40, 52, 'Non-production zone', 'test only; existing NP Vault, PVWA, CPM', icon='server', accent='#B26B00')
    for x in (370, 760):
        s.add(f'<line x1="{x + 15}" y1="80" x2="{x + 15}" y2="300" stroke="{RED}" stroke-width="2" stroke-dasharray="6 5"/>')
        s.add(f'<circle cx="{x + 15}" cy="190" r="11" fill="#fff" stroke="{RED}" stroke-width="2"/>'
              f'<line x1="{x + 7}" y1="182" x2="{x + 23}" y2="198" stroke="{RED}" stroke-width="2"/>')
    s.callout(385, 250, 'no\nflows', RED)
    s.callout(775, 250, 'no\nflows', RED)
    s.box(820, 12, 200, 40, 'Cross-domain solution', 'CDS', kind='existing', icon='shield', accent='#9B2C2C')
    s.edge([(1020, 32), (1100, 32), (1100, 70)], 'software media,\none way in', (1100, 40), arrow='end')
    s.text(20, 30, 'Each classification is a self-contained network.', 12, '600')
    s.text(20, 50, 'Nothing crosses between classifications; SECRET receives software only through the CDS.', 11, 'normal', MUTED)
    s.save('fig02-classification-boundaries.svg')


def fig_zones():
    s = SVG(1240, 900, 'Network zones and component placement')
    # Z1, Z2
    s.zone(40, 40, 330, 120, 'Z1  User zone', 'user', 'trust: low')
    s.box(55, 75, 145, 70, 'Admin', 'workstations', icon='user', accent='#5B6B7F')
    s.box(210, 75, 145, 70, 'Auditor', 'workstations', icon='user', accent='#5B6B7F')
    s.zone(400, 40, 200, 120, 'Z2  CND zone', 'user', 'low')
    s.box(415, 75, 170, 70, 'CND', 'workstations', icon='user', accent='#5B6B7F')
    # Z3
    s.zone(40, 210, 560, 110, 'Z3  PAM access zone', 'access', 'trust: medium')
    s.box(55, 245, 260, 60, 'F5 LTM virtual servers', 'psm, psmp, psm-cnd, psmp-cnd', icon='lb', accent='#0F7C8C')
    s.box(330, 245, 255, 60, 'PVWA x4', 'existing; smart-card login', kind='existing', icon='server')
    # Z4a Z4b
    s.zone(40, 370, 270, 120, 'Z4a  Session: consumer', 'session', 'high')
    s.box(55, 405, 115, 70, 'PSM x4', 'Windows', icon='server')
    s.box(180, 405, 115, 70, 'PSMP x4', 'RHEL 8', icon='server')
    s.zone(330, 370, 270, 120, 'Z4b  Session: CND', 'cnd', 'high')
    s.box(345, 405, 115, 70, 'PSM x2', 'Windows', icon='server', accent='#3A4FA0')
    s.box(470, 405, 115, 70, 'PSMP x2', 'RHEL 8', icon='server', accent='#3A4FA0')
    # Z5 Z6 Z9
    s.zone(40, 540, 270, 120, 'Z5  PAM core', 'core', 'highest')
    s.box(55, 575, 115, 70, 'Vault', 'existing', kind='existing', icon='db', accent='#9B2C2C')
    s.box(180, 575, 115, 70, 'DR Vault', 'existing', kind='existing', icon='db', accent='#9B2C2C')
    s.zone(330, 540, 270, 120, 'Z6  PAM management', 'mgmt', 'high')
    s.box(345, 575, 115, 70, 'CPM x2', 'existing', kind='existing', icon='gear', accent='#6B4FA0')
    s.box(470, 575, 115, 70, 'PTA x1', 'RHEL 8', icon='shield', accent='#6B4FA0')
    s.zone(640, 540, 200, 120, 'Z9  PAM administration', 'admin', 'highest')
    s.box(655, 575, 170, 70, 'Vault admin VM x2', 'one per site', icon='server', accent='#4A2E7A')
    # Z7
    s.zone(40, 720, 800, 120, 'Z7  Target zones', 'target', 'trust: varies')
    for i, (a, b) in enumerate([('Windows', 'servers'), ('Linux / Unix', 'servers'), ('Network', 'devices'),
                                ('SQL Server', 'PostgreSQL'), ('Web consoles', 'and OOB')]):
        s.box(55 + i * 156, 755, 145, 70, a, b, icon='server', accent='#2E7D4F')
    # Z8
    s.zone(900, 40, 300, 800, 'Z8  Enterprise services', 'ent', 'high')
    for i, (a, b) in enumerate([('F5 DNS', 'wide IPs, both sites'), ('AD, DNS, NTP', 'directory, time'),
                                ('PKI, CRL/OCSP', 'proxy (not SECRET)'), ('ServiceNow', 'ticket validation'),
                                ('Cribl, Splunk, DSOC', 'logging, use cases'), ('Monitoring', 'health, F5 drain'),
                                ('Patching, EDR, backup', 'operations'), ('Ansible controller', 'build')]):
        s.box(915, 80 + i * 92, 270, 70, a, b, kind='existing', icon='server', accent='#6E6E6E')
    # flows
    s.edge([(130, 160), (130, 210)], 'F1, F2', (130, 185))
    s.edge([(500, 160), (500, 210)], 'F1, F3', (500, 185))
    s.edge([(150, 320), (150, 370)], 'F5', (150, 345))
    s.edge([(250, 305), (250, 340), (420, 340), (420, 370)], 'F5', (335, 340))
    s.edge([(440, 370), (440, 352), (530, 352), (530, 305)], 'F6 ticket', (560, 345), dashed=True)
    s.edge([(110, 490), (110, 540)], 'F9 1858', (110, 515))
    s.edge([(400, 490), (400, 515), (240, 515), (240, 540)], 'F9', (320, 515))
    s.edge([(740, 660), (740, 690), (175, 690), (175, 660)], 'F9, F10  1858, 9022', (300, 690))
    s.edge([(310, 600), (345, 600)], 'F12', (327, 588), lsize=9.5)
    s.edge([(40, 440), (22, 440), (22, 790), (55, 790)], 'F23, F24', (22, 610))
    s.edge([(600, 430), (620, 430), (620, 720)], 'F23, F24', (620, 620))
    s.edge([(500, 660), (500, 720)], 'F25 CPM', (540, 705))
    s.edge([(600, 275), (915, 275)], 'F7, F8  ServiceNow, CRL', (760, 262))
    s.edge([(600, 100), (915, 100)], 'F4  DNS', (760, 100))
    s.edge([(915, 135), (880, 135), (880, 240), (600, 240)], 'F19 iQuery', (880, 190))
    s.edge([(840, 600), (880, 600), (880, 535), (915, 535)], 'F15, F16, F21', (880, 560))
    s.legend(640, 380, [('new', 'New component'), ('existing', 'Existing component'), ('flow', 'Allowed flow (Fn = flow matrix)')])
    s.save('fig03-network-zones.svg')


def fig_sites():
    s = SVG(1240, 740, 'Primary and secondary sites')
    s.box(500, 15, 240, 56, 'Users (Z1, Z2)', 'RDP, SSH, browser to PVWA', icon='user', accent='#5B6B7F')
    s.box(500, 105, 240, 56, 'F5 DNS wide IPs', 'listeners at both sites; TTL 30 s', icon='lb', accent='#0F7C8C')
    s.edge([(620, 71), (620, 105)], '1 resolve', (660, 88))
    for side, x, label in (('P', 30, 'Primary site'), ('S', 650, 'Secondary site')):
        s.zone(x, 190, 560, 530, label, 'site')
        s.zone(x + 15, 225, 530, 90, 'Z3  Access', 'access')
        s.box(x + 30, 255, 250, 48, 'F5 LTM HA pair', '4 virtual servers, local nodes only', icon='lb', accent='#0F7C8C')
        s.box(x + 295, 255, 235, 48, 'PVWA x2', 'existing, active', kind='existing', icon='server')
        s.zone(x + 15, 335, 530, 110, 'Z4a / Z4b  Session', 'session')
        s.box(x + 30, 368, 160, 62, 'Consumer PSM x2', '+ contingency', icon='server')
        s.box(x + 200, 368, 160, 62, 'Consumer PSMP x2', 'RHEL 8', icon='server')
        s.box(x + 370, 368, 160, 62, 'CND PSM x1', 'CND PSMP x1', icon='server', accent='#3A4FA0')
        if side == 'P':
            zx = {'Z9': x + 15, 'Z6': x + 195, 'Z5': x + 385}
        else:
            zx = {'Z5': x + 15, 'Z6': x + 195, 'Z9': x + 385}
        s.zone(zx['Z5'], 465, 160, 110, 'Z5  Core', 'core')
        s.zone(zx['Z6'], 465, 175, 110, 'Z6  Management', 'mgmt')
        s.zone(zx['Z9'], 465, 160, 110, 'Z9  Administration', 'admin')
        if side == 'P':
            s.box(zx['Z5'] + 10, 500, 140, 60, 'Vault', 'ACTIVE', kind='existing', icon='db', accent='#9B2C2C')
            s.box(zx['Z6'] + 10, 495, 155, 34, 'CPM: active', None, kind='existing', accent='#6B4FA0')
            s.box(zx['Z6'] + 10, 535, 155, 34, 'PTA (single)', None, accent='#6B4FA0')
            s.box(zx['Z9'] + 10, 500, 140, 60, 'Vault admin VM', 'administers Vault', icon='server', accent='#4A2E7A')
        else:
            s.box(zx['Z5'] + 10, 500, 140, 60, 'DR Vault', 'PASSIVE', kind='existing', icon='db', accent='#9B2C2C')
            s.box(zx['Z6'] + 10, 495, 155, 34, 'CPM: standby', None, kind='existing', accent='#6B4FA0')
            s.box(zx['Z6'] + 10, 535, 155, 34, 'PTA rebuild target', None, kind='existing', accent='#6B4FA0')
            s.box(zx['Z9'] + 10, 500, 140, 60, 'Vault admin VM', 'DR Vault; standby', icon='server', accent='#4A2E7A')
        s.edge([(x + 155, 303), (x + 155, 368)], 'local only', (x + 155, 336))
        s.add(f'<rect x="{x + 15}" y="595" width="530" height="110" rx="4" fill="#FFFFFF" stroke="#C9D1DB"/>')
        s.text(x + 30, 615, 'If this site is lost:', 11, 'bold')
        if side == 'P':
            txt = ['F5 DNS answers only with the secondary site; users reconnect (TTL 30 s).',
                   'Vault fails over to the DR Vault under the existing DR procedure.',
                   'Secondary CPM and Vault admin VM take over; PTA is rebuilt (2 days).']
        else:
            txt = ['F5 DNS answers only with the primary site.',
                   'Half of each pool remains (NFR1); no change to the Vault.',
                   'Primary Vault admin VM continues.']
        for i, t in enumerate(txt):
            s.text(x + 30, 640 + i * 20, '•  ' + t, 10.5, 'normal', INK)
    s.edge([(560, 133), (155, 133), (155, 255)], '2a session', (300, 133))
    s.edge([(680, 133), (775, 133), (775, 255)], '2b session', (720, 120))
    s.edge([(555, 545), (675, 545)], 'replication', (620, 560))
    s.edge([(700, 430), (700, 452), (620, 452), (620, 515), (560, 515)], '1858 cross-site', (620, 480), dashed=True)
    s.edge([(480, 430), (480, 500)], '1858', (505, 450))
    s.legend(990, 15, [('new', 'New component'), ('existing', 'Existing component'), ('dash', 'Cross-site flow')])
    s.save('fig04-sites.svg')


def sequence(name, title, parts, msgs, h, alt=None):
    w = 170 * len(parts) + 60
    s = SVG(w, h, title)
    xs = [100 + i * 170 for i in range(len(parts))]
    for x, (p, sub, kind) in zip(xs, parts):
        accent = {'user': '#5B6B7F', 'access': '#0F7C8C', 'session': '#1F5FA8', 'core': '#9B2C2C',
                  'ent': '#6E6E6E', 'target': '#2E7D4F'}[kind]
        s.box(x - 75, 15, 150, 50, p, sub, kind='existing' if kind in ('ent', 'core') else 'new', accent=accent)
        s.add(f'<line x1="{x}" y1="65" x2="{x}" y2="{h - 20}" stroke="#9AA6B2" stroke-width="1" stroke-dasharray="4 4"/>')
    y = 95
    if alt:
        ay0, ay1, label = alt
        s.add(f'<rect x="30" y="{ay0}" width="{w - 60}" height="{ay1 - ay0}" rx="4" fill="#FFF8F7" stroke="{RED}" stroke-dasharray="5 3"/>')
        s.text(40, ay0 + 12, label, 10.5, 'bold', RED)
    for n, (a, b, text, ret) in enumerate(msgs, 1):
        if a is None:
            y += 10
            continue
        x1, x2 = xs[a], xs[b]
        col = RED if text.startswith('!') else LINE
        text = text.lstrip('!')
        if a == b:
            s.edge([(x1, y), (x1 + 40, y), (x1 + 40, y + 16), (x1 + 4, y + 16)], None, color=col)
            s.text(x1 + 48, y + 8, f'{n}. {text}', 11, 'normal', col)
            y += 40
            continue
        s.edge([(x1, y), (x2 + (-6 if x2 > x1 else 6), y)], None, color=col, dashed=ret)
        s.text((x1 + x2) / 2, y - 10, f'{n}. {text}', 11, 'normal', col, 'middle')
        y += 38
    s.save(name)


def fig_rdp():
    parts = [('User', 'smart card', 'user'), ('PVWA', 'existing', 'access'), ('ServiceNow', 'existing', 'ent'),
             ('F5 virtual server', 'site-local', 'access'), ('PSM node', 'Windows', 'session'),
             ('Vault', 'existing', 'core'), ('Target', 'Windows, DB, web', 'target')]
    msgs = [(0, 1, 'Smart-card login (PKIPN)', False), (0, 1, 'Pick account, Connect, enter ticket', False),
            (1, 2, 'Validate ticket', False), (2, 1, 'Allowed', True), (1, 0, 'One-time RDP file', True),
            (0, 3, 'mstsc opens RDP to wide-IP name', False), (3, 4, 'Route to healthy local node', False),
            (4, 5, 'Fetch credential (never shown)', False), (4, 6, 'Connect with credential', False),
            (4, 0, 'Isolated, recorded session', True), (4, 5, 'Upload recording at session end', False)]
    sequence('fig05-rdp-session.svg', 'RDP, database and web session', parts, msgs, 540,
             alt=None)


def fig_ssh():
    parts = [('User', 'native SSH client', 'user'), ('F5 virtual server', 'site-local', 'access'),
             ('PSMP node', 'RHEL 8', 'session'), ('PVWA', 'existing', 'access'), ('ServiceNow', 'existing', 'ent'),
             ('Vault', 'existing', 'core'), ('Target', 'Linux, network', 'target')]
    msgs = [(0, 1, 'ssh user@account@target@psmp', False), (1, 2, 'Route to healthy local node', False),
            (2, 0, 'Authenticate: AD + MFA-caching key', True), (2, 0, 'Prompt: ticketing system, ticket ID', True),
            (0, 2, 'Ticket ID', False), (2, 3, 'Validate ticket', False), (3, 4, 'Check ticket', False),
            (4, 3, 'Allowed', True), (3, 2, 'Result', True), (2, 5, 'Fetch credential', False),
            (2, 6, 'SSH with credential', False), (2, 0, 'Recorded session', True)]
    sequence('fig06-ssh-session.svg', 'SSH session through PSMP', parts, msgs, 560)


def fig_ticket():
    s = SVG(1100, 430, 'Ticket decision')
    s.box(20, 175, 190, 60, 'User enters ticket', 'PVWA Connect or PSMP prompt', icon='doc')
    s.diamond(330, 205, 170, 90, 'ServiceNow\nreachable?')
    s.diamond(560, 105, 200, 110, 'Eligible ticket,\nflag true,\nrequester matches?')
    s.diamond(560, 320, 190, 90, 'Emergency\nrole?')
    s.box(760, 75, 300, 60, 'Session allowed', 'ticket stored with the session and audit', accent='#2E7D4F')
    s.box(760, 260, 300, 60, 'Emergency path', 'reason + dual-control approval in PVWA; 4 hours', accent='#B26B00')
    s.box(760, 345, 300, 60, 'DSOC alert; review next business day', 'retrospective ticket within 1 day', accent='#B26B00')
    s.box(380, 380, 120, 40, 'Denied', None, accent=RED)
    s.edge([(210, 205), (245, 205)])
    s.edge([(330, 160), (330, 105), (460, 105)], 'Yes', (330, 130))
    s.edge([(330, 250), (330, 320), (465, 320)], 'No', (330, 285))
    s.edge([(660, 105), (760, 105)], 'Yes', (705, 92))
    s.edge([(560, 160), (560, 275)], 'No', (585, 215))
    s.edge([(655, 320), (705, 320), (705, 290), (760, 290)], 'Yes', (705, 305))
    s.edge([(910, 320), (910, 345)])
    s.edge([(560, 365), (560, 400), (500, 400)], 'No', (540, 412))
    s.save('fig07-ticket-decision.svg')


def fig_breakglass():
    s = SVG(1180, 220, 'Break-glass check-out and check-in')
    steps = [('Request', 'account + ticket'), ('Dual-control', 'approval'), ('Exclusive', 'check-out'),
             ('Use', 'via PSM, or Retrieve'), ('Check-in', 'or auto at timeout'), ('CPM rotates', 'password'),
             ('Review', 'next business day')]
    for i, (a, b) in enumerate(steps):
        x = 20 + i * 165
        s.box(x, 70, 145, 60, a, b, accent='#9B2C2C' if i in (1, 2) else '#1F5FA8')
        if i:
            s.edge([(x - 20, 100), (x, 100)])
    s.box(185, 160, 145, 40, 'Rejected: denied', None, accent=RED)
    s.edge([(257, 130), (257, 160)], 'reject', (285, 145))
    s.box(350, 10, 145, 40, 'DSOC alert', None, accent='#B26B00')
    s.edge([(422, 70), (422, 50)])
    s.text(20, 30, 'Applies to every break-glass account (DEC-10).', 11, 'normal', MUTED)
    s.save('fig08-break-glass.svg')


def fig_nonprod():
    s = SVG(1180, 470, 'Non-production placement')
    s.zone(20, 50, 200, 140, 'Z1  User zone', 'user')
    s.box(35, 90, 170, 80, 'Testers', 'CyberArk, test team,\nnominated users', icon='user', accent='#5B6B7F')
    s.zone(260, 30, 620, 420, 'Non-production zone (PROTECTED, primary site)', 'np', 'test data only')
    s.box(280, 70, 270, 56, 'F5 LTM (NP partition)', 'psm-np, psmp-np', icon='lb', accent='#0F7C8C')
    s.box(590, 70, 270, 56, 'PVWA', 'existing NP', kind='existing', icon='server')
    s.box(280, 160, 130, 56, 'PSM x2', 'new', icon='server')
    s.box(420, 160, 130, 56, 'PSMP x2', 'new', icon='server')
    s.box(590, 160, 130, 56, 'PTA', 'new', icon='shield', accent='#6B4FA0')
    s.box(730, 160, 130, 56, 'Admin VM', 'new', icon='server', accent='#4A2E7A')
    s.box(280, 260, 270, 56, 'Vault', 'existing NP (14.6)', kind='existing', icon='db', accent='#9B2C2C')
    s.box(590, 260, 270, 56, 'CPM', 'existing NP', kind='existing', icon='gear', accent='#6B4FA0')
    s.box(280, 360, 580, 60, 'Test targets', 'Windows, Linux, network image, SQL Server, PostgreSQL, web consoles', icon='server', accent='#2E7D4F')
    s.zone(920, 50, 240, 300, 'Z8  Enterprise (PROTECTED)', 'ent')
    s.box(935, 90, 210, 56, 'ServiceNow', 'non-production instance', kind='existing', icon='doc', accent='#6E6E6E')
    s.box(935, 165, 210, 56, 'Cribl, Splunk', 'test index', kind='existing', icon='shield', accent='#6E6E6E')
    s.box(935, 240, 210, 56, 'AD, DNS, NTP', None, kind='existing', icon='server', accent='#6E6E6E')
    s.edge([(205, 100), (280, 100)], 'NP2', (242, 100))
    s.edge([(205, 140), (570, 140), (570, 98), (590, 98)], 'NP1', (420, 140))
    s.edge([(345, 126), (345, 160)])
    s.edge([(485, 126), (485, 160)])
    s.edge([(415, 216), (415, 260)], 'NP8 1858', (450, 240))
    s.edge([(345, 216), (345, 240), (268, 240), (268, 390), (280, 390)], 'NP12', (268, 330))
    s.edge([(860, 98), (935, 118)], 'NP6', (898, 98))
    s.edge([(860, 288), (900, 288), (900, 193), (935, 193)], 'NP13', (900, 240))
    s.text(20, 230, 'No flow to or from', 11, 'bold', RED)
    s.text(20, 248, 'production PAM zones', 11, 'bold', RED)
    s.text(20, 266, '(Z3–Z6, Z9).', 11, 'bold', RED)
    s.legend(920, 370, [('new', 'New component'), ('existing', 'Existing component'), ('flow', 'Flow (NPn = flow table)')])
    s.save('fig09-non-production.svg')


def fig_schedule():
    import datetime as dt
    s = SVG(1240, 560, 'Delivery schedule')
    x0, x1 = 300, 1210
    start, end = dt.date(2027, 1, 1), dt.date(2028, 5, 1)
    span = (end - start).days

    def X(d):
        return x0 + (d - start).days / span * (x1 - x0)
    # month grid
    d = start
    while d < end:
        nx = dt.date(d.year + (d.month // 12), d.month % 12 + 1, 1)
        s.add(f'<rect x="{X(d):.1f}" y="60" width="{X(nx) - X(d):.1f}" height="440" fill="{"#F7F9FB" if d.month % 2 else "#FFFFFF"}"/>')
        s.text((X(d) + X(nx)) / 2, 48, d.strftime('%b'), 10.5, 'normal', MUTED, 'middle')
        if d.month == 1:
            s.text(X(d) + 2, 28, str(d.year), 11, 'bold', INK)
        d = nx
    rows = [
        ('0  Discovery and HLD', '2027-01-04', '2027-02-05', '#5B6B7F'),
        ('1  Foundations, non-production, LLD', '2027-02-08', '2027-04-02', '#0F7C8C'),
        ('2  Pilot build, SIT, accreditation (PROTECTED)', '2027-03-08', '2027-05-07', '#1F5FA8'),
        ('3  SECRET and OFFICIAL build, SIT, accreditation', '2027-04-05', '2027-07-09', '#1F5FA8'),
        ('4  Onboarding waves', '2027-05-10', '2027-08-27', '#2E7D4F'),
        ('5  Enforcement per wave', '2027-06-28', '2027-10-01', '#9B2C2C'),
        ('6  Service transition and hypercare', '2027-05-10', '2027-10-29', '#6B4FA0'),
        ('   Deferred connectors', '2027-07-19', '2027-09-17', '#9AA6B2'),
    ]
    p = lambda t: dt.date.fromisoformat(t)
    for i, (label, a, b, col) in enumerate(rows):
        y = 80 + i * 38
        s.text(20, y + 11, label, 11.5, '600' if not label.startswith('   ') else 'normal', INK)
        s.add(f'<rect x="{X(p(a)):.1f}" y="{y}" width="{X(p(b)) - X(p(a)):.1f}" height="22" rx="3" fill="{col}"/>')
    ms = [('G0', '2027-01-04'), ('G1', '2027-02-05'), ('G2', '2027-03-05'), ('G3 S/O', '2027-04-02'),
          ('G4 PROT', '2027-05-07'), ('G5 pilot', '2027-05-10'), ('G4 S/O', '2027-07-09'),
          ('Last G6', '2027-10-01'), ('G7', '2027-10-29')]
    y = 400
    s.text(20, y + 8, 'Gates (accelerated plan)', 11.5, '600')
    for i, (lab, d0) in enumerate(ms):
        x = X(p(d0))
        s.add(f'<path d="M{x:.1f},{y - 8} l8,8 l-8,8 l-8,-8 z" fill="#1D2733"/>')
        s.text(x, y + (22 if i % 2 == 0 else -18), lab, 10, '600', INK, 'middle')
    y = 455
    s.text(20, y + 11, 'Standard plan, for comparison', 11.5, '600', MUTED)
    s.add(f'<rect x="{X(p("2027-01-04")):.1f}" y="{y}" width="{X(p("2028-04-07")) - X(p("2027-01-04")):.1f}" height="22" rx="3" fill="#C9D1DB"/>')
    s.text(X(p('2027-01-04')) + 8, y + 11, 'about 15 months to operational acceptance (G7, April 2028)', 10.5, 'normal', INK)
    s.text(20, 530, 'Dates are illustrative; the steering group fixes the start date at G0. Each G4 follows the end of SIT by the 4-week accreditation lead time.', 10.5, 'normal', MUTED)
    s.save('fig10-delivery-schedule.svg')


if __name__ == '__main__':
    for f in (fig_overview, fig_classification, fig_zones, fig_sites, fig_rdp, fig_ssh,
              fig_ticket, fig_breakglass, fig_nonprod, fig_schedule):
        f()
    print('written to', os.path.normpath(OUT))
