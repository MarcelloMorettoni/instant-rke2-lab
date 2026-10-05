#!/usr/bin/env python3
"""Generate the SVG diagrams in diagrams/ (same visual style as ../soft-tenancy/confluence).

    python3 diagrams/src/make_diagrams.py            # writes diagrams/*.svg
    diagrams/src/to-png.sh                           # optional: PNGs for Confluence/Word

Edit the diagram functions below, never the SVGs.
"""

from __future__ import annotations

from html import escape
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent
SANS = "'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "Consolas, 'SFMono-Regular', 'Liberation Mono', Menlo, monospace"

INK, BODY, MUTED, LINE = "#0F172A", "#475569", "#64748B", "#E2E8F0"
PAL = {  # fill, stroke, title
    "teal": ("#F0FDFA", "#5EEAD4", "#115E59"),     # collection
    "indigo": ("#EEF2FF", "#A5B4FC", "#3730A3"),   # Loki
    "amber": ("#FFFBEB", "#FCD34D", "#92400E"),    # Azure storage / data
    "slate": ("#F8FAFC", "#CBD5E1", "#334155"),    # tenants, people, neutral
    "violet": ("#F5F3FF", "#C4B5FD", "#5B21B6"),   # Grafana
    "sky": ("#F0F9FF", "#7DD3FC", "#075985"),      # gateway
    "rose": ("#FFF1F2", "#FDA4AF", "#9F1239"),     # blocked / attacks
    "green": ("#F0FDF4", "#86EFAC", "#166534"),    # identity / security services
    "orange": ("#FFF7ED", "#FDBA74", "#9A3412"),   # Kafka (the buffer between the tiers)
}
WRITE, READ, BLOCK, NEUTRAL = "#16A34A", "#4338CA", "#DC2626", "#94A3B8"


class Svg:
    def __init__(self, w: int, h: int, title: str, subtitle: str):
        self.w, self.h, self.parts = w, h, []
        self.markers: set[str] = set()
        self.add(f'<rect x="0.5" y="0.5" width="{w-1}" height="{h-1}" rx="14" fill="#FFFFFF" stroke="{LINE}"/>')
        self.text(32, 44, title, 21, INK, weight=700)
        self.text(32, 68, subtitle, 13.5, MUTED)
        self.title = title

    def add(self, s: str) -> None:
        self.parts.append(s)

    def text(self, x, y, s, size=12, fill=BODY, weight=400, anchor="start", mono=False, spacing=0):
        fam = MONO if mono else SANS
        ls = f' letter-spacing="{spacing}"' if spacing else ""
        self.add(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" font-weight="{weight}" '
                 f'fill="{fill}" text-anchor="{anchor}"{ls}>{escape(s)}</text>')

    def lane(self, x, y, s, anchor="start"):
        self.text(x, y, s.upper(), 11, MUTED, 700, anchor, spacing=1)

    def frame(self, x, y, w, h, label, dashed=True):
        dash = ' stroke-dasharray="6 5"' if dashed else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="none" stroke="#CBD5E1" stroke-width="1.5"{dash}/>')
        self.text(x + 14, y + 20, label, 11.5, MUTED, 700)

    def box(self, x, y, w, h, title, lines=(), pal="slate", tag=None, title_size=13.5):
        fill, stroke, tcol = PAL[pal]
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        self.text(x + 14, y + 24, title, title_size, tcol, 700)
        ty = y + 44
        for ln in lines:
            mono = ln.startswith("`")
            self.text(x + 14, ty, ln.strip("`"), 11 if mono else 11.5, BODY, mono=mono)
            ty += 17
        if tag:
            self.pill(x + 14, y + h - 32, w - 28, tag, stroke)

    def pill(self, x, y, w, s, stroke="#CBD5E1", color=INK):
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="22" rx="11" fill="#FFFFFF" stroke="{stroke}" stroke-width="1"/>')
        self.text(x + w / 2, y + 15, s, 10, color, 600, "middle", mono=True)

    def mini(self, x, y, w, h, s, pal="indigo", sub=None):
        fill, stroke, tcol = PAL[pal]
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="#FFFFFF" stroke="{stroke}" stroke-width="1.2"/>')
        self.text(x + w / 2, y + (h / 2 + 4 if not sub else h / 2 - 2), s, 11, tcol, 700, "middle")
        if sub:
            self.text(x + w / 2, y + h / 2 + 12, sub, 9.5, MUTED, 400, "middle", mono=True)

    def _marker(self, color):
        mid = "ah" + color.strip("#")
        self.markers.add(color)
        return mid

    def arrow(self, pts, color=WRITE, label=None, dashed=False, lx=None, ly=None, both=False, width=2):
        mid = self._marker(color)
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        dash = ' stroke-dasharray="6 5"' if dashed else ""
        start = f' marker-start="url(#{mid})"' if both else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{dash}{start} marker-end="url(#{mid})"/>')
        if label:
            (x1, y1), (x2, y2) = pts[0], pts[-1]
            lx = lx if lx is not None else (x1 + x2) / 2
            ly = ly if ly is not None else (y1 + y2) / 2 - 8
            self.text(lx, ly, label, 10.5, color, 600, "middle")

    def cross(self, x, y, color=BLOCK):
        self.add(f'<circle cx="{x}" cy="{y}" r="10" fill="#FFFFFF" stroke="{color}" stroke-width="2"/>')
        self.add(f'<path d="M{x-4},{y-4} L{x+4},{y+4} M{x+4},{y-4} L{x-4},{y+4}" stroke="{color}" stroke-width="2.2"/>')

    def check(self, x, y, color=WRITE):
        self.add(f'<circle cx="{x}" cy="{y}" r="10" fill="#FFFFFF" stroke="{color}" stroke-width="2"/>')
        self.add(f'<path d="M{x-5},{y} L{x-1},{y+4} L{x+5},{y-4}" fill="none" stroke="{color}" stroke-width="2.2"/>')

    def render(self) -> str:
        defs = "".join(
            f'<marker id="ah{c.strip("#")}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
            for c in sorted(self.markers))
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" role="img" aria-labelledby="t">\n'
                f'<title id="t">{escape(self.title)}</title>\n<defs>{defs}</defs>\n'
                + "\n".join(self.parts) + "\n</svg>\n")


