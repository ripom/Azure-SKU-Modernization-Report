# Azure SKU Modernization Report

**Current version:** `v0.9`

> **See the output first:** open the rendered anonymized dashboard:
> [Rendered HTML demo](https://ripom.github.io/Azure-SKU-Modernization-Report/examples/Azure-SKU-Modernization-Report-example.html)
> ([source HTML](examples/Azure-SKU-Modernization-Report-example.html)).
> It is a sanitized illustrative artifact and may be regenerated separately from the current release; use a
> fresh local run for release-accurate labels, controls and counts.

## Quick navigation

- [Prerequisites](#prerequisites)
- [Minimum Azure permissions](#minimum-azure-permissions)
- [Command syntax](#command-syntax)
- [Common runs](#common-runs)
- [Review tests](#review-tests)
- [How the script works](#how-the-script-works)
- [CPU vendor and architecture policy](#cpu-vendor-and-architecture-policy)
- [HTML dashboard layout](#html-dashboard-layout)
- [Cost impact on Reserved Instance / Savings Plan](#cost-impact-on-reserved-instance--savings-plan)
- [Remediation wave plan](#remediation-wave-plan)
- [Coverage and disclaimer](#coverage-and-disclaimer)
- [Parameter reference](#parameter-reference)
- [Generated outputs](#generated-outputs)
- [Consistency guardians and delivery readiness](#consistency-guardians-and-delivery-readiness)

Generates a fully deterministic Azure VM modernization report (SKU retirements, migration candidates,
retail cost delta, readiness) including a fact-derived executive dashboard. Output: CSV, JSON
and a scan-first HTML dashboard in `out/<timestamp>/`.

## Principles

- **Fully deterministic.** The report is built only from computed and reconciled `$facts`; the
  executive summary prose is generated from those facts, so the same inputs always yield the same
  output (no external language model, no network call to generate the narrative text).
- **LIVE-only retirement.** Retirement signals come exclusively from live sources:
  - Stream A: Azure Advisor via Resource Graph (per-resource), discovered by the
    **Service Upgrade and Retirement** subcategory — no hardcoded list of recommendation type IDs,
    so every SKU family (present and future) is captured automatically.
  - Stream B: Microsoft Learn markdown (SKU-family)
  - Stream C: Microsoft Release Communications JSON API (SKU-family)
  - No hardcoded fallback list.
- **Release Communications API is an official retirement source.** Stream C reads official public
  communications across all available history by default. A notice creates a SKU-family finding only when
  it has structured retirement availability and deterministically names a SKU family present in tenant
  inventory. Microsoft Learn retains priority when both sources cover the same family. Unmatched notices are
  still rendered as **Corroborated**, **FinOps** or **Review-only** coverage context.

  Official Microsoft endpoint:

  ```text
  https://www.microsoft.com/releasecommunications/api/v2/azure
  ```

  The script's default query restricts that endpoint to retirement notices for the Compute products covered
  by the report:

  ```text
  https://www.microsoft.com/releasecommunications/api/v2/azure?$filter=tags/any(t:%20t%20eq%20%27Retirements%27)%20and%20(products/any(p:%20p%20eq%20%27Azure%20Dedicated%20Host%27)%20or%20products/any(p:%20p%20eq%20%27Azure%20Kubernetes%20Service%20(AKS)%27)%20or%20products/any(p:%20p%20eq%20%27Azure%20Linux%27)%20or%20products/any(p:%20p%20eq%20%27Batch%27)%20or%20products/any(p:%20p%20eq%20%27Linux%20Virtual%20Machines%27)%20or%20products/any(p:%20p%20eq%20%27Virtual%20Machine%20Scale%20Sets%27)%20or%20products/any(p:%20p%20eq%20%27Virtual%20Machines%27)%20or%20products/any(p:%20p%20eq%20%27Windows%20Virtual%20Machines%27))&$orderby=modified%20desc
  ```
- **Trust describes provenance, not per-resource certainty.** `High` confidence means that evidence came
  through an accepted official-source path and passed deterministic validation. Advisor is tenant-specific;
  Learn and Release Communications remain public SKU-family evidence and still require impacted-resource
  reconciliation in Service Health or the Retirement Workbook.
- **Retirement vs upgrade split.** The Advisor subcategory contains both genuine retirements and
  pure upgrade prompts. A signal is treated as a **retirement** only when it carries a retirement
  date; upgrade-only signals (no date) are captured separately and are **not** counted on the
  retirement path.
- **Not an official Microsoft tool.** The report is indicative and may contain errors or omissions;
  it guides and orients the analysis but does not replace authoritative sources. Every result must be
  verified in Azure Advisor, Service Health and the Azure Retirement Workbook. The HTML report carries
  an explicit disclaimer and an **Analysis Coverage** section describing what is and is not covered.
- **Separate monitoring lifecycle.** Dependency Agent / VM Insights Map retirement is tracked in a
  separate section and does not contribute to the compute SKU retirement count. Its per-resource
  retirement date is read from the live Azure Advisor recommendation; no fallback date is embedded.
- **Presentation-only dashboard.** The HTML dashboard reads already-computed facts, remediation waves
  and provenance values. It does not reclassify rows or recompute retirement counts, cost deltas,
  wave assignments, evidence classes or SKU recommendations.
- **Executive view shows total compute exposure.** Standalone VMs remain the main remediation and CSV
  population, but the Executive Summary and Decision Room also surface Public Preview VMSS and Batch
  retirement-path counts so the first screen shows total compute exposure at a glance.
- **Preview remediation follows the resource model.** VMSS and Batch are not folded into standalone VM
  waves. Instead, affected sidecar resources get a Public Preview remediation queue based on scale-set
  model rollout and Batch pool replacement/drain patterns.
- **Commitment impact flagged, not calculated.** When a SKU covered by a Reserved Instance or a
  Savings Plan is on a retirement path, the report raises a **warning** with the date ("when"),
  without quantifying the financial effect (effective RI/SP pricing is out of scope).
- **Reserved Instance cutoff planning is Public Preview.** The report separately flags compute
  resources whose VM size family is affected by the Reserved VM Instance new purchase/renewal cutoff
  announced through Release Communications. The cutoff date and affected family names are extracted
  from the official API record, not maintained as a static list. This is a FinOps planning signal, not a VM shutdown signal, and it does **not**
  prove that an active reservation exists in the tenant. It does **not** change the VM retirement-path
  count, CSV backlog or remediation wave totals.
- **Azure Batch pool exposure is Public Preview.** Batch pools are separate Azure Batch resources that
  use normal Azure VM sizes. The report can now scan `Microsoft.Batch/batchAccounts/pools`, match each
  pool's `vmSize` against the same live VM-size retirement resolver, and show affected pools in a
  separate preview section. Batch pool rows do **not** change the VM retirement-path count, CSV backlog
  or remediation wave totals.
- **VM Scale Set exposure is Public Preview.** VMSS resources are scanned separately from standalone
  VMs. The report matches `Microsoft.Compute/virtualMachineScaleSets` `sku.name` values against the
  same live VM-size retirement resolver and shows affected scale sets in a separate preview section.
  VMSS rows do **not** change the VM retirement-path count, CSV backlog or remediation wave totals.
- **Preview sidecars are non-blocking.** Batch, VMSS and RI cutoff sidecars are informational previews.
  Empty inventories or missing optional resource types should produce zero preview rows and must not
  block the standalone VM report, retirement source health checks or delivery gate.
- **Delivery gate before publishing.** Before the HTML is written the report passes a layered set of
  consistency guardians and a final automated delivery-readiness gate (`Assert-DeliveryReady`) that
  re-verifies the run-time and post-run checks in one auditable place. Golden rule: if a number has no
  traceable live source, the report is not delivery-ready. See
  [Consistency guardians and delivery readiness](#consistency-guardians-and-delivery-readiness).

## Changelog

Release history is maintained in [CHANGELOG.md](CHANGELOG.md).

## Review tests

The repository includes a focused Pester review suite for retirement-source parsing, SKU resolution,
recommendation safety, cost publication guards, backlog selection and external API contracts. The `v0.9`
baseline contains 164 tests and is validated with Pester 5.7.1.

Run it with Pester 5:

```powershell
Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 5.0 -Force
Invoke-Pester .\review\AzureSkuModernizationReport.Review.Tests.ps1 -Output Detailed
```

### What the tests establish about trust

The Pester suite validates the report's deterministic **trust policy**, not the absolute truth of an
external publication. It verifies that:

- the default Stream C endpoint uses the expected Microsoft HTTPS host and API path;
- Advisor is treated as tenant-specific evidence, while Learn and Release Communications remain
  SKU-family evidence;
- Stream C requires structured retirement availability, a retirement ring, a boundary-safe SKU-family
  mention and a family present in tenant inventory;
- commercial RI purchase/renewal notices cannot become technical VM-size retirements;
- unknown sources receive low confidence, unavailable official data is not fabricated, and strict mode
  fails closed when every enabled live source fails;
- every retiring SKU receives a non-retiring catalog alternative when at least one candidate passes the
  availability, architecture, workload-class and performance hard gates;
- the retirement fallback can cross family, upsize and switch Intel/AMD, but cannot cross the x64/ARM
  boundary or select a target that is itself on a known retirement path;
- same-family candidates prioritize the lowest validated Retail price, while cross-family candidates first
  minimize vCPU/memory distance and then Retail price;
- recommendations do not contain hardcoded SKU-to-SKU mappings. They use live catalog candidates plus explicit
  family-level policy. For retiring A-family basic VMs, the preferred successor order is B (basic/burstable),
  then D (general purpose), then the generic cross-family search. Each family is considered only when a candidate
  passes availability, architecture, workload-class, performance, retirement and configured cost gates;
- within the selected successor family, ranking minimizes effective vCPU/RAM growth and then Retail price. The
  regression suite pins `A1_v2 -> B2als_v2 -> W3`, proves that D is selected when B fails a gate, and verifies
  that generic fallback remains available when both preferred families fail their hard gates;
- fully tied candidates use the normalized SKU name as the final deterministic ordering key, so API/catalog
  input order cannot change a recommendation. A repeat-run gate also requires byte-identical VM-to-target
  mappings for identical inputs;
- reductions in local temporary storage, local NVMe, maximum NICs or maximum data disks are retained as
  explicit validation warnings rather than suppressing an otherwise suitable lower-cost target;
- the engineer view labels each target as equivalent or non-equivalent on compared catalog capabilities,
  shows exact differences including commercial workload-profile and known CPU-vendor changes plus selection rationale, and states that workload profile, burstability, CPU,
  storage, NIC/disk ceilings, licensing and application behavior still require workload validation;
- `N/A` is retained only for an explicit hard-gate impossibility, not merely because no same-family or
  equivalent-shape target exists;
- remediation waves depend only on urgency and raw workload/change facts. Recommendation wording and the
  advisory RI/SP retirement-impact flag cannot promote or demote a VM;
- standalone Retail commitment discovery queries Reservation records only. Savings Plan eligibility remains
  derived from nested Consumption pricing data rather than a standalone Retail `priceType` query;
- source counts, evidence classes, remediation waves and rendered totals reconcile before publication.

`High` confidence means that the evidence came through an accepted official-source path and passed the
report's deterministic gates. For Learn and Release Communications it does **not** prove that a specific
tenant resource is impacted; only Advisor provides per-resource evidence in this report.

The suite cannot independently prove that Microsoft authored a semantically correct notice, detect every
future wording/schema change, guarantee that Azure RBAC exposed the complete tenant scope, or replace
Service Health impacted-resource verification. Those are external-truth and coverage risks, so final
decisions must still be reconciled with Advisor, Service Health and the Retirement Workbook.

The review suite is hermetic: external calls are mocked with controlled fixtures. This makes regressions
repeatable and lets negative cases be tested reliably, but it is not a live integration or publisher-
authenticity test. Runtime HTTPS validation, source-health logging and manual impacted-resource
reconciliation remain separate operational controls.

## Prerequisites

- PowerShell 7+
- Azure sign-in already completed (`Connect-AzAccount`)
- Azure read permissions on the analyzed scope. The easiest reliable assignment is `Reader` on each
  analyzed subscription; stricter custom-role options are described below.

## Minimum Azure permissions

The script is read-only. It does not resize VMs, change VMSS models, change Batch pools, create
reservations, or modify Azure resources. There are two useful ways to think about permissions:

- **Recommended minimum, lowest effort:** assign the built-in `Reader` role at subscription scope.
  This is the simplest permission model and gives the most complete report.
- **Strict least privilege:** use a custom read-only role with only the resource-provider read actions
  the script needs. This is more precise, but it requires more governance work and still needs some
  subscription-scope reads for Advisor, Resource Graph and Compute SKU availability.

Recommended assignment options:

| Option | Scope | Role / permission model | What you get |
| --- | --- | --- | --- |
| Easiest reliable minimum | Each analyzed subscription | Built-in `Reader` | Complete inventory, Advisor signals, VMSS/Batch sidecars and Compute SKU availability with the least setup effort. |
| Multi-subscription convenience | Management group containing the analyzed subscriptions | Built-in `Reader` inherited by subscriptions | Same practical result as subscription-level Reader, but managed once at management-group scope. Use only if your governance model allows inheritance. |
| Reduced-scope report | Selected resource groups or resources | Built-in `Reader` on those scopes | Partial visibility for VM/VMSS/Batch resources in that scope. Advisor and SKU availability may still require subscription-scope read access, so the report can be incomplete. |
| Strict least privilege | Usually subscription scope for shared data plus narrower scopes where supported | Custom role with explicit read actions | Smallest permission surface, but more operational effort. Best for controlled environments where custom RBAC is standard. |

For normal use, assign `Reader` at the **subscription** scope for each subscription included in
`-SubscriptionIds`. If you pass multiple subscriptions, the signed-in identity needs read access on all
of them. If you omit `-SubscriptionIds`, the script scans the enabled subscriptions visible to the
current Azure context, so the output is only as complete as the subscriptions the identity can read.

Strict least-privilege custom role baseline:

```text
Microsoft.Resources/subscriptions/read
Microsoft.Resources/subscriptions/resourceGroups/read
Microsoft.ResourceGraph/resources/read
Microsoft.Advisor/recommendations/read
Microsoft.Compute/skus/read
Microsoft.Compute/virtualMachines/read
Microsoft.Compute/virtualMachines/extensions/read
Microsoft.Compute/virtualMachineScaleSets/read
Microsoft.Batch/batchAccounts/read
Microsoft.Batch/batchAccounts/pools/read
```

Important scope notes:

- **VM inventory, VM extensions, VMSS inventory, Batch accounts and Batch pools** can be narrowed to
  selected resource groups or resources if you intentionally want a limited report.
- **Azure Advisor retirement signals** are subscription-level recommendations. To reliably include
  Advisor-confirmed retirement rows, grant the identity permission to read Advisor recommendations at
  subscription scope.
- **Compute Resource SKUs API** is called through a subscription-level ARM endpoint
  (`/subscriptions/{subscriptionId}/providers/Microsoft.Compute/skus`). It is used to understand regional
  SKU availability and restrictions, so it is not tied to one specific VM resource.
- **Azure Resource Graph** returns only resources the identity can read. Narrow scopes produce narrow
  results; this is valid when intentional, but it is not a complete subscription report.
- **Azure Retail Prices API, Microsoft Learn retirement data and Microsoft Release Communications**
  are public sources; they do not require tenant-specific Azure RBAC.

No elevated roles such as `Contributor`, `Owner`, `Virtual Machine Contributor`, `Cost Management
Reader`, or reservation administrator roles are required for the default report. The report estimates
retail/list-price deltas and RI/SP signals from public pricing data; it does not read actual billing,
reservation inventory, invoices, negotiated prices, or Cost Management data.

## Command syntax

```powershell
.\AzureSkuModernizationReport.ps1 `
  [-SubscriptionIds <string[]>] `
  [-TenantId <string>] `
  [-Regions <string[]>] `
  [-OutputRoot <string>] `
  [-UseDeviceAuthentication] `
  [-SkipAdvisor] `
  [-SkipRetailApi] `
  [-Currency <string>] `
  [-RequireLiveRetirementSource <bool>] `
  [-BatchManagementApiVersion <string>] `
  [-UseReleaseCommunicationsApi <bool>] `
  [-ReleaseCommunicationsApiUrl <string>] `
  [-ReleaseCommunicationsLookbackMonths <int>] `
  [-ReleaseCommunicationsCacheTtlHours <int>] `
  [-ForceRefreshCache]
```

All parameters are optional. With no region filter the script detects regions from the VM inventory.
With no subscription filter it scans the enabled subscriptions available in the current tenant/context.

## Common runs

### Basic run

```powershell
.\AzureSkuModernizationReport.ps1 `
  -SubscriptionIds "<subscription-id>" `
  -TenantId "<tenant-id>"
```

Without any other parameters the script detects the regions from the inventory, uses the local cache
when available, and produces CSV/JSON/HTML.

### Multiple subscriptions

```powershell
.\AzureSkuModernizationReport.ps1 `
  -TenantId "<tenant-id>" `
  -SubscriptionIds @("<subscription-id-1>", "<subscription-id-2>")
```

### Limit analysis to specific regions

```powershell
.\AzureSkuModernizationReport.ps1 `
  -SubscriptionIds "<subscription-id>" `
  -Regions @("uksouth", "italynorth")
```

### Force fresh SKU/price data

```powershell
.\AzureSkuModernizationReport.ps1 `
  -SubscriptionIds "<subscription-id>" `
  -ForceRefreshCache
```

### Enforce live retirement-source availability

```powershell
.\AzureSkuModernizationReport.ps1 `
  -SubscriptionIds "<subscription-id>" `
  -RequireLiveRetirementSource $true
```

Use this mode when a report must not be produced if all enabled live retirement sources are unavailable.

## How the script works

At a high level the script follows this deterministic pipeline:

1. **Inventory:** reads standalone VMs from Azure Resource Graph. Public Preview sidecars also read
  Azure Batch pools and VM Scale Sets as separate resource types.
2. **Retirement sources:** loads live retirement signals from Azure Advisor Resource Graph, Microsoft Learn
  and the Microsoft Release Communications API. Upgrade-only Advisor prompts without retirement dates are
  not counted as retirements. Stream C fills SKU-family gaps only for deterministic tenant-inventory matches
  backed by structured retirement availability; Learn retains priority for duplicate family coverage.
3. **Release Communications coverage:** uses the same retirement-only JSON API result for the Coverage tab.
  The first sync caches the complete paginated retirement index and one detail document per ID. For 24 hours
  later runs use the local cache; after the TTL, only records modified since the last successful watermark and
  their detail documents are downloaded. All returned notices are rendered by default. Notices are
  classified as Corroborated, FinOps or Review-only. A guard ensures Coverage rendering cannot mutate the
  findings already computed from the source result.
4. **SKU and price catalog:** loads a subscription-scoped, region-filtered Compute SKU catalog for each
  subscription plus shared Retail Prices data. Compute SKU pages are compacted immediately to keep memory
  bounded, and cache entries are isolated by tenant, subscription and region scope. A catalog failure in one
  subscription keeps its VM rows for manual review instead of applying restrictions from another subscription.
5. **Recommendation engine:** selects compatible target SKUs through the governed cascade documented below
  and records generation, architecture, quota/capacity and validation caveats. For x64 targets, the normal
  paths prefer the current CPU vendor (Intel or AMD). A mixed-vendor target is selected only when no compatible
  same-vendor target exists or when its known Retail price is lower; the reason is shown in the recommendation
  note. An x64-to-ARM or ARM-to-x64 target is never proposed.
6. **Classification:** builds standalone VM retirement facts, remediation waves and sidecar previews
  for Batch, VMSS and RI cutoff planning.
7. **Validation gates:** checks source health, fact reconciliation, monitoring separation, OS-aware
  pricing and delivery readiness before writing the report.
8. **Output generation:** writes CSV, JSON, HTML and logs into the timestamped output folder.

The HTML is a presentation layer over computed facts. It does not invent new counts or reclassify rows.

## Recommendation cascade for retiring SKUs

The engine evaluates candidates in this order:

1. same family and workload model;
2. same vCPU/memory shape on a newer generation;
3. bounded burstable modernization, including the minimum 1-to-2-vCPU step when required;
4. technically compatible nearby/cross-family target;
5. governed retirement fallback across non-retiring x64 families, with upsize and Intel/AMD change allowed.

The final retirement fallback exists to prevent a retiring SKU from being left without a recommendation only
because its family or exact shape has no modern successor. It preserves these hard gates:

- the target is available in the VM's region and subscription;
- x64 and ARM64 are never crossed;
- vCPU and memory are not reduced;
- Premium/Ultra disk and accelerated-networking support are not regressed;
- general-purpose, GPU, HPC and Confidential Compute workload classes are not crossed;
- the configured performance floor is met using a common performance model;
- the target is not itself matched by a known retirement signal.

The configured cost and ordinary upsize ceilings remain normal-path controls. For a retiring SKU they cannot
by themselves suppress the last safe alternative: cost, size and CPU vendor instead influence candidate
ranking and are surfaced as validation impacts. `CandidateTargetSku = N/A` therefore means no catalog target
passed the hard gates and requires manual architecture review. It does not mean only that the current family
lacked an equivalent size.

Candidate ranking follows two cost-aware priorities. Within the same family, the lowest validated Retail
price wins among candidates that pass the hard gates. For cross-family and retirement fallback candidates,
the engine first minimizes combined proportional vCPU/memory distance and then selects the lowest Retail
price among equally close shapes. Generation, CPU vendor and feature score are later tie-breakers.

Maximum data-disk count, maximum NIC count and temporary/local-storage form are SKU ceilings, not evidence of
actual workload use. They therefore do not force an oversized target. Any reduction or resource/cache/NVMe
change is surfaced in `ValidationChecklist` and `MigrationRisksAndBlocks` as a warning to compare against the
VM's actual attachments and storage dependency before resize.

Every selected target also exposes `CandidateEquivalenceStatus`, `CandidateEquivalenceDetails` and
`CandidateSelectionReason` in JSON/CSV. `Equivalent` means an exact match on effective vCPU, memory, maximum
data disks, maximum NICs, temporary/local-storage type, Premium IO, Ultra SSD and Accelerated Networking.
Any difference produces `NotEquivalent` with explicit `current -> target` values. The HTML engineer view shows
the equivalence badge, why the target was selected and the same differences in its Validation column.

CPU comparisons use `vCPUsAvailable` when Azure publishes it, falling back to nominal `vCPUs` only when the
available count is absent. Constrained variants such as `Standard_F4-1amds_v7` therefore count as one usable
vCPU, not four, and cannot replace a four-vCPU source merely because their parent shape has four nominal CPUs.

Workload class is also a hard compatibility boundary. General-purpose SKUs cannot fall through to GPU (`N`),
HPC (`H`) or Confidential Compute (`DC`/`EC`) families solely because their numeric capabilities happen to
fit. Sources already in one of those specialized classes remain within the same class.

## CPU vendor and architecture policy

Candidate selection treats CPU architecture and CPU vendor as separate concerns:

| Current / candidate | Selection policy |
|---|---|
| Intel x64 -> Intel x64 | Preferred when technically compatible. |
| AMD x64 -> AMD x64 | Preferred when technically compatible. |
| Intel x64 <-> AMD x64 | Allowed only when no compatible same-vendor candidate exists, or when the mixed-vendor candidate has a known lower Azure Retail price than the compatible same-vendor alternative. |
| x64 <-> ARM64 | Never proposed. ARM is a hard architecture boundary, including when `-AllowArchitectureChange` is supplied. |

When both same-vendor and mixed-vendor candidates lack a usable Retail price, the same-vendor candidate
retains priority. A missing price is never interpreted as a saving. All normal candidate gates still apply:
region and subscription restrictions, vCPU/memory bounds, workload class, Premium/Ultra disk, accelerated
networking, performance floor and configured cost ceiling. NIC, data-disk and local-storage differences are
advisory checks.

For a SKU on a live retirement path, the engine must provide a non-retiring alternative whenever one passes
the hard safety gates. If same-family and equivalent-shape selection returns no target, a governed fallback
searches other x64 families, permits a compute/memory upsize and may switch Intel/AMD. Availability,
subscription restrictions, architecture, workload class and the performance floor remain mandatory;
the configured cost ceiling becomes a ranking signal rather than a blocker. A target already on a known
retirement path is never proposed. `N/A` is emitted only when no catalog candidate passes these hard gates,
with an explicit manual-architecture-review reason.

Local temporary storage is detected from Azure capacity and placement capabilities (`MaxResourceVolumeMB`,
cached-disk bytes, local NVMe size and ephemeral OS disk placements) plus the Azure SKU `d` feature marker when
capacity metadata is incomplete. A target may differ or have no local storage, but the report emits a warning
check and treats the saving as conditional on confirming that the workload does not depend on that capability.

Constrained Azure size names such as `Standard_DS12-1_v2` and `Standard_DS12-2_v2` inherit the retirement
series of their parent size (`Dsv2-series`). Numeric constrained-vCPU suffixes do not allow an otherwise
retiring SKU to pass as a non-retiring target.

The vendor is read first from Compute SKU capability metadata when Azure supplies a recognized manufacturer
or vendor field. For x64 records without that metadata, the resolver uses Azure SKU naming semantics (for
example, the `a` variant in `Standard_B2ats_v2` identifies an AMD-based size). If the vendor cannot be
determined, it remains `Unknown` and no Intel/AMD preference is asserted.

Each recommendation row exposes the decision in structured output:

| Field | Meaning |
|---|---|
| `CurrentCpuVendor` | Detected vendor of the current SKU: `Intel`, `AMD`, `ARM` or `Unknown`. |
| `TargetCpuVendor` | Detected vendor of the selected target SKU. |
| `CpuVendorChange` | `$true` only for a known Intel/AMD change. |
| `CpuVendorChangeReason` | `LowerRetailPrice`, `NoSameVendorAlternative` or `N/A`. |

For a mixed-vendor recommendation, the HTML recommendation note states whether the change was selected for
lower Retail price or because no compatible same-vendor alternative was available. This remains a planning
recommendation: validate vendor-sensitive licensing, native dependencies and performance before migration.

## HTML dashboard layout

The HTML output is a self-contained dashboard designed for quick scanning and PDF export. It uses only
inline CSS (no external CDN, JavaScript or font dependency) and renders the same facts that drive the
CSV/JSON outputs. The left sidebar contains a CSS-only section switcher; selecting a view changes the
right-hand pane while the provenance/sidebar facts remain visible.

The layout is fluid: KPI cards, matrix cells, scenarios and cost panels use responsive grids that
expand or collapse with the screen size. Wide operational tables are kept inside scrollable table
containers so large datasets remain readable instead of forcing narrow columns.

Audience views:

- **Executive Overview (CXO):** landing view with Executive Summary, KPI cards, info strip and
  Decision Room. It keeps the big picture visible: total compute exposure, standalone VM wave counts,
  VMSS/Batch preview count, nearest deadline, retail delta, RI cutoff planning and monitoring count.
- **CSA / Engineer:** implementation detail for standalone VMs plus Public Preview sidecars. It
  includes the per-VM CSA / Engineer table, Preview Sidecar Coverage counts, Preview Remediation
  Queue for VMSS/Batch, Batch pool exposure, VMSS exposure and Monitoring Lifecycle technical detail.
  The VM table is ordered by
  remediation wave (`W0` to `W4`), then retirement date and VM name; cost columns are intentionally
  excluded from this engineering view.
- **Project Plan:** delivery view for PMs and migration leads. It contains Summary by Change Type,
  Risk vs Effort Matrix, Execution Scenarios, If We Do Nothing deadline queue and the W0-W4
  Remediation Plan wave panels.
- **FinOps:** cost and commitment planning view. It contains Cost Impact (monthly), VM Cost Detail,
  RI / Savings Plan flags and the compact Reserved Instance Cutoff Planning family summary. VM Cost
  Detail follows remediation wave order (`W0` to `W4`), then retirement date and VM name.
  Per-resource RI cutoff detail remains in CSV/JSON outputs.
- **Coverage:** evidence and audit view with Analysis Coverage plus generated time, live-source
  provenance, as-of date and disclaimer.

### How to read the Decision Room

Decision Room presents two related but distinct scopes: standalone VM execution waves and total Compute
exposure. Read the cards and chips in this order:

1. The status fraction is `impacted Compute resources / scanned Compute resources`. Both sides include
  standalone VMs, VM Scale Sets and Batch pools. Monitoring lifecycle rows are excluded.
2. **This sprint**, **Next wave** and **Quick wins** partition standalone retirement-path VMs:
  `W0 + (W1 + W2 + W3) + W4 = standalone VM retirement-path count`. A VM belongs to one wave only.
3. **Preview sidecars** is impacted VMSS plus Batch pools. Add this card to the standalone VM count to
  obtain the Compute total. Sidecars remain outside standalone VM waves and backlog.
4. **Advisor-confirmed share** uses standalone retirement-path VMs as its denominator. `0%` means none
  has a per-resource Advisor signal; official Microsoft Learn or Release Communications family evidence
  may still support every finding, so this does not contradict `live sources ok`.
5. **RI cutoff planning** is a commercial offer population. It may overlap retirement-path resources,
  does not prove an active reservation exists and is not added to the Compute total.
6. **Monitoring kept separate** is an Azure Monitor feature-lifecycle population. A VM may appear both
  here and on the Compute retirement path, so this count is also not additive.

For the example `10/14 | VM 9, VMSS 1, Batch 0`, ten of fourteen scanned Compute resources are on a
retirement path. The lane cards reconcile as `0 + 4 + 5 = 9` standalone VMs; adding one VMSS sidecar
produces the Compute total of ten. The `11` RI-cutoff resources and `8` monitoring VMs are separate,
potentially overlapping views and must not be added to ten. The monthly amount is a PAYG/list-price delta
for standalone VM candidates, and the nearest deadline is the earliest dated retirement finding in scope.

The **Legend** control remains in the sidebar and opens a closeable guide explaining core concepts,
wave meanings, count reconciliation, denominator choices, overlap rules, detail-table fields, cost caveats
and validation expectations.

Print/PDF output uses a dedicated `@media print` stylesheet that expands all audience views and detail
sections sequentially so tabbed content is not hidden in exported PDFs.

### Provenance assembly

Dashboard provenance is assembled upstream in the report flow and then passed to the renderer. The
renderer displays these fields only; it does not derive them. Provenance currently includes:

- generated UTC;
- tenant and subscription counts from the run scope;
- live sources text and live-source OK status from retirement source health;
- as-of date from source health or row-level `RetirementSourceAsOf` values;
- nearest retirement date and VM, selected from existing retirement-date fields.

## Cost impact on Reserved Instance / Savings Plan

The report does **not** calculate the actual financial impact of RI or Savings Plan (the effective
pricing of a commitment is out of scope). Instead it detects **whether and when** a SKU covered by a
commitment is on a retirement path and raises a warning:

- The condition is: the current SKU is covered by a Reserved Instance **or** a Savings Plan (from the
  Retail Prices signals) **and** the SKU is on a retirement path (per-resource Azure Advisor signal
  or an official SKU-family announcement from Microsoft Learn or Release Communications).
- For each affected VM a `WARN` is logged and the note — with the retirement date (the "when") and the
  commitment type (Reserved Instance and/or Savings Plan) — is appended to the **Validation** column of
  the detail table.
- The dashboard shows the number of retiring VMs covered by a commitment (`CommitmentImpactCount`) in
  the info strip, pointing to the Validation column for the per-VM detail.
- The financial effect is not quantified: it is an **attention flag**, not a number.

Separately, the report includes a **Reserved Instance Cutoff Planning** Public Preview sidecar for the
stop on new purchase/renewal of Reserved VM Instances for selected legacy families. Its source is the
official commercial notice already returned by the configured Release Communications query. This sidecar:

- scans standalone VMs, Azure Batch pools and VM Scale Sets;
- extracts the cutoff date and affected family names from the live notice, then matches normal Azure
  VM size fields against those announced families;
- summarizes the HTML view by affected VM-size family and resource count; per-resource detail remains
  in the structured CSV/JSON outputs;
- flags both retirement-wave families and RI-cutoff-only families such as Dv3/Dsv3/Ev3/Esv3;
- remains outside retirement counts, remediation waves, CSV backlog and cost calculations.

It is a FinOps planning signal only. It does not prove that a real tenant reservation exists, does not
read reservation inventory, does not calculate utilization/coverage/expiry, and does not imply VM
shutdown. If the analyzed subscriptions have no active RI purchases, this section should be read as
roadmap/planning context only: no direct reservation renewal action is implied by the report itself.

## Remediation wave plan

The HTML dashboard includes a **deterministic remediation wave plan** (`Build-RemediationPlan`) that
assigns every retirement-path VM to exactly one wave, so the wave counts always sum to the retirement
path total (an invariant enforced before the HTML is written). Assignment combines two independent
floors and selects the lower wave number (the more urgent/governed lane):

| Axis | Facts | Floor |
|---|---|---|
| **Urgency** | `RetirementRiskLevel = Critical` | **W0** |
| **Urgency** | `RetirementRiskLevel = High` | **W1** |
| **Urgency** | `RetirementRiskLevel = Medium` or `Watch` | **W4** |
| **Complexity** | `GenerationChange` or normalized cross-family move | **W3** |
| **Complexity** | sensitive workload with no generation/cross-family boundary | **W2** |
| **Complexity** | ordinary same-generation, same-family move | **W4** |

For example, `High + Gen1->Gen2` resolves to `min(W1, W3) = W1`; a medium-risk sensitive Domain
Controller that crosses the generation boundary resolves to `min(W4, W3) = W3`. W3 is the
architecture-validation lane, not a statement that the workload is less delicate than W2. Reason
codes retain every applicable fact, including sensitive workload role, even when another floor selects
the final wave. Each entry carries:

- a **rationale** aligned with the normalized same-family/cross-family fact while preserving the source
  `RecommendationBasis` in structured data, plus a Gen1→Gen2 caution when it applies;
- a deterministic **cost caveat** (`Get-RemediationCostFlag`): a delta above **+30%** that also crosses
  VM families is flagged as a *compute-class change* (e.g. burstable/basic → compute-optimized), **not**
  a pure price rise — validate the workload truly needs sustained CPU;
- a class-conditioned **checklist** (`Get-RemediationChecklist`): an always-on quota/capacity check plus
  conditional items for generation change, cross-family, sensitive workload and RI/SP coverage.

No AI is involved — the plan is a pure function of the report facts.

The fail-closed plan guard recomputes the expected floor from each row's raw facts before accepting its
wave. The Pester review suite separately pins the full `4 x 2 x 2 x 2` risk/sensitive/generation/family
matrix to literal expected floors, so a shared-helper defect cannot silently satisfy both routing and
guard. Legacy Premium Storage names such as `DS2_v2` are normalized to their architectural family
(`D`), keeping `DS2_v2 -> D2ads_v7` same-family while genuine moves such as `A -> F` remain cross-family.

## Coverage and disclaimer

The report is **not an official Microsoft tool** and its coverage is not exhaustive. The HTML output
makes this explicit with a disclaimer banner (top and footer) and an **Analysis Coverage** section:

- **What it covers:** Azure Advisor recommendations in the *Reliability &rarr; Service Upgrade and
  Retirement* subcategory, across all SKU families (no fixed list), with retirement date / retiring
  feature when available, plus Microsoft Learn (Stream B) and deterministic Microsoft Release
  Communications (Stream C) SKU-family exposures. Public Preview: Azure Batch pools and VM Scale Sets
  are scanned as separate resources and matched by their normal Azure VM size fields (`vmSize` and
  `sku.name`); Reserved VM Instance cutoff planning is derived from the commercial notice in Release
  Communications.
- **What it does NOT cover / manual verification required:**
  - Retirements present **only in Azure Service Health** (not emitted by Advisor) &mdash; check
    *Service Health &rarr; Health advisories* and the *Impacted Resources* tab.
  - Services not yet covered by the *Service Retirement Workbook* (partial coverage) &mdash; verify in
    *Advisor &rarr; Workbooks &rarr; Service Retirement*.
  - Public announcements without a mapping to a resource &mdash; check *Azure Updates*.
  - Service Health retention in Azure Resource Graph is 90 days: reconcile within that window.

Always validate compatibility, quota and cost before any migration decision.

## Parameter reference

All parameters are optional (`Mandatory = $false`). Below is the full list grouped by area, with type,
default and effect.

### Scope and authentication

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SubscriptionIds` | `string[]` | (all enabled subscriptions of the tenant) | Subscriptions to analyze. If omitted, uses all `Enabled` subscriptions of the effective tenant. |
| `-TenantId` | `string` | (tenant of the current Az context) | Target tenant. If the current context is on a different tenant, forces a new sign-in. |
| `-UseDeviceAuthentication` | `switch` | off | Uses the device code flow for `Connect-AzAccount` (useful without an interactive browser). |
| `-Regions` | `string[]` | (detected from the VM inventory) | Restricts the analysis to the specified regions. If omitted, automatically detects the regions from the VMs found. |
| `-OutputRoot` | `string` | `.\out` | Root folder for outputs; each run creates `out/<timestamp>/`. |

### Recommendation engine (scoring & candidates)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-TopCandidates` | `int` | `3` | Maximum number of candidate SKUs (Option A/B/C…) proposed for each VM. |
| `-MaxRecommendedVcpuIncreaseRatio` | `double` | `1.5` | Maximum allowed vCPU increase ratio on normal candidate paths (1.5 = +50%). The bounded burstable path permits the minimum 1-to-2-vCPU step. The final retirement fallback may exceed this ceiling only to provide a hard-compatible non-retiring alternative and exposes the upsize for validation. |
| `-MaxRecommendedMemoryIncreaseRatio` | `double` | `1.5` | Maximum allowed memory increase ratio on normal candidate paths. The final retirement fallback may exceed it only to avoid leaving a retiring SKU without a hard-compatible alternative. |
| `-MaxRecommendedCostIncreasePercent` | `double` | `20` | Maximum tolerated Retail cost increase on normal candidate paths. For a retiring SKU's final governed fallback, cost affects ranking and disclosure but does not override availability, architecture, capability or performance safety. |
| `-MinRecommendedPerfRatio` | `double` | `0.95` | Minimum performance (index) ratio of the candidate relative to the current SKU. Applied to same-family, same-shape, burstable and cross-family candidates. |
| `-EquivalentVcpuTolerancePercent` | `double` | `15` | vCPU percentage tolerance to consider a candidate "equivalent". |
| `-EquivalentMemoryTolerancePercent` | `double` | `20` | Memory percentage tolerance to consider a candidate "equivalent". |
| `-AllowArchitectureChange` | `switch` | off | Relaxes matching for non-ARM architecture metadata differences. ARM remains a hard boundary: the engine never proposes x64↔Arm64 migration. |

### Data sources (Advisor, Retail, SKU REST)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipAdvisor` | `switch` | off | Skips collecting Azure Advisor recommendations (reduces the stages by one). |
| `-SkipRetailApi` | `switch` | off | Skips the Azure Retail Prices API: no cost delta and no RI/Savings Plan signals. |
| `-Currency` | `string` | `USD` | ISO currency code passed to the Azure Retail Prices API (e.g. `USD`, `EUR`, `GBP`); the retail delta and prices are expressed in this currency. The cache key includes the currency. |
| `-RetailExpectedPages` | `int` | `180` | Expected number of pages (floor) for the Retail API; if not set, it is estimated from history. |
| `-RetailMaxRetries` | `int` | `5` | Maximum number of retry attempts on Retail calls. |
| `-RetailRetryBaseDelaySec` | `int` | `1` | Base delay (s) for the exponential backoff of Retail retries. |
| `-RetailRetryMaxDelaySec` | `int` | `30` | Maximum delay (s) for the Retail retry backoff. |
| `-RetailMaxParallelRequests` | `int` | `6` | Degree of parallelism for Retail requests (PS7+). |
| `-RetailApiTimeoutSec` | `int` | `15` | Timeout (s) per single Retail request. |
| `-UseResourceSkusRestApi` | `bool` | `$true` | Uses the Resource SKUs REST API for the catalog; with `$false` uses `Get-AzComputeResourceSku`. |
| `-ResourceSkusApiVersion` | `string` | `2026-03-02` | Azure Resource Manager API contract version used only for `Microsoft.Compute/skus`. It is not a report as-of date, retirement cutoff date or RI cutoff date. |
| `-BatchManagementApiVersion` | `string` | `2025-06-01` | Azure Batch Management API contract version used to list pools under each Batch account when Resource Graph does not expose pool child resources. |
| `-IncludeExtendedLocationsInSkuApi` | `bool` | `$true` | Includes extended locations in the SKU catalog query. |

Change `-ResourceSkusApiVersion` only if the Resource SKUs REST call fails because the selected API
version is not supported in the target cloud/subscription, or if a newer Compute SKUs API version is
needed for fields exposed by Azure. Changing it can affect SKU catalog shape, availability and
restriction metadata, but it does not change retirement-source logic or remediation-wave rules.

### Retirement (LIVE-only)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-UseOfficialRetirementList` | `bool` | `$true` | Enables Stream B (Microsoft Learn markdown, SKU-family). |
| `-UsePortalRetirementSource` | `bool` | `$true` | Enables Stream A (Azure Advisor via ARG, per-resource). |
| `-RequireLiveRetirementSource` | `bool` | `$false` | If `$true` and all enabled live sources fail, the script terminates with an error instead of proceeding with partial data. |
| `-UseReleaseCommunicationsApi` | `bool` | `$true` | Enables Stream C (Microsoft Release Communications API). Structured retirement records that deterministically match a tenant SKU family are authoritative findings; unmatched notices remain Coverage context. |
| `-ReleaseCommunicationsApiUrl` | `string` | Microsoft Release Communications retirement-and-compute filter | Retirement-only JSON API query restricted to Azure Dedicated Host, AKS, Azure Linux, Batch, Linux/Windows Virtual Machines, Virtual Machine Scale Sets and Virtual Machines. The verified default currently returns 78 records. Change only for testing or cloud-specific routing. |
| `-ReleaseCommunicationsLookbackMonths` | `int` | `0` | History window for API notices rendered in the Coverage tab. `0` includes all records returned by the configured API query; a positive value limits records by their API `modified` timestamp. |
| `-ReleaseCommunicationsCacheTtlHours` | `int` | `24` | Freshness window for the complete retirement index. A stale index triggers a modified-since query and refreshes only changed/new per-ID details. Uses the shared persistent cache controls and `-ForceRefreshCache`. |
| `-AdvisorRetirementTypeIdBlocklist` | `string[]` | 2 GUIDs (Dependency Agent / VM Insights Map) | Advisor Type IDs that are monitoring lifecycle signals and must **never** become compute SKU retirements. |
| `-AdvisorRetirementNameBlockPattern` | `string` | agent/monitoring regex | Fallback text match (Option B) to exclude agent/monitoring recommendations not present in the blocklist. |

### Persistent cache

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-UsePersistentCache` | `bool` | `$true` | Enables local file caches for the SKU catalog, Retail prices/commitment signals and Release Communications index/details. |
| `-CacheRoot` | `string` | `<OutputRoot>\cache` | Cache folder; if omitted uses the `cache` subfolder of `OutputRoot`. |
| `-SkuCacheTtlHours` | `int` | `168` | TTL (hours) of the SKU catalog cache (168 = 7 days). |
| `-RetailCacheTtlHours` | `int` | `24` | TTL (hours) of the Retail prices cache. |
| `-ForceRefreshCache` | `switch` | off | Forces the refresh of **all** caches (SKU catalog, Retail prices, RI/SP signals and Release Communications index/details). |

### Logging

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DetailedRunLog` | `bool` | `$true` | Logs the detailed `API_CALL|...` traces in the run log (more concise console, full file). |

## Generated outputs

Each run creates a timestamped folder under `out/<timestamp>/` unless `-OutputRoot` is changed. The
folder contains the human report, structured data files and audit logs for the same run.

| File | Primary audience | How to use it |
|---|---|---|
| `sku_modernization_report.html` | CXO, CSA/Engineer, PM, FinOps | Open in a browser. This is the main self-contained report with left-side audience views: Executive Overview, CSA / Engineer, Project Plan, FinOps and Coverage. Use it for review meetings and PDF export. |
| `sku_modernization_report.csv` | CSA/Engineer, FinOps | Flat per-VM retirement-path dataset, including CPU-vendor decision fields. Use in Excel/Power BI for filtering by VM, region, current SKU, recommended SKU, wave, cost delta and validation notes. |
| `sku_modernization_report.json` | Automation, audit, downstream tooling | Full structured report data with top-level `ReportVersion`, recommendation `Items` (including CPU-vendor decision fields), sidecar previews and `ReleaseCommunicationContext` status/results. Use when another script, dashboard or pipeline needs report data without scraping HTML. |
| `migration_backlog_items.csv` | PM, delivery lead | Work-item/backlog-friendly extract for remediation planning. Import into Azure DevOps, Planner, Jira or a spreadsheet to track owner, wave, target SKU and execution status. |
| `advisor_hints.json` | CSA/Engineer, troubleshooting | Raw Advisor-related hints captured during analysis. Use to verify why a row was treated as Advisor-confirmed or to reconcile with Azure Advisor/Workbook views. |
| `api_calls_log.csv` | Operations, audit | Tabular API-call trace with provider, request metadata and success/failure state. Use for quick filtering and evidence collection. |
| `api_calls_log.json` | Automation, audit | Structured version of the API-call trace. Use when joining run telemetry with other logs or pipeline output. |
| `run_activity.log` | Troubleshooting, delivery readiness | Human-readable execution log. Check source health, warnings, delivery-readiness gate output, cache usage and failure details. |

Recommended consumption pattern:

1. Open `sku_modernization_report.html` first and review the Executive Overview.
2. Use the CSA / Engineer tab for implementation details and sidecar remediation.
3. Use the Project Plan tab to sequence waves and create delivery work items.
4. Use the FinOps tab plus `sku_modernization_report.csv` for cost and commitment review.
5. Use Coverage and `run_activity.log` before sharing the report externally, especially if source
  health is `WARN`.

## Notes

- LIVE-only retirement can produce a `WARN` source-health state when not all **retirement findings**
  are covered by live sources; with `-RequireLiveRetirementSource $true` the script terminates if all
  enabled live sources fail. A "retirement finding" is a VM actually on a retirement path (live
  Advisor, Learn or Release Communications signal), **not** every analyzed VM: a VM with no retirement
  signal does not lower the source-health ratio.
- **OS-aware prices.** For the same SKU the Retail API exposes distinct meters for Windows and Linux
  (the Windows meter is more expensive). The price used for each VM respects the inventory's `OsType`,
  falling back to the cheapest meter when the specific meter is not available.

## Robustness (paging and cache)

- **Resource Graph paging via SkipToken.** All ARG queries (VM inventory, Advisor retirement signals,
  Dependency Agent presence) page through the `SkipToken` cursor instead of the numeric `-Skip`, which
  on large tenants is unreliable/capped and can truncate results.
- **Memory-bounded Compute SKU retrieval.** The ARM Resource SKUs catalog is queried one requested region
  at a time and each page is compacted immediately. If extended-location metadata exhausts available
  memory, the script retries the same region-scoped query without that optional metadata.
- **Nested progress for long stages.** Long-running inventory, catalog, pricing and source operations show
  child progress under the main phase, including the current region, subscription or API page. A page number
  identifies the current paginated API response; it is not a count of Azure resources.
- **Prices/commitment cache only if complete.** The Retail prices cache and the RI/SP signals cache are
  saved **only** if the download completed across all requested regions. If a cursor aborts midway, the
  partial map is never persisted (avoids understating coverage on subsequent runs); a `WARN` is logged.
  For RI/SP, a Savings Plan filter rejected with `400` (not supported for that scope) is treated as an
  unavailable signal and does not block the cache.

## Consistency guardians and delivery readiness

Before the HTML is written, the report is validated by a layered set of guardians. Each one throws (or
downgrades to `WARN`) on a specific class of defect, so a wrong number never reaches the client.

### Guardian layers

- **`Get-RetirementSourceHealth`** — grades live-source coverage of the retirement findings:
  - `OK`: every retirement finding is backed by a live source (Advisor ARG / Microsoft Learn / Microsoft Release Communications).
  - `WARN`: at least one live source is available but coverage is incomplete (logged, non-blocking).
  - `BLOCK`: no live source available — report generation is refused.
  - **Denominator = retirement findings only.** A "finding" is a VM actually on a retirement path
    (live Advisor/Learn/Release Communications signal). A VM with no retirement signal is *not* counted, so it cannot inflate
    the "stale/unknown" ratio or produce a false `WARN`.
- **`Assert-ReportConsistency`** — hard invariants that throw on failure:
  - `AdvisorConfirmed + SkuFamily == RetireCount` (retirement-path quadrature).
  - `CostCovered + CostMissing == RetireCount`.
  - `SkuChangeWithGenChange + SkuChangeWithoutGenChange == recommended-SKU rows`.
- **`Assert-CountsUnchangedAfterReleaseCommunicationCoverage`** — hard rendering invariant:
  - Retirement counts, source split, monitoring count and remediation wave totals must be identical
    before and after building the Coverage section, otherwise report generation stops.
  - Stream C findings are computed earlier, alongside the other retirement sources; this guard only prevents
    the later Coverage rendering pass from mutating them.
  - Monitoring presence counters reconcile to the distinct monitoring VM count; no duplicate monitoring
    `ResourceId`; a monitoring row can be `Confirmed` only from a Dependency-Agent ARG detection.
  - **`AdvisorConfirmed == advisor rows with a real Advisor recommendation ID`** — every
    advisor-confirmed row must trace to a real Rec ID, so the count cannot be inflated.
  - **Pricing OS invariant:** a Windows VM with an available Windows meter must be priced on the
    Windows basis (never silently priced as Linux).

### Delivery-readiness gate (`Assert-DeliveryReady`)

The final gate is the machine version of the one-page delivery checklist. It runs after the guardians
above and re-verifies their outcomes plus the "10-second" manual checks in one place, logging an
auditable `DELIVERY CHECKLIST` block and a single `DELIVERY READY` / `DELIVERY NOT READY` verdict. It
throws on any blocking failure, so a non-defensible report is never written.

**Section 2 — Run (read from `run_activity.log`):**

- `STREAM A OK=True` (live Advisor ARG).
- `STREAM B succeeded. Series: N` with `N > 0` (live Learn markdown).
- No `Retirement source health = BLOCK`.
- No `Status property not found` defect signature.
- `Assert-ReportConsistency` did not throw (implicit — the gate runs after it).

**Section 3 — Post-run (from facts / rows):**

- **Money-line:** the sum of the per-row retail deltas equals the Executive total.
- **Quadrature:** `RetireCount == AdvisorConfirmed + SkuFamily`.
- **Monitoring separate:** monitoring VMs are counted *outside* the retirement total.
- **OS canary:** every Windows VM with a Windows meter is priced on the Windows basis.
- **RI/SP flag:** `CommitmentImpactCount` reconciles with the flagged retirement rows.
- **Provenance:** live retirement source + as-of date on live retirement rows.

Blocking (`FAIL`) checks throw; `WARN` checks (incomplete-but-present live coverage,
missing as-of, unreadable log) surface in the log without blocking delivery.

### Reading the Stream A entry counter

The run log line `Load-Retirements: STREAM A succeeded. Per-resource entries (pre-inventory join): N`
reports the number of **real Advisor retirements deduped by resource ID across the whole tenant**,
*before* they are joined against the analyzed inventory. This value is therefore a **superset** of the
report's `AdvisorConfirmed`: only the entries whose resource ID is also in the analyzed inventory become
advisor-confirmed rows. Example: `Per-resource entries (pre-inventory join): 8` with
`AdvisorConfirmed = 2` is correct — 8 tenant-wide advisor-flagged VMs, 2 of them in scope. The two
numbers are **not** expected to be equal.

### Reading the Stream C log entries

Stream C emits three explicit lifecycle entries in `run_activity.log`:

- `Attempting STREAM C` marks the start of Microsoft Release Communications API ingestion.
- `STREAM C API succeeded` reports returned notices, cache mode, index size, updated details and pages.
- `STREAM C succeeded` reports tenant-matched SKU families, families added to retirement evidence and
  matches superseded by Microsoft Learn. A non-zero matched count with `added=0` is valid when Learn
  already covers every matching family, because Stream B retains priority for duplicate family evidence.

The later `Release Communications API coverage` entry reports how all returned notices were classified
for the Coverage view; those Coverage counts are not additional retirement-path resources.
