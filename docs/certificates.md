# Certificates and ACME solvers

How TLS certificates are issued on this cluster, and the open question of adding
**DNS-01** alongside the HTTP-01 solver in use today.

Status: **HTTP-01 is what runs, and the recommendation is to keep it for now.**
Nothing else below is deployed. Raised in review 2026-08-10, prompted by the
number of distinct DNS zones already pointing at the cluster; a second reviewer
pointed at **DNS-PERSIST-01**, which changes the answer — see that section.

## What runs today

Two `ClusterIssuer`s (`k8s/infra-manifest/cluster-infra/clusterissuers/letsencrypt.yaml`),
`letsencrypt-staging` and `letsencrypt-prod`, each with a single HTTP-01 solver
against the `traefik` ingress class. Wire a new host up on staging first — Let's
Encrypt's production rate limits are strict — then switch the annotation.

HTTP-01 needs no credentials at all: Let's Encrypt fetches a token over plain
HTTP from the host being validated. Its cost is that the host must be **publicly
reachable on port 80 at validation time**, which is why a stale `A` record
pointing at a released IP breaks issuance intermittently (round-robin sends some
challenges to the dead address).

## Why DNS-01 is being considered

The cluster already serves **several unrelated DNS zones**, and the list will
grow:

| Zone | Owner | Example |
|---|---|---|
| infra services | infra | `*.wsinfra.scouterna.net` (test: `*.wsv2test.j26.se`) |
| shared project wildcard | infra | `*.webservices.scouterna.net` — *planned* |
| project-specific | the project | `*.wsjdev.se`, `scoutid.se`, … |

Three things HTTP-01 cannot do:

1. **Wildcards.** ACME requires DNS-01 for `*.example.com`, with no exception.
   Without it every host needs its own certificate and its own successful
   validation — so the shared project wildcard above is not possible today.
2. **Issue before DNS points at the cluster.** Useful for migrations: a
   certificate can exist before cutover rather than after.
3. **Issue for a host that is not publicly reachable on port 80.**

The wildcard is the real driver. Every new infra app and every project subdomain
is currently a separate ACME issuance, and a full cluster rebuild re-issues all
of them at once — the most likely way to meet a rate limit.

## The two can coexist — how selection works

`solvers` is a list, and cert-manager picks per certificate. **Verified against
the cert-manager docs**, precedence highest to lowest:

1. `selector.dnsNames` — exact host match
2. `selector.dnsZones` — the name is that zone or a subdomain of it
3. `selector.matchLabels` — all labels must match
4. **no selector — matches everything**

Ties go to the solver defined earliest. Upstream documents an "All Together"
example mixing HTTP-01 with several DNS-01 solvers, so this is a supported
shape, not a trick.

The practical consequence: **a DNS-01 solver with no selector would hijack every
certificate on the cluster.** Always scope DNS-01 with `dnsZones`, and leave the
HTTP-01 solver unselected as the fallback:

```yaml
solvers:
- dns01:
    azureDNS:
      hostedZoneName: webservices.scouterna.net
      resourceGroupName: <dns-rg>
      subscriptionID: <subscription>
      environment: AzurePublicCloud
      managedIdentity:
        clientID: <identity-client-id>
  selector:
    dnsZones: ["webservices.scouterna.net"]
- http01:
    ingress:
      class: traefik
```

Adding a zone later is additive — existing certificates keep using HTTP-01,
untouched.

### What happens to existing Ingresses

**Nothing, and no manifest needs changing.** Two annotations are involved and
they behave differently:

| Annotation | Role | If DNS-01 is selected |
|---|---|---|
| `cert-manager.io/cluster-issuer` | **Required.** Names the issuer; without it the ingress-shim ignores the Ingress and no certificate is created. | still required, unchanged |
| `acme.cert-manager.io/http01-ingress-class` | Optional. **HTTP-01 only** — overrides which ingress class solves the challenge. | **silently ignored** |

The second is *exclusively* an HTTP-01 setting, per the cert-manager docs: if a
certificate is solved by DNS-01, the annotation is not read at all. It does not
*select* HTTP-01 either — solver choice comes entirely from the issuer's
`solvers` list matching the certificate's DNS names. It only says which ingress
class to use once HTTP-01 has already been chosen, and it **overrides**
`solvers.http01.ingress.class` in the ClusterIssuer when both are present.

On this cluster it is redundant — the issuer already sets `class: traefik` and
Traefik is the only ingress controller. Three infra manifests set it anyway
(`dex`, `headlamp`, `kube-prometheus-stack`), harmlessly: same value as the
issuer default. Its real use is solving challenges through a *different* ingress
class than the app's own (e.g. an internal service whose challenge must arrive
via a public ingress).

So adding a scoped DNS-01 solver is **non-breaking**: for hosts in the selected
zone the HTTP-01 annotation goes quiet, and for every other host nothing changes.
That is a concrete argument for the scoped-solver shape over adding a second
ClusterIssuer, which would require every project to switch its
`cluster-issuer` annotation.

> This holds **only** because the HTTP-01 solver stays in the list as the
> unselected fallback. A DNS-01 solver added *without* a selector captures every
> certificate cluster-wide, and those annotations go inert everywhere at once.

## The part that needs deciding: credentials, per zone

**DNS-01 is per-zone, not per-cluster.** Each zone validated this way needs
write access to that zone's records, held by the cluster. So this is not one
decision but one per zone, and the credential is the substance of each.