# --------------------------------------------------------------------------- 1
def overview() -> Svg:
    s = Svg(1400, 780, "Multi-tenant Loki on AKS with OpenTelemetry: the whole picture",
            "Tenants never pick their tenant: OpenTelemetry collectors decide it, the read gateway decides who sees it")
    s.frame(24, 88, 1106, 506, "AKS cluster (private, 3 availability zones)")
    s.lane(44, 130, "Write path: OpenTelemetry, with Kafka between the collector tiers")
    s.box(44, 142, 150, 170, "Tenant namespaces", ["stdout / stderr", "or an OTel SDK", "(OTLP to the", "node's agent)"],
          "slate", "ns → tenant")
    s.box(214, 142, 166, 170, "OTel agent", ["DaemonSet, 1/node", "files + OTLP in", "tenant from ns", "masks PAN/IBAN"],
          "teal", "queue on node")
    s.box(400, 142, 150, 170, "Kafka", ["Strimzi, 3 zones", "topic otel-logs", "RF 3, acks=all", "24 h retention"],
          "orange", "ns kafka")
    s.box(570, 142, 166, 170, "OTel gateway", ["StatefulSet, 3 pods", "consumer group", "routes by tenant", "queue per tenant"],
          "teal", "zonal SSD")
    s.box(756, 142, 120, 170, "Distributors", ["per-tenant", "limits", "HPA 3 → 9"], "indigo", "/otlp")
    s.box(896, 142, 214, 170, "Ingesters: 3 zones", ["RF 3, WAL on zonal disk"], "indigo")
    for i, z in enumerate("abc"):
        s.mini(906 + i * 67, 218, 61, 56, f"zone {z}", "indigo", "2 pods")
    s.arrow([(194, 227), (214, 227)], WRITE)
    s.arrow([(380, 227), (400, 227)], WRITE)
    s.arrow([(550, 227), (570, 227)], WRITE)
    s.arrow([(736, 227), (756, 227)], WRITE)
    s.arrow([(876, 227), (896, 227)], WRITE)

    s.lane(44, 360, "Read path")
    s.box(44, 372, 176, 160, "Bank users", ["SSO: Entra ID (default),", "Keycloak or OIDC;", "groups per tenant;", "local admin (change-me-now)"], "slate", "auth.provider")
    s.box(250, 372, 196, 160, "Grafana (2 replicas)", ["one org per tenant", "group → org + role", "Viewer / Editor only"],
          "violet", "/payments/ + key")
    s.box(476, 372, 196, 160, "obs-gateway", ["kgateway (Envoy)", "one view per org", "SETS X-Scope-OrgID"], "sky",
          "read-only")
    s.box(702, 372, 408, 160, "Query path + caches", ["frontend → scheduler → queriers → index gateways"], "indigo")
    for i, (n, sub) in enumerate([("results", "memcached"), ("queriers", "4 → 16"), ("chunks", "memcached"), ("index gw", "disk")]):
        s.mini(716 + i * 98, 452, 90, 56, n, "indigo", sub)
    s.arrow([(220, 452), (250, 452)], READ)
    s.arrow([(446, 452), (476, 452)], READ)
    s.arrow([(672, 452), (702, 452)], READ)
    s.arrow([(996, 372), (996, 312)], READ, "recent", dashed=True, lx=1030, ly=346)

    s.box(1160, 142, 216, 390, "Azure Blob Storage", ["chunks + TSDB index", "", "GZRS: 3 zones +", "paired region",
          "", "private endpoint only", "no shared keys", "Workload Identity", "CMK (Key Vault, HSM)", "",
          "Cool 30 d, Cold 180 d,", "never Archive", "", "retention per tenant"], "amber", "<tenant>/ prefix")
    s.arrow([(1110, 227), (1160, 227)], WRITE, "flush", ly=218)
    s.arrow([(1110, 452), (1160, 452)], READ, "read", ly=443)
    s.add(f'<rect x="44" y="546" width="628" height="34" rx="8" fill="{PAL["rose"][0]}" stroke="{PAL["rose"][1]}"/>')
    s.cross(64, 563)
    s.text(84, 567, "Tenant pods reach only their node's OTel agent: never the gateway, Loki or Grafana's backends",
           11.5, PAL["rose"][2], 600)

    s.frame(24, 614, 1352, 144, "Azure platform services (Terraform: infra/terraform)")
    for i, (t, ls, pal) in enumerate([
        ("Entra ID", ["Grafana SSO (default; or Keycloak/OIDC)", "Workload Identity (Loki, ESO)"], "green"),
        ("Key Vault (premium, HSM)", ["CMKs: Blob + disks", "read-gateway keys → ESO"], "green"),
        ("PostgreSQL flexible", ["Grafana state", "zone-redundant HA"], "amber"),
        ("Azure Monitor", ["managed Prometheus: Loki,", "collectors, gateway; alerts"], "slate"),
        ("Log Analytics / SIEM", ["storage, Key Vault, database", "audit logs"], "slate"),
    ]):
        s.box(44 + i * 266, 640, 246, 96, t, ls, pal)
    return s


