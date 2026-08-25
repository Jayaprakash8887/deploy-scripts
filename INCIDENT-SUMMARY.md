# PROD (41.74.172.79) inbound unreachable — investigation and resolution

**Status:** Root cause confirmed and acknowledged by the datacenter — the fault is on their side
and nothing on ours needs fixing. **Blocked on a decision**, not on further diagnosis: the
datacenter has offered a new IP from their AOS block, and we need to settle the scope of that
change before accepting (see §11). No service is currently down — PROD is empty and
`cce.moh.gov.rw` is still served from UAT.

**Last updated:** 19 August 2026

**Environment:** Rwanda CCE, physical Proxmox host at the datacenter. All addresses sit in the
single subnet `41.74.172.0/25` behind gateway `41.74.172.1`, delivered by the datacenter as one
VLAN in access mode on the host's physical port (`eno5`, bridge `vmbr0`, no VLAN tags). Edge
`197.243.24.6`.

| Address | What | Public DNS (verified 19 Aug 2026) |
|---|---|---|
| `41.74.172.72` | Proxmox hypervisor (`pve`) | — |
| `41.74.172.80` | UAT — VM 101 | `cceuat.moh.gov.rw`, **and currently `cce.moh.gov.rw`** |
| `41.74.172.79` | PROD — VM 103, MAC `4e:f7:85:c3:7e:03` | none yet — will take over `cce.moh.gov.rw` |
| `41.74.172.73` | cancer-registry VM (host not yet confirmed — see §12) | `cancerregistry.rbc.gov.rw` |

All three domains resolve **directly** to these public IPs — no CNAME, no CDN/proxy, no NAT in
front. Every address change therefore requires a public DNS change; there is no indirection layer
to absorb one.

PROD (`.79`) has never been reachable from the internet. UAT (`.80`) always worked.

---

## 1. The symptom

SSH (and, it turned out, everything else) to `41.74.172.79` was unreachable from the internet.
The same VM was reachable from **inside** the datacenter — e.g. from UAT (`.80`) over SSH — and
outbound traffic from the VM to the internet worked normally (0% loss to 8.8.8.8).

## 2. Our own diagnostics (July 22, before this investigation)

Run directly on VM 103:
- `ufw` inactive, `iptables INPUT` policy `ACCEPT` with no rules
- Correct default route via `41.74.172.1`
- Local ARP table showed `.79` resolving consistently to the correct MAC, no duplicate detected
- `tcpdump` on the VM's own NIC during external ping/SSH tests captured **zero** external packets
- The key behavioural clue: immediately after the VM sent any outbound traffic, inbound SSH from
  the internet worked — and kept working until the gateway's dynamically-learned ARP entry aged
  out, at which point inbound went dark again

This pointed at the gateway's ARP cache, but the tooling used (tcpdump filtered to the VM's own
NIC) could not see anything happening on the shared network segment beyond that NIC — which is
where the real problem turned out to live.

## 3. First request to the datacenter, and their first response

We asked the datacenter to add a static ARP entry for `41.74.172.79 → 4e:f7:85:c3:7e:03` on the
gateway, plus matching inbound ACLs, identical to what (we assumed) existed for `.80`.

Their response:

> We provision the VLAN in access mode on your port and assign the single IP for you to configure
> on your device... We do not add static ARP entries or per-IP ACLs for individual hosts. The
> gateway dynamically resolves MACs. Since `.80` works and `.79` only works briefly, the gateway is
> trying to ARP, but your VM isn't replying after the cache expires. That's a host-side issue.

Their position was reasonable on its own terms (static ARP genuinely isn't how this is normally
fixed), but their conclusion — "your VM isn't replying" — was asserted, not demonstrated. Nobody
had yet captured ARP traffic on the shared segment itself.

## 4. Reframing the problem before re-testing

Two addressing systems need to agree for a packet to arrive: the **IP** routes it to the
datacenter; the final hop from the gateway onto the local segment is resolved via **ARP**, which
maps IP → MAC and is cached for a few minutes before the gateway re-asks. The observed
symptom — "works right after outbound traffic, dies when the cache entry expires" — is exactly
what an ARP resolution problem looks like, and it can fail in one of three ways:

