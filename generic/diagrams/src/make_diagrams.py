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
    s.lane(44, 130, "Write path: OpenTelemetry (OTLP end to end)")
    s.box(44, 142, 176, 170, "Tenant namespaces", ["stdout / stderr", "or an OTel SDK", "(OTLP to the node's", "agent)"],
          "slate", "namespace → tenant")
    s.box(250, 142, 196, 170, "OTel agent", ["DaemonSet, 1 per node", "files + OTLP in", "tenant from namespace", "masks PAN/IBAN/tokens"],
          "teal", "queue on node disk")
    s.box(476, 142, 196, 170, "OTel gateway", ["StatefulSet, 3 pods", "routes by tenant", "1 exporter per tenant", "own queue per tenant"],
          "teal", "queues on zonal SSD")
    s.box(702, 142, 150, 170, "Distributors", ["per-tenant", "limits", "HPA 3 → 9"], "indigo", "OTLP /otlp")
    s.box(882, 142, 228, 170, "Ingesters: 3 zones", ["RF 3, WAL on zonal disk"], "indigo")
    for i, z in enumerate("abc"):
        s.mini(894 + i * 72, 218, 66, 56, f"zone {z}", "indigo", "2 pods")
    s.arrow([(220, 227), (250, 227)], WRITE)
    s.arrow([(446, 227), (476, 227)], WRITE, "gRPC", ly=218)
    s.arrow([(672, 227), (702, 227)], WRITE)
    s.arrow([(852, 227), (882, 227)], WRITE, "×3", ly=218)

    s.lane(44, 360, "Read path")
    s.box(44, 372, 176, 160, "Bank users", ["Entra ID sign-in", "security group", "per tenant"], "slate", "no local users")
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
        ("Entra ID", ["Grafana SSO (groups → orgs)", "Workload Identity (Loki, ESO)"], "green"),
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
            "OpenTelemetry end to end. The platform decides the tenant once; every hop has a durable buffer.")
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
        ("7", "persistent queue on node disk (2 GiB)"),
    ]
    y = 368
    for n, t in steps:
        if n:
            s.add(f'<circle cx="68" cy="{y}" r="10" fill="#FFFFFF" stroke="{PAL["teal"][1]}" stroke-width="1.5"/>')
            s.text(68, y + 4, n, 10.5, PAL["teal"][2], 700, "middle")
        s.text(86, y + 4, t, 11.5, BODY)
        y += 36 if n else 30
    s.arrow([(189, 314), (189, 330)], WRITE)

    s.box(390, 124, 230, 330, "OTel gateway", ["StatefulSet, 3 pods (zones)", "only agents may connect", "",
          "routing by tenant:", "one OTLP exporter + one", "persistent queue PER TENANT", "on the pod's zonal SSD", "",
          "tenant throttled (429)?", "only ITS queue grows", "Loki down? all queue,", "retried up to 6 h"], "teal", "X-Scope-OrgID: <tenant>")
    s.arrow([(334, 600), (362, 600), (362, 290), (390, 290)], WRITE)
    s.text(372, 470, "OTLP/gRPC", 11, WRITE, 700)
    s.text(372, 486, "zstd, round-robin", 10.5, MUTED)

    s.box(656, 124, 200, 250, "Distributor", ["OTLP → Loki streams", "", "`otlp_config:`", "4 attrs → labels,", "rest → structured", "metadata", "",
          "per-tenant limits"], "indigo", "over limit → 429")
    s.arrow([(620, 250), (656, 250)], WRITE)
    s.text(638, 238, "HTTP", 10.5, WRITE, 600, "middle")

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
            "Identity comes from Entra ID groups; the tenant comes from the gateway view. Nothing a user sends can change it.")
    s.lane(32, 110, "Entra ID")
    s.lane(292, 110, "Grafana org")
    s.lane(552, 110, "obs-gateway view")
    s.lane(862, 110, "Loki")
    rows = [
        ("sg-obs-payments-*", "payments", "/payments/", "payments"),
        ("sg-obs-cards-*", "cards", "/cards/", "cards|shared-services"),
        ("sg-obs-platform-*", "platform", "/platform/", "platform|unassigned|all tenants"),
    ]
    for i, (g, org, view, hdr) in enumerate(rows):
        y = 126 + i * 118
        s.box(32, y, 220, 104, g, ["viewers → Viewer", "editors → Editor"], "green", title_size=12.5)
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
    s = Svg(1400, 640, "Durability without Kafka: a durable buffer at every hop",
            "Where logs wait when the next hop is down, how long, and where Kafka / Event Hubs would go if ever needed")
    hops = [
        ("Container", "slate", ["writes stdout", "", "kubelet log files", "on the node", "", "buffer: rotation", "(50 MiB × 5 / ctr)"]),
        ("OTel agent", "teal", ["file checkpoints", "on node disk", "", "persistent queue", "2 GiB per node", "", "retries forever"]),
        ("OTel gateway", "teal", ["persistent queue", "PER TENANT", "1-4 GiB × 3 pods", "zonal SSD (CMK)", "", "~1 h of all logs (M)", "retried up to 6 h"]),
        ("Loki ingesters", "indigo", ["WAL on zonal SSD", "", "RF 3 across", "3 zones", "", "acks after 2 of 3", "(quorum)"]),
        ("Blob Storage", "amber", ["GZRS: 3 zones", "sync + paired", "region async", "", "14-day soft", "delete", ""]),
    ]
    for i, (t, pal, ls) in enumerate(hops):
        x = 32 + i * 272
        s.box(x, 100, 236, 210, t, ls, pal)
        if i:
            s.arrow([(x - 36, 205), (x, 205)], WRITE)
    s.text(32 + 1 * 272 + 118, 338, "survives: agent restart,", 11, BODY, 400, "middle")
    s.text(32 + 1 * 272 + 118, 354, "gateway / Loki outage", 11, BODY, 400, "middle")
    s.text(32 + 2 * 272 + 118, 338, "survives: gateway pod restart,", 11, BODY, 400, "middle")
    s.text(32 + 2 * 272 + 118, 354, "Loki outage, one tenant at 429", 11, BODY, 400, "middle")
    s.text(32 + 3 * 272 + 118, 338, "survives: pod crash,", 11, BODY, 400, "middle")
    s.text(32 + 3 * 272 + 118, 354, "a whole zone", 11, BODY, 400, "middle")
    s.text(32 + 4 * 272 + 118, 338, "survives: zone loss;", 11, BODY, 400, "middle")
    s.text(32 + 4 * 272 + 118, 354, "region loss (async)", 11, BODY, 400, "middle")

    s.add(f'<rect x="270" y="390" width="530" height="60" rx="10" fill="#FFFFFF" stroke="{NEUTRAL}" stroke-width="1.5" stroke-dasharray="6 5"/>')
    s.text(535, 416, "IF EVER NEEDED: Azure Event Hubs (Kafka protocol) here", 12.5, INK, 700, "middle")
    s.text(535, 436, "agent: kafka exporter  →  topic  →  gateway: kafka receiver (both in OTel contrib)", 11, BODY, 400, "middle")
    s.arrow([(535, 390), (535, 318)], NEUTRAL, dashed=True)

    s.lane(32, 488, "Add a bus only if one of these becomes true")
    reasons = [
        ("Loki downtime regularly longer", "than the gateway queues hold (~1 h, M)"),
        ("Other consumers (SIEM, data", "lake) need the same stream + replay"),
        ("Loki's Kafka ingest mode is GA", "and scale needs it (multi-TB/day)"),
    ]
    for i, (a, b) in enumerate(reasons):
        x = 32 + i * 452
        s.box(x, 500, 430, 72, a, [b], "slate", title_size=12.5)
    s.text(32, 606, "Kafka would add: a 3rd stateful system (brokers, partitions, ACLs, upgrades, capacity), a second copy of", 11.5, MUTED)
    s.text(32, 624, "every log line, and its own failure modes, to buy durability the pipeline already has.", 11.5, MUTED)
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


def main() -> None:
    for name, fn in [("01-architecture-overview", overview), ("02-write-path", write_path),
                     ("03-read-path-and-tenancy", read_path), ("04-zones-and-failure", zones),
                     ("05-disaster-recovery", dr), ("06-durability-without-kafka", durability),
                     ("07-caching", caching)]:
        (OUT / f"{name}.svg").write_text(fn().render())
        print(f"diagrams/{name}.svg")


if __name__ == "__main__":
    main()