# --------------------------------------------------------------------------- 2
def write_path() -> Svg:
    s = Svg(1400, 720, "Write path: from a container (or an OTel SDK) to Blob storage",
            "OpenTelemetry end to end, Kafka between the collector tiers. The platform decides the tenant once; every hop has a durable buffer.")
    s.frame(24, 92, 330, 604, "AKS node (any pool)")
    s.box(44, 124, 290, 104, "Tenant pods", ["stdout → kubelet → log file", "OTel SDK → OTLP → otel-agent", "(same node: internalTrafficPolicy)"],
          "slate")
    s.box(44, 244, 290, 70, "/var/log/pods (node disk)", ["kubelet-rotated files"], "amber")
    s.arrow([(189, 228), (189, 244)], WRITE)
    s.box(44, 330, 290, 346, "OTel agent (DaemonSet pod)", [], "teal")
    steps = [
        ("1", "file_log: read files (checkpointed)"),
        ("2", "otlp: accept pushes from this node"),
        ("3", "OTLP: drop claimed k8s.* / tenant"),
        ("4", "k8s_attributes: pod from file path,"),
        ("", "or from the connection's source IP"),
        ("5", "namespace → tenant (generated)"),
        ("6", "mask PAN / IBAN / bearer tokens"),
        ("7", "queue on node disk (2 GiB) → Kafka"),
    ]
    y = 368
    for n, t in steps:
        if n:
            s.add(f'<circle cx="68" cy="{y}" r="10" fill="#FFFFFF" stroke="{PAL["teal"][1]}" stroke-width="1.5"/>')
            s.text(68, y + 4, n, 10.5, PAL["teal"][2], 700, "middle")
        s.text(86, y + 4, t, 11.5, BODY)
        y += 36 if n else 30
    s.arrow([(189, 314), (189, 330)], WRITE)

    s.box(390, 124, 230, 176, "Kafka (Strimzi)", ["topic otel-logs, 24 partitions", "3 brokers, one per zone",
          "RF 3, acks=all (2 of 3)", "24 h retention: replay", "TLS + SCRAM, ACLs:", "agents write, gateways read"], "orange")
    s.box(390, 326, 230, 196, "OTel gateway", ["StatefulSet, 3 pods (zones)", "consumer group otel-gateway",
          "one Loki exporter + one", "persistent queue PER TENANT", "offset committed once queued",
          "queue full: the partition waits"], "teal", "X-Scope-OrgID: <tenant>")
    s.arrow([(334, 600), (362, 600), (362, 212), (390, 212)], WRITE)
    s.text(372, 552, "Kafka TLS :9093", 11, WRITE, 700)
    s.text(372, 568, "zstd, acks=all", 10.5, MUTED)
    s.arrow([(505, 300), (505, 326)], WRITE)

    s.box(656, 124, 200, 330, "Distributor", ["OTLP → Loki streams", "", "`otlp_config:`", "4 attrs → labels,", "rest → structured", "metadata", "",
          "per-tenant limits"], "indigo", "over limit → 429")
    s.arrow([(620, 410), (656, 410)], WRITE)
    s.text(638, 398, "HTTP", 10.5, WRITE, 600, "middle")

    s.frame(890, 92, 486, 330, "Ingesters: zone-aware, replication factor 3")
    for i, z in enumerate(["1", "2", "3"]):
        x = 904 + i * 158
        s.box(x, 124, 146, 170, f"zone {z}", ["ingester-zone-" + "abc"[i], "×2", "WAL → zonal", "disk (CMK)"], "indigo",
              "obs-zonal-ssd")
    s.arrow([(856, 250), (904, 250)], WRITE, "×3", ly=240)
    s.text(904, 322, "A push succeeds when 2 of 3 zones have it (quorum).", 11.5, BODY)
    s.text(904, 340, "A whole zone can fail or be upgraded: no write fails.", 11.5, BODY)
    s.text(904, 358, "Crash → WAL replay; shutdown → flush (≤ 10 min).", 11.5, BODY)
    s.text(904, 376, "Upgrades: rollout-operator, one zone at a time.", 11.5, BODY)

    s.box(656, 470, 720, 206, "Azure Blob Storage (GZRS, private endpoint)", [
        "`loki-chunks/<tenant>/...                compressed chunks, ~1.5 MB each`",
        "`loki-chunks/index/loki_index_<day>/     TSDB index, one table per day`",
        "",
        "flush when a chunk is full (1.5 MB), idle 30 min, or 2 h old",
        "compactor: merges the index, applies per-tenant retention, runs deletes",
        "the 3 replicas flush identical chunks: same key, stored once"], "amber")
    s.arrow([(1300, 294), (1300, 470)], WRITE, "flush", lx=1330, ly=392)
    return s