1. The gateway's ARP request never reaches the VM (datacenter-side)
2. It arrives and the VM doesn't answer (host-side — what the datacenter assumed)
3. It arrives, the VM answers correctly, and the answer is dropped or beaten upstream
   (datacenter-side, but invisible to a check that only looks at the VM's own NIC)

Distinguishing these needed a vantage point that could see **both** the datacenter-facing uplink
and the VM's virtual port at once — which meant capturing from the Proxmox hypervisor itself, not
from inside the guest.

## 5. Access constraint hit during this investigation

Claude could not reach the datacenter subnet directly from the user's Mac — outbound TCP/22 to
that subnet specifically was filtered on that network (confirmed by testing: `github.com:22` was
reachable, `41.74.172.72:22` was not). The working path, matching the user's own existing access,
was Mac → Tailscale → jump host `100.70.48.101` → `root@41.74.172.72` (the Proxmox host). Both
hops required password auth; with the user's explicit go-ahead, credentials from
`rwanda-servers.txt` were used to establish a single multiplexed SSH control socket, which Claude
then drove directly and read-only for the remainder of the session. The socket and all temporary
files/credentials-handling scripts were cleaned up afterward.

## 6. Diagnosis performed on the Proxmox host

All read-only. Proxmox VE 7.4-3, host `pve`, single bridge `vmbr0` carrying uplink `eno5` plus
`tap101i0` (UAT) and `tap103i0` (PROD).

**Pre-flight comparison (101 vs 103):** NIC configs were identical in shape
(`virtio=<mac>,bridge=vmbr0`, no VLAN tag, no per-NIC firewall flag). `pve-firewall` was disabled
host-wide; host `iptables` policies were all `ACCEPT`. This ruled out any Proxmox-level or
host-firewall explanation.

**First anomaly — the host's own ARP cache was wrong:**
```
ip neigh show dev vmbr0
41.74.172.79 lladdr 0c:ea:14:42:06:bd STALE      <- not VM 103's MAC
41.74.172.80 lladdr be:30:2c:d1:12:3f STALE      <- correct
```
`0c:ea:14:42:06:bd` did not match VM 103's configured MAC (`4e:f7:85:c3:7e:03`), and was absent
from VM 103's own bridge port entirely.

**Located the foreign MAC:**
```
bridge fdb show | grep -i 0c:ea:14:42:06:bd
0c:ea:14:42:06:bd dev eno5 master vmbr0     <- learned on the DATACENTER uplink, not on our VM
```
The `eno5` forwarding table also contained dozens of other unrelated MACs (other tenants /
Proxmox nodes), confirming this is a large flat shared segment, consistent with what the
datacenter described.

**Captured the actual ARP race** (uplink `eno5` and VM 103's port `tap103i0` simultaneously,
while forcing a fresh resolution):
```
11:10:49.310973  d4:f5:ef:79:4a:c8 > ff:ff:ff:ff:ff:ff  Request who-has 41.74.172.79 tell 41.74.172.72
11:10:49.311090  0c:ea:14:42:06:bd > d4:f5:ef:79:4a:c8  Reply 41.74.172.79 is-at 0c:ea:14:42:06:bd   (on eno5)
11:10:49.311094  4e:f7:85:c3:7e:03 > d4:f5:ef:79:4a:c8  Reply 41.74.172.79 is-at 4e:f7:85:c3:7e:03   (on tap103i0)
```
One request, two replies, 4 microseconds apart. **VM 103 was answering correctly all along** —
the earlier "VM stops replying" theory was wrong.

**Quantified the race** — 15 forced resolutions from the hypervisor:
- Foreign device (`0c:ea:14:42:06:bd`) answered **15/15** times
- Which reply actually won the race: **8 for VM 103, 7 for the foreign device**, from the
  hypervisor's vantage point (topologically close to both). From the gateway's vantage point —
  closer to the foreign device — it evidently won almost every time, which is why inbound was
  broken almost always and why the fault had looked intermittent.

**Confirmed no inbound ever reached the VM during the "working" window:** while the address
briefly answered pings from the public internet (35/35, 0% loss), a simultaneous capture on the
datacenter uplink showed **zero** ICMP frames for `.79` arriving there — a control capture for
`.80` in the same window caught all 76 frames. In other words, when `.79` "worked," it was the
**foreign device** answering, not the VM. Twenty minutes later the same address was back to
100% loss. This live flap was captured directly.

**Confirmed the gateway's own behaviour ruled out "it just isn't asking":** during 70 seconds of
continuous inbound pings to `.79` from the public internet, the gateway (`41.74.172.1`) sent
**2,130 ARP requests** on the segment for dozens of other addresses, retrying unresolved ones
roughly every 2 seconds — but **zero** requests for `.79` in that window. Since the gateway
clearly does keep re-asking for addresses it can't resolve, sending none for `.79` meant it
already held a (wrong) cached entry.

**Identified the offending hardware:** MAC OUI `0C:EA:14` is registered to **Ubiquiti Inc**
(MA-L block). Across all captures it claimed exactly one IP (`.79`) — a single misconfigured
device, not a proxy-ARP appliance serving multiple addresses.

## 7. Root cause

**A separate device on the shared VLAN — a Ubiquiti appliance, MAC `0c:ea:14:42:06:bd`, not our
equipment — was configured with our IP address, `41.74.172.79`.** It answered ARP for that address
just as fast as our VM (and slightly faster, in the captured race), so the gateway's cached
mapping pointed at it unpredictably. Whichever device the gateway believed owned `.79` at any
given moment received the inbound traffic; the other did not. This produced exactly the observed
symptom: works right after our VM's own traffic refreshes the gateway's cache in our favor, breaks
again once a subsequent resolution goes the other way.

Both the original datacenter diagnosis ("your VM isn't replying") and Claude's own earlier
leading hypothesis (Dynamic ARP Inspection dropping the VM's replies) were superseded by this
direct evidence — the VM was replying correctly throughout; the problem was a second, unrelated
device answering for the same address.

## 8. Evidence sent to the datacenter

`dc-ticket-41.74.172.79.md` (this folder) — withdrew the static-ARP request, presented the capture
excerpt above plus the full reasoning, and asked for one of:
- **Option 1:** locate and remove `.79` from the device with MAC `0c:ea:14:42:06:bd`, clear the
  stale gateway ARP entry, confirm sole allocation
- **Option 2:** issue a different IP from the same subnet instead

`arp-evidence-41.74.172.79.tgz` — full pcaps and readable text of every capture referenced above,
pulled from the Proxmox host and offered as an attachment if needed.

## 9. Datacenter's response

The datacenter (AOS team) investigated and confirmed the finding:

> We have investigated the issue and confirmed that 41.74.172.79 was flagged internally as a free
> IP on 26 October 2025. It was subsequently allocated to another client on the same shared VLAN,
> which resulted in the IP conflict you identified.
>
> As we are currently migrating services from the ISP range 41.74.172.x to our new AOS IP block,
> we recommend using this opportunity to resolve the issue permanently. We can allocate a new IP
> from our AOS block and migrate your service to it, avoiding any further conflict.

This matches the evidence exactly: `.79` had been double-allocated on their side.

## 10. Current status

- Root cause is confirmed by both sides: **datacenter IP double-allocation**, not a host or
  Proxmox misconfiguration on our end. Nothing on our side needs fixing.
- The datacenter has offered to allocate PROD a **new IP from their AOS block** and migrate the
  service to it, rather than reclaiming `.79` from the other tenant.
- That offer has **not yet been accepted, scoped, or scheduled** — see §11.
- No changes were made to VM 103, VM 101, or the Proxmox host during this investigation — it was
  read-only throughout. No workaround (e.g. an ARP keepalive) was applied or is currently running.
- PROD is currently **empty** — nothing is running on it and no domain points at it. The live
  service `cce.moh.gov.rw` is being served from UAT (`.80`) in the meantime, so there is no
  outage; the blocker is that PROD cannot be brought into service.

## 11. The open decision — resolution options

### The constraint that decides blast radius

All four of our addresses (`.72`, `.73`, `.79`, `.80`) are in **one subnet behind one gateway on
one access-mode VLAN**. A new IP from the AOS block is a *different subnet with a different
gateway*, so it can only reach our host if the datacenter does one of:

| How they deliver it | Effect on `.72` / `.73` / `.80` |
|---|---|
| Adds the AOS subnet **alongside** the existing one on our current VLAN | none — PROD only |
| **Trunks** a second VLAN to our port | none — PROD only |
| **Moves** our port to the AOS VLAN | all of them lose their gateway → everything must be re-addressed at once |

The first two keep this a PROD-only change. The third turns it into a full migration of every
service on the host. The datacenter has not said which they intend, so this must be asked
explicitly rather than assumed — it is the single most important thing to establish before
agreeing to anything.

### Options

**Option A — Ask them to free `.79` on the existing range, defer the migration**
- *Blast radius:* PROD only. No change to UAT or cancer-registry. No new subnet or gateway.
- *Upside:* smallest possible change; the address is already configured on VM 103.
- *Downside:* depends on the datacenter reconfiguring **another tenant's** device, which is
  outside our control and which they have already signalled they would rather not do. `.79` also
  sits on a range they are decommissioning, so a second migration is still coming later. Their
  IPAM marked `.79` free once already — recurrence is a real risk.

**Option B — Take a new AOS-block IP for PROD only (recommended)**
- *Blast radius:* PROD only — **conditional** on the datacenter delivering the new subnet on our
  existing port (rows 1–2 of the table above).
- *Upside:* permanent fix on a clean address with no double-allocation history. Because PROD is
  empty and `cce.moh.gov.rw` still resolves to UAT, this is the **lowest-risk possible pilot of
  the new AOS block** — if the new address misbehaves, nothing is down, and we only repoint DNS
  after verifying it. It also proves the block before UAT and cancer-registry have to move.
- *Downside:* two migrations overall (PROD now, the rest later); temporarily split across two
  subnets; requires the AOS block to actually be ready.

**Option C — Migrate the whole host to the AOS block now**
- *Blast radius:* everything — `.72` (hypervisor management), `.80` (UAT, serving two live
  domains), `.73` (cancer-registry, live), plus possibly a new edge IP. Three public DNS records.
- *Upside:* one coordinated cutover instead of two.
- *Downside:* highest risk, touches live production services, needs a maintenance window and
  sign-off from the cancer-registry stakeholders. Doing it *before* the new block has been proven
  in a low-stakes test is the wrong order.

### Recommendation

**Option B**, with **Option A as the fallback** if the AOS block is not ready in a useful
timeframe. Decline Option C for now — not permanently, but as a separately planned maintenance
window later, once Option B has demonstrated that the AOS block works end-to-end.

Rationale: PROD is empty, so it is the only service we can migrate with zero risk to anything
live. Spending that free trial run on the new block is worth more than the small saving of
reusing `.79`.

## 12. Open questions

**To put to the datacenter (before accepting):**
1. Will the new AOS IP be delivered **alongside** our existing `41.74.172.0/25` on the same
   physical port, or does it require moving our port to a different VLAN?
2. If a different VLAN — confirm explicitly that `.72`, `.73`, and `.80` remain reachable and
   unchanged throughout, or state what else has to change and when.
3. What are the exact new **IP, subnet mask, and gateway**? Does the edge IP (`197.243.24.6`)
   change?
4. What is the timeline for **decommissioning `41.74.172.x`**, so UAT and cancer-registry can be
   planned separately rather than being surprised by it?
5. Is `.79` confirmed as sole-allocated to us in IPAM either way, so it cannot be re-issued again?

**To confirm on our side:**
- **Which hypervisor hosts `41.74.172.73` (cancer-registry)?** This investigation only enumerated
  VM 101 and VM 103 on host `.72`; the bridge forwarding table showed multiple Proxmox nodes on
  the shared segment, so `.73` may well be on a different host. This changes whether a VLAN move
  would affect it, and who needs to be in the loop.
- Who owns the DNS records for `moh.gov.rw` and `rbc.gov.rw`, and what is the turnaround for a
  change request? This gates the cutover regardless of which option is chosen.

## 13. Cutover checklist — applies whichever option is chosen

1. **Before** the cutover, lower the TTL on `cce.moh.gov.rw` so the switch propagates in minutes,
   not hours. Do this far enough ahead that the old high TTL has expired everywhere.
2. Configure the address on VM 103 and verify **inbound reachability from outside the datacenter**
   on **TCP 22, 80 and 443** — not just SSH. Port 80 is required for Let's Encrypt issuance and
   renewal on `cce.moh.gov.rw`.
3. Re-run the duplicate-IP check on the new address before trusting it — `arp-diag.sh` in this
   folder does exactly this and is the fastest way to rule out a repeat of this incident. Update
   `TARGET`/`MAC` in it for the new address first.
4. Only once 22/80/443 are confirmed, repoint `cce.moh.gov.rw` from `.80` to PROD.
5. Leave `cceuat.moh.gov.rw` on `.80` — UAT is unaffected by all of this.
6. After propagation, confirm certificate issuance/renewal actually succeeds on PROD.
7. Restore the DNS TTL to its normal value.

## 14. Unrelated observations from this investigation (not yet actioned)

- Proxmox's web UI (`41.74.172.72:8006`) is reachable from the public internet, with `root` login
  enabled — worth restricting separately.
- Production credentials (Proxmox root, Grafana/Keycloak/Portainer admin passwords) are stored in
  plaintext in the **parent** directory (`../rwanda-servers.txt`, `../rwanda-prod.txt`,
  `../rwanda-proxmox.txt`, `../rwanda-uat.txt`), alongside an Infisical instance that appears
  intended to hold exactly these secrets. Worth migrating into Infisical and removing the
  plaintext copies — and confirming none of these files are in a git repository.

## Files in this folder

| File | What it is |
|---|---|
| `INCIDENT-SUMMARY.md` | This document |
| `dc-ticket-41.74.172.79.md` | The evidence write-up sent to the datacenter |
| `arp-evidence-41.74.172.79.tgz` | Raw packet captures backing the ticket |
| `arp-diag.sh` | Read-only ARP duplicate-IP diagnostic for the Proxmox host. Superseded by the direct interactive investigation for *this* incident, but it is the tool for **step 3 of the cutover checklist** — point it at the new address to confirm nobody else is claiming it. Update `TARGET`, `CONTROL` and `MAC` before running. |