| Zone hosted at | Auth | Secret in cluster? |
|---|---|---|
| **Azure DNS** | Workload Identity (`managedIdentity.clientID`) | **No** — federated, the pattern ESO and Velero already use |
| **Azure DNS** | service principal | Yes — client secret in a Secret |
| **Loopia** | third-party webhook solver | Yes — a Loopia API credential |

cert-manager has **no built-in Loopia provider**, so Loopia zones need a webhook
solver: another component to vendor, pin and maintain, holding a credential that
can rewrite the zone. Azure DNS with Workload Identity needs **no stored secret
at all** and reuses the federation this cluster already does twice
(`docs/install.md` §8), plus a `DNS Zone Contributor` role assignment on the zone.

That asymmetry, rather than any cert-manager detail, is what should drive the
decision.

## DNS-PERSIST-01 — the option worth waiting for

Raised by a reviewer, and it attacks precisely the problem above. **DNS-PERSIST-01**
replaces repeated proof-of-control with a **single standing TXT record** at
`_validation-persist.<domain>`, naming the CA's issuer domain and our ACME
account URI. Add `policy=wildcard` and it authorises wildcards too.

**No DNS write access at validation time.** The record is published once, by
hand, and reused for every issuance and renewal thereafter.

That dissolves the credential question entirely — the thing this whole decision
turns on:

| | DNS-01 | DNS-PERSIST-01 |
|---|---|---|
| DNS credential in the cluster | **yes**, per zone | **none** |
| Loopia zones | third-party webhook + API credential | one TXT record, no provider needed |
| Project-owned zones | our cluster can rewrite their domain | they publish one record authorising our account; revocable at their end |
| Wildcards | yes | yes (`policy=wildcard`) |

**It is not usable yet — verified 2026-08-10, and the published timeline has
already slipped:**

- **Let's Encrypt:** in **staging**, *not* production. Deployment is explicitly
  blocked — Aaron Gable (LE staff), June 2026: *"We will not be deploying
  dns-persist-01 until [issue #64] is resolved."* The Feb 2026 announcement
  targeted Q2; by May that had moved toward Q3, and the spec is still evolving.
- **cert-manager:** [issue #8373][cm8373] is **open**, no assignee, no PR, no
  branch. Nothing implemented.

Both were "late Q1 / Q2 2026" on paper and neither has landed. **Re-check both
before acting on this section** rather than trusting the dates.

Spec is an [IETF ACME working-group draft][draft] (adopted Oct 2025; CA/Browser
Forum ballot SC-088v3 passed the same month), so the direction is settled even
though the details are not.

[cm8373]: https://github.com/cert-manager/cert-manager/issues/8373
[draft]: https://datatracker.ietf.org/doc/draft-ietf-acme-dns-persist/

## Recommendation

**Do nothing yet.** HTTP-01 works, is proven on this cluster, and there is no
wildcard need urgent enough to justify building a mechanism that may be obsolete
within a year. Building DNS-01 now means per-zone credentials — the expensive,
ongoing part — for a capability DNS-PERSIST-01 is on track to provide with a
static record and no credential at all.

**Revisit when either** a wildcard becomes genuinely blocking (the shared
`*.webservices.scouterna.net` is the likely trigger), **or** Let's Encrypt ships
dns-persist-01 to production *and* cert-manager implements it.

**If a wildcard is needed before then**, the smallest step is one zone:
`*.webservices.scouterna.net` on Azure DNS via Workload Identity.

- It is infra-owned, so no third party's credential enters the cluster.
- No stored secret — same federation pattern as ESO and Velero.
- It delivers the wildcard that removes per-project certificate work, which is
  the strongest reason to do this at all.
- Every Loopia-hosted zone stays on HTTP-01, exactly as today.

Then treat each further zone as its own decision, with that precedent to follow.

## Open questions

- **Does a project-owned zone (`wsjdev.se`, `scoutid.se`) get DNS-01?** It means
  a credential that can rewrite someone else's domain living in this cluster. A
  project cannot create one itself — the per-project AppProject excludes `Secret`
  and `ExternalSecret` — so this stays infra-granted, like a database. Worth
  deciding deliberately rather than by omission. **DNS-PERSIST-01 would make this
  question mostly go away** — the project publishes one TXT record instead of
  handing over a credential.
- **Would `webservices.scouterna.net` be delegated to Azure DNS, or moved?**
  Delegation (an `NS` record at Loopia for that subdomain only) keeps the parent
  zone where it is and is the smaller change.
- **How does a wildcard certificate reach project namespaces?** A `Certificate`
  in one namespace produces a Secret in that namespace; Traefik will not read it
  from another. Options are a per-namespace `Certificate` against the same
  wildcard issuer, or replicating the Secret. **Unresolved — decide before
  promising projects a wildcard.** Note this is a Kubernetes/Traefik question,
  not an ACME one: **no challenge type solves it**, DNS-PERSIST-01 included. It
  determines whether a wildcard actually saves the work it appears to.
- **Propagation timing.** DNS-01 fails differently from HTTP-01: a certificate
  sits `Pending` while cert-manager waits for the TXT record to propagate. Add
  `kubectl describe challenge` to the troubleshooting notes if this lands.

## If this is implemented

- Prove it on **`letsencrypt-staging` first** — a wildcard failing repeatedly
  against production is a fast route to a rate limit.
- Verify the HTTP-01 hosts still issue afterwards. A mis-scoped selector shows
  up as *other* certificates quietly switching solver, not as an error.
- `kubectl get certificate -A` and `kubectl describe challenge -A` are the two
  commands worth knowing; see [argocd.md](argocd.md) for the sync side.