# --------------------------------------------------------------------------- 3
def read_path() -> Svg:
    s = Svg(1240, 720, "Read path: who can see which tenant",
            "Identity comes from the provider's groups (auth.provider); the tenant from the gateway view. Nothing a user sends changes it.")
    s.lane(32, 110, "Identity provider groups")
    s.lane(292, 110, "Grafana org")
    s.lane(552, 110, "obs-gateway view")
    s.lane(862, 110, "Loki")
    rows = [
        ("payments groups", "payments", "/payments/", "payments", "sg-obs-payments-*", "obs-payments-*", "mock: alice"),
        ("cards groups", "cards", "/cards/", "cards|shared-services", "sg-obs-cards-*", "obs-cards-*", "mock: bob"),
        ("platform groups", "platform", "/platform/", "platform|unassigned|all tenants", "sg-obs-platform-*", "obs-platform-*", "+ local admin"),
    ]
    for i, (g, org, view, hdr, entra, oidc, local) in enumerate(rows):
        y = 126 + i * 118
        s.box(32, y, 220, 104, g, [f"Entra: {entra}", f"Keycloak/OIDC: {oidc}", f"viewer · editor · {local}"], "green", title_size=12.5)
        s.box(292, y, 220, 104, f'org "{org}"', ["1 Loki data source:", f"`gateway{view}`", "+ its own key (encrypted)"], "violet")
        s.box(552, y, 270, 104, f"view-{org}", ["key must be obs-key-" + org, "push / delete → 403"], "sky")
        s.pill(566, y + 72, 242, f"X-Scope-OrgID: {hdr}"[:38], PAL["sky"][1])
        s.arrow([(252, y + 48), (292, y + 48)], READ)
        s.arrow([(512, y + 48), (552, y + 48)], READ)
        s.arrow([(822, y + 48), (862, y + 48)], READ)
    s.box(862, 126, 352, 340, "query-frontend → queriers", ["reads only the tenants in the header", "",
          "`payments → payments' data`", "`cards|shared-services → both`",
          "`platform|... → everything (SRE)`", "", "per-tenant query limits:", "`max_query_parallelism`",
          "`max_queriers_per_tenant`", "`query_timeout, max_query_length`", "", "NetworkPolicy: only the gateway",
          "may reach the query-frontend"], "indigo")

    s.lane(32, 510, "What the design blocks")
    attacks = [
        ("Forged X-Scope-OrgID from a user", "the view SETS the header: replaced"),
        ("payments' key on /cards/", "401: each view opens only with its key"),
        ("Org Admin adds a data source", "users are never Admin; without a key: 401"),
        ("Tenant pod calls Loki or the gateway", "NetworkPolicy: connection dropped"),
        ("User in no mapped group", "denied at login (allowed_groups)"),
        ("Push or delete via the gateway", "403 on every view"),
    ]
    for i, (a, r) in enumerate(attacks):
        x = 32 + (i % 3) * 400
        y = 524 + (i // 3) * 88
        s.add(f'<rect x="{x}" y="{y}" width="382" height="74" rx="10" fill="{PAL["rose"][0]}" stroke="{PAL["rose"][1]}" stroke-width="1.5"/>')
        s.cross(x + 24, y + 26)
        s.text(x + 44, y + 30, a, 12, PAL["rose"][2], 700)
        s.text(x + 44, y + 52, r, 11.5, BODY)
    return s


# --------------------------------------------------------------------------- 4
def zones() -> Svg:
    s = Svg(1240, 760, "Zone layout and what survives a failure",
            "One Loki node pool per availability zone. Losing a zone costs capacity, not data or availability.")
    comps = [
        ("ingester-zone-{z} ×2", "WAL on zonal disk"),
        ("distributor", "HPA across zones"),
        ("querier ×1-2+", "HPA 4 → 16"),
        ("index-gateway", "1 per zone"),
        ("chunks-cache", "memcached"),
        ("obs-gateway", "kgateway, PDB 2"),
        ("frontend / scheduler", "2 each, spread"),
        ("grafana", "2 replicas"),
    ]
    for i, z in enumerate(["1", "2", "3"]):
        x = 32 + i * 402
        s.frame(x, 92, 386, 452, f"Availability zone {z}  ·  node pool loki{z}", dashed=False)
        s.text(x + 14, 134, "Standard_D16ds_v5 · AzureLinux · 2-5 nodes · taint obs.platform/dedicated", 10.5, MUTED)
        for j, (n, sub) in enumerate(comps):
            if j >= 6 and i == 2:          # 2 replicas: zones 1 and 2
                continue
            cx = x + 14 + (j % 2) * 182
            cy = 150 + (j // 2) * 92
            pal = "sky" if n.startswith("obs") else "violet" if n == "grafana" else "indigo"
            s.box(cx, cy, 172, 78, n.replace("{z}", "abc"[i]), [sub], pal, title_size=12)
        s.pill(x + 14, 516, 358, "Premium SSD (CMK) · ephemeral OS disk", PAL["amber"][1])

    s.box(32, 562, 1190, 72, "Azure Blob Storage (GZRS): one account, synchronously in all 3 zones, async copy to the paired region",
          ["Chunks and index are safe from any single zone failure. Loki reads and writes through one private endpoint."], "amber",
          title_size=12.5)
    s.box(32, 648, 580, 92, "Zone lost: what happens", ["writes: 2 of 3 replicas still ack (quorum) → no push fails",
          "reads: ingesters of 2 zones + Blob → complete results", "then: autoscaler adds nodes in the surviving zones"], "green")
    s.box(642, 648, 580, 92, "PostgreSQL (Grafana)", ["primary zone 1, synchronous standby zone 2",
          "automatic failover ~60-120 s; Grafana reconnects", "Loki keeps ingesting: Grafana is only the read UI"], "amber")
    return s


# --------------------------------------------------------------------------- 5
def dr() -> Svg:
    s = Svg(1240, 640, "Disaster recovery: region loss",
            "The log store is geo-replicated; compute is rebuilt from code. Pick the tier the bank's RPO needs.")
    s.frame(32, 92, 560, 330, "Primary region (e.g. West Europe)", dashed=False)
    s.box(52, 130, 250, 130, "AKS + Loki", ["ingesters hold the last ≤ 2 h", "of logs (not yet in Blob)"], "indigo")
    s.box(322, 130, 250, 130, "Blob Storage GZRS", ["everything older than ~2 h", "3 zones, synchronous"], "amber")
    s.box(322, 276, 250, 126, "PostgreSQL HA", ["Grafana dashboards, orgs,", "alert rules"], "amber")
    s.box(52, 276, 250, 126, "Key Vault", ["CMKs + secrets", "(Azure replicates to the", "paired region, read-only)"], "green")
    s.frame(648, 92, 560, 330, "Paired region (e.g. North Europe)", dashed=True)
    s.box(938, 130, 250, 130, "AKS + Loki (standby)", ["Terraform + install.sh", "same tenants.yaml", "RTO: hours (tier A)"], "slate")
    s.box(668, 130, 250, 130, "Blob secondary", ["async copy (typically", "< 15 min behind, no SLA)", "after account failover:", "read-write"], "amber")
    s.box(668, 276, 250, 126, "PostgreSQL geo-restore", ["from geo-redundant backup", "RPO ≤ 1 h"], "amber")
    s.box(938, 276, 250, 126, "Tier B: second Loki", ["OTel gateway exports to", "BOTH regions (2 exporters)", "RPO ≈ 0, 2× cost"], "green")
    s.arrow([(572, 195), (668, 195)], WRITE, "async", ly=186, dashed=True)
    s.arrow([(572, 340), (668, 340)], WRITE, "backup", ly=331, dashed=True)

    rows = [("", "Tier A: rebuild (default)", "Tier B: dual-write"),
            ("RPO (logs)", "unflushed ≤ 2 h + Blob lag", "≈ 0"),
            ("RTO", "2-4 h: infra + deploy + DNS", "minutes: switch Grafana"),
            ("Cost", "storage replication only", "2× compute + storage"),
            ("Use when", "logs are operational", "logs are records (audit)")]
    for r, (a, b, c) in enumerate(rows):
        y = 456 + r * 34
        weight = 700 if r == 0 else 400
        s.add(f'<rect x="32" y="{y}" width="1176" height="34" fill="{"#F1F5F9" if r == 0 else "#FFFFFF"}" stroke="{LINE}"/>')
        s.text(48, y + 22, a, 12, INK, 700)
        s.text(300, y + 22, b, 12, BODY, weight)
        s.text(760, y + 22, c, 12, BODY, weight)
    return s


# --------------------------------------------------------------------------- 6
def durability() -> Svg:
    s = Svg(1400, 660, "Durability: a buffer at every hop, Kafka the replicated one",
            "Where logs wait when the next hop is down, for how long, and what each buffer survives")
    hops = [
        ("Container", "slate", ["writes stdout", "", "kubelet log files", "on the node", "", "buffer: rotation", "(50 MiB × 5 / ctr)"]),
        ("OTel agent", "teal", ["file checkpoints", "on node disk", "", "persistent queue", "2 GiB per node", "", "retries forever"]),
        ("Kafka", "orange", ["topic otel-logs", "3 brokers, 3 zones", "RF 3, acks=all", "", "24 h retention", "(kafka.topic", ".retentionHours)"]),
        ("OTel gateway", "teal", ["persistent queue", "PER TENANT", "zonal SSD (CMK)", "", "offset committed", "once queued", "retried up to 6 h"]),
        ("Loki ingesters", "indigo", ["WAL on zonal SSD", "", "RF 3 across", "3 zones", "", "acks after 2 of 3", "(quorum)"]),
        ("Object storage", "amber", ["Blob GZRS: 3 zones", "+ paired region", "", "or any S3 API", "(generic)", "", ""]),
    ]
    for i, (t, pal, ls) in enumerate(hops):
        x = 32 + i * 226
        s.box(x, 100, 200, 210, t, ls, pal)
        if i:
            s.arrow([(x - 26, 205), (x, 205)], WRITE)
    survives = [None, ("agent restart,", "Kafka outage"), ("node, broker or zone", "loss; 24 h of gateway", "or Loki outage"),
                ("pod restart, one", "tenant at 429"), ("pod crash,", "a whole zone"), ("zone loss;", "region (Blob, async)")]
    for i, lines in enumerate(survives):
        if not lines:
            continue
        for j, ln in enumerate(lines):
            s.text(32 + i * 226 + 100, 338 + j * 16, ("survives: " if j == 0 else "") + ln, 11, BODY, 400, "middle")

    s.lane(32, 418, "What Kafka adds, and what it costs")
    rows = [("", "With Kafka (kafka.enabled, default)", "Without (overlays/no-kafka.yaml)"),
            ("Node lost during an outage", "the backlog is in Kafka (replicated): only seconds lost", "the backlog in that node's agent queue is lost"),
            ("Loki down for hours", "24 h in Kafka for ALL tenants, replayed in order", "~1 h in the gateway queues, then node queues"),
            ("Other consumers (SIEM, lake)", "can read the same topic (new consumer group + ACL)", "need a second export"),
            ("Operations", "a 3rd stateful system: brokers, KRaft, upgrades, capacity", "two collector tiers only"),
            ("Tenant isolation", "per-tenant gateway queues; a full one pauses its partition", "per-tenant gateway queues")]
    for r, (a, b, c) in enumerate(rows):
        y = 432 + r * 30
        s.add(f'<rect x="32" y="{y}" width="1336" height="30" fill="{"#F1F5F9" if r == 0 else "#FFFFFF"}" stroke="{LINE}"/>')
        s.text(44, y + 19, a, 11.5, INK, 700)
        s.text(300, y + 19, b, 11.5, BODY, 700 if r == 0 else 400)
        s.text(860, y + 19, c, 11.5, BODY, 700 if r == 0 else 400)
    s.text(32, 640, "Decision and alternatives: docs/adr/0010-kafka-in-cluster.md (supersedes 0006).", 11.5, MUTED)
    return s


# --------------------------------------------------------------------------- 7
def caching() -> Svg:
    s = Svg(1400, 600, "Caching: on the read path only, and never the source of truth",
            "Three caches make repeated and dashboard queries cheap. Losing any of them costs speed, never data.")
    s.box(32, 110, 200, 150, "Grafana", ["dashboard refresh,", "Explore query"], "violet")
    s.box(272, 110, 220, 150, "Query frontend", ["splits by 1 h, shards", "", "asks the RESULTS cache", "first"], "indigo")
    s.box(532, 110, 200, 150, "Queriers", ["run what the", "results cache", "didn't have"], "indigo")
    s.box(772, 110, 250, 150, "Index gateways ×3", ["TSDB index on local", "disk (50 Gi each)", "", "queriers don't each", "download the index"], "indigo")
    s.box(1062, 110, 306, 150, "Azure Blob Storage", ["the source of truth", "", "every chunk and index file", "", "per-GB read cost in Cool/Cold"], "amber")
    s.arrow([(232, 185), (272, 185)], READ)
    s.arrow([(492, 185), (532, 185)], READ)
    s.arrow([(732, 185), (772, 185)], READ)
    s.arrow([(1022, 185), (1062, 185)], READ)

    s.box(272, 300, 220, 128, "Results cache", ["memcached ×2, 2 GB each", "per query slice, 12 h", "", "hits: dashboards, re-runs"], "sky")
    s.box(532, 300, 490, 128, "Chunks cache", ["memcached ×3 (one per zone), 8 GB each = 24 GB",
          "compressed chunks, as fetched from Blob", "", "hits: the last hours/days, the queries everyone runs"], "sky")
    s.arrow([(382, 260), (382, 300)], READ, both=True)
    s.arrow([(632, 260), (632, 300)], READ, both=True)
    s.arrow([(1022, 364), (1215, 364), (1215, 260)], READ, "on miss", lx=1150, ly=356)

    rows = [("Question", "Answer"),
            ("Why no cache on the write path?", "A write cache is a buffer: the agent/gateway queues and the Loki WAL already are. No second copy to lose."),
            ("Why memcached, not Redis?", "Loki's recommended, tested cache; chart-managed; no persistence needed. Redis adds nothing here."),
            ("What if a cache dies?", "Queries go to Blob: slower and a bit more read cost for a while. No data loss, no errors."),
            ("Is tenant data isolated in cache?", "Keys include the tenant ID; only Loki pods can reach memcached (NetworkPolicy)."),
            ("When to grow it?", "Chunks-cache hit rate < 80 %, or Blob read costs rising: add replicas or memory.")]
    for r, (a, b) in enumerate(rows):
        y = 452 + r * 24
        s.add(f'<rect x="32" y="{y}" width="1336" height="24" fill="{"#F1F5F9" if r == 0 else "#FFFFFF"}" stroke="{LINE}"/>')
        s.text(44, y + 16, a, 11.5, INK, 700)
        s.text(330, y + 16, b, 11.5, BODY, 700 if r == 0 else 400)
    return s


# --------------------------------------------------------------------------- 8
def _core(s: Svg, top: int, users: str) -> None:
    """The Loki backend, drawn the same way in pictures 08 and 09."""
    s.lane(44, top, "Write path")
    y = top + 12
    s.box(44, y, 140, 132, "Tenant pods", ["stdout / stderr", "or an OTel SDK"], "slate", "ns → tenant")
    s.box(204, y, 160, 132, "OTel agent", ["DaemonSet", "tenant from ns", "masks secrets"], "teal", "node queue")
    s.box(384, y, 170, 132, "Kafka (Strimzi)", ["KRaft, 3 zones", "topic otel-logs", "RF 3, 24 h"], "orange", "ns kafka")
    s.box(574, y, 160, 132, "OTel gateway", ["consumer group", "queue per tenant", "sets the tenant"], "teal", "ns otel")
    s.box(754, y, 356, 132, "Loki write", ["distributors: per-tenant limits", "ingesters: 3 zones, RF 3, WAL on PVC"], "indigo",
          "Loki 3.6, distributed")
    for x in (184, 364, 554, 734):
        s.arrow([(x, y + 66), (x + 20, y + 66)], WRITE)
    s.lane(44, top + 176, "Read path")
    y = top + 188
    s.box(44, y, 140, 132, "Bank users", [users[0], users[1]], "slate", "HTTPS")
    s.box(204, y, 160, 132, "Load balancer", ["internal only", "kgateway (Envoy)", "TLS ends here"], "sky", "Grafana + SSO")
    s.box(384, y, 170, 132, "Grafana", ["org per tenant", "group → org, role", "local admin"], "violet", "ns grafana")
    s.box(574, y, 160, 132, "Read gateway", ["view per org", "key per view", "SETS X-Scope-OrgID"], "sky", "read-only")
    s.box(754, y, 356, 132, "Loki read", ["query-frontend → scheduler → queriers", "index gateways; memcached results",
          "and chunks caches"], "indigo", "per-tenant query limits")
    for x in (184, 364, 554, 734):
        s.arrow([(x, y + 66), (x + 20, y + 66)], READ)


def generic() -> Svg:
    s = Svg(1400, 860, "Generic installation: everything runs in the cluster",
            "No Azure service needed. Kafka, Keycloak, PostgreSQL, secrets and monitoring are in-cluster; "
            "log storage is any S3 API (Azure Blob for now).")
    s.frame(24, 88, 1106, 650, "Kubernetes cluster (3 zones recommended)  ·  environments/generic")
    _core(s, 128, ("browser, bank", "network"))
    s.box(1160, 140, 216, 320, "Object storage", ["chunks + TSDB index", "<tenant>/ prefix", "",
          "any S3 API:", "Rook/Ceph RGW,", "on-prem S3", "(overlays/s3-storage.yaml)", "", "today: Azure Blob,", "Workload Identity"],
          "amber", "the source of truth")
    s.arrow([(1110, 206), (1160, 206)], WRITE, "flush", ly=197)
    s.arrow([(1160, 382), (1110, 382)], READ, "read", ly=373)

    s.lane(44, 472, "Platform services, in the cluster")
    y = 512
    s.box(44, y, 200, 160, "Keycloak", ["Keycloak operator", "realm obs: tenant", "groups, grafana client", "Entra broker: optional"],
          "green", "ns keycloak")
    s.box(264, y, 200, 160, "PostgreSQL", ["Percona operator", "(you bring it)", "Grafana + Keycloak", "HA, pgBackRest"],
          "amber", "ns postgres")
    s.box(484, y, 200, 160, "Secrets", ["made by the chart,", "kept on upgrade:", "view keys, Kafka users,", "client secret, TLS"],
          "slate", "no Key Vault")
    s.box(704, y, 200, 160, "Monitoring", ["Prometheus Operator", "PodMonitors", "PrometheusRule", "(the same alerts)"],
          "slate", "ns monitoring")
    s.box(924, y, 186, 160, "Operators", ["kgateway", "Strimzi", "Keycloak operator"], "slate", "platform-operators")
    s.arrow([(444, 448), (444, 486), (144, 486), (144, 512)], READ, dashed=True)
    s.text(380, 481, "sign-in (OIDC)", 10.5, READ, 600, "middle")
    s.arrow([(494, 448), (494, 496), (364, 496), (364, 512)], NEUTRAL, dashed=True)
    s.text(502, 478, "state", 10.5, MUTED, 600, "start")
    s.arrow([(244, 614), (264, 614)], NEUTRAL, dashed=True)

    s.add(f'<rect x="44" y="686" width="1066" height="36" rx="8" fill="{PAL["slate"][0]}" stroke="{PAL["slate"][1]}"/>')
    s.text(577, 709, "keyVault.enabled: false · postgres.provider: percona · keycloak.install: true · "
           "auth.provider: keycloak · monitoring.prometheusOperator.enabled: true", 10.5, BODY, anchor="middle", mono=True)
    s.text(24, 768, "The Loki backend (rows 1-2) is identical to the Azure installation (picture 09): only the services around it change.",
           12.5, INK, 600)
    s.text(24, 790, "Manifests per component: manifests/generic/ (scripts/render-manifests.sh).  Install: scripts/install.sh generic.",
           11.5, MUTED)
    s.text(24, 808, "Not in the cluster: the users' browsers, DNS names for Grafana and Keycloak, and (until s3-storage.yaml) the Blob account.",
           11.5, MUTED)
    return s


# --------------------------------------------------------------------------- 9
def azure() -> Svg:
    s = Svg(1400, 950, "Azure installation: the same backend, with Azure services around it",
            "AKS with Blob, Key Vault, Entra ID, PostgreSQL flexible server and managed Prometheus. "
            "Kafka and Loki stay in the cluster.")
    s.frame(24, 88, 1106, 470, "AKS cluster (private API, 3 availability zones, zonal node pools)  ·  environments/azure")
    _core(s, 128, ("SSO through", "Entra ID"))
    s.box(754, 468, 356, 76, "External Secrets Operator", ["Key Vault → Secrets (Workload Identity)"], "green")
    s.box(1160, 140, 216, 320, "Azure Blob (GZRS)", ["chunks + TSDB index", "<tenant>/ prefix", "",
          "3 zones + paired region", "private endpoint only", "no shared keys:", "Workload Identity", "CMK in Key Vault (HSM)", "",
          "Cool 30 d, Cold 180 d"], "amber", "the source of truth")
    s.arrow([(1110, 206), (1160, 206)], WRITE, "flush", ly=197)
    s.arrow([(1160, 382), (1110, 382)], READ, "read", ly=373)

    s.frame(24, 582, 1352, 152, "Azure services (Terraform: infra/terraform)")
    svc = [("Disks + node pools", ["disk encryption set (CMK)", "zonal pools loki1/2/3"], "slate"),
           ("Entra ID", ["Grafana SSO: group → org", "Workload Identity: Loki, ESO"], "green"),
           ("PostgreSQL flexible", ["Grafana state", "zone-redundant HA"], "amber"),
           ("Key Vault (HSM)", ["CMKs: Blob + disks", "secrets for ESO"], "green"),
           ("Managed Prometheus", ["azmonitoring PodMonitors", "rule groups: same alerts"], "slate"),
           ("Log Analytics / SIEM", ["audit: storage,", "Key Vault, database"], "slate")]
    for i, (t, ls, pal) in enumerate(svc):
        s.box(44 + i * 222, 622, 206, 92, t, ls, pal)
    s.arrow([(444, 448), (444, 566), (369, 566), (369, 622)], READ, dashed=True)
    s.text(436, 520, "SSO", 10.5, READ, 600, "end")
    s.arrow([(494, 448), (494, 580), (591, 580), (591, 622)], NEUTRAL, dashed=True)
    s.text(543, 574, "state", 10.5, MUTED, 600, "middle")
    s.arrow([(813, 544), (813, 622)], NEUTRAL, dashed=True)
    s.text(822, 600, "secrets", 10.5, MUTED, 600)

    s.lane(32, 768, "What changes between the two installations")
    rows = [("", "Generic (picture 08)", "Azure (this picture)"),
            ("Log storage", "any S3 API (Azure Blob for now)", "Blob GZRS, private endpoint, Workload Identity, CMK"),
            ("Secrets", "generated by the chart, kept on upgrade", "Key Vault + External Secrets"),
            ("Grafana's database", "PostgreSQL by the Percona operator", "Azure Database for PostgreSQL (flexible)"),
            ("Sign-in", "Keycloak in the cluster (optionally brokering Entra ID)", "Entra ID (or Keycloak / OIDC)"),
            ("Monitoring", "Prometheus Operator: PodMonitors + PrometheusRule", "managed Prometheus + rule groups"),
            ("Kafka, collectors, Loki, read gateway", "the same", "the same")]
    for r, (a, b, c) in enumerate(rows):
        y = 780 + r * 21
        s.add(f'<rect x="32" y="{y}" width="1336" height="21" fill="{"#F1F5F9" if r == 0 else "#FFFFFF"}" stroke="{LINE}"/>')
        s.text(44, y + 15, a, 11, INK, 700)
        s.text(330, y + 15, b, 11, BODY, 700 if r == 0 else 400)
        s.text(830, y + 15, c, 11, BODY, 700 if r == 0 else 400)
    return s


def main() -> None:
    for name, fn in [("01-architecture-overview", overview), ("02-write-path", write_path),
                     ("03-read-path-and-tenancy", read_path), ("04-zones-and-failure", zones),
                     ("05-disaster-recovery", dr), ("06-durability-and-buffers", durability),
                     ("07-caching", caching), ("08-generic-in-cluster", generic),
                     ("09-azure-components", azure)]:
        (OUT / f"{name}.svg").write_text(fn().render())
        print(f"diagrams/{name}.svg")


if __name__ == "__main__":
    main()
