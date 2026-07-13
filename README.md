# Azure SKU Modernization Report

**Current version:** `v0.4`

> **See the output first:** open the rendered anonymized dashboard:
> [Rendered HTML demo](https://ripom.github.io/Azure-SKU-Modernization-Report/examples/Azure-SKU-Modernization-Report-example.html)
> ([source HTML](examples/Azure-SKU-Modernization-Report-example.html)).
> It shows the generated report experience without publishing real Azure resource names.

## Quick navigation

- [Prerequisites](#prerequisites)
- [Minimum Azure permissions](#minimum-azure-permissions)
- [Command syntax](#command-syntax)
- [Common runs](#common-runs)
- [How the script works](#how-the-script-works)
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
  - No hardcoded fallback list.
- **Retirement vs upgrade split.** The Advisor subcategory contains both genuine retirements and
  pure upgrade prompts. A signal is treated as a **retirement** only when it carries a retirement
  date; upgrade-only signals (no date) are captured separately and are **not** counted on the
  retirement path.
- **Not an official Microsoft tool.** The report is indicative and may contain errors or omissions;
  it guides and orients the analysis but does not replace authoritative sources. Every result must be
  verified in Azure Advisor, Service Health and the Azure Retirement Workbook. The HTML report carries
  an explicit disclaimer and an **Analysis Coverage** section describing what is and is not covered.
- **Separate monitoring lifecycle.** Dependency Agent / VM Insights Map retirement is tracked in a
  separate section and does not contribute to the compute SKU retirement count.
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
  (`2026-07-01`). This is a FinOps planning signal, not a VM shutdown signal, and it does **not**
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

## Prerequisites

- PowerShell 7+
- Azure sign-in already completed (`Connect-AzAccount`)
- Reader role on the analyzed subscriptions

## Minimum Azure permissions

The script is read-only. It does not resize VMs, change VMSS models, change Batch pools, create
reservations, or modify Azure resources. The minimum practical permission is **Reader** on every
subscription you want to analyze.

Recommended assignment:

| Scope | Minimum role | Why it is needed |
| --- | --- | --- |
| Each analyzed subscription | `Reader` | Lets the script enumerate VMs, VM Scale Sets, Batch accounts, Batch pools, Advisor recommendations, and Compute SKU availability through Azure Resource Graph and ARM read APIs. |
| Management group containing the analyzed subscriptions | `Reader` | Optional convenience when you want the same read access inherited by many subscriptions. Use only if your governance model allows it. |
| Individual resource group or resource | `Reader` | Works only for partial, resource-scoped visibility. Use this only when you intentionally want a limited report; subscription-level Reader is recommended for complete retirement and Advisor coverage. |

In simple terms: assign `Reader` at the **subscription** scope for each subscription included in
`-SubscriptionIds`. If you pass multiple subscriptions, the signed-in identity needs Reader on all of
them. If you omit `-SubscriptionIds`, the script scans the enabled subscriptions visible to the current
Azure context, so the output is only as complete as the subscriptions the identity can read.

Data-source notes:

- **VM inventory, VMSS inventory, Batch accounts and Batch pools:** require Azure read access on the
  target resources. Subscription-level `Reader` is the safest minimal scope for complete inventory.
- **Azure Advisor retirement signals:** require read access at the subscription scope to reliably see
  subscription recommendations. If Advisor is unavailable or intentionally skipped with `-SkipAdvisor`,
  the report can still use Microsoft Learn SKU-family retirement data, but it loses per-resource
  Advisor confirmation.
- **Compute Resource SKUs API:** uses ARM read access in one target subscription to understand regional
  SKU availability and restrictions.
- **Azure Retail Prices API and Microsoft Learn retirement data:** public sources; they do not require
  tenant-specific Azure RBAC.

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

Use this mode when a report must not be produced if both live retirement sources are unavailable.

## How the script works

At a high level the script follows this deterministic pipeline:

1. **Inventory:** reads standalone VMs from Azure Resource Graph. Public Preview sidecars also read
  Azure Batch pools and VM Scale Sets as separate resource types.
2. **Retirement sources:** loads live retirement signals from Azure Advisor Resource Graph and the
  Microsoft Learn SKU-family source. Upgrade-only Advisor prompts without retirement dates are not
  counted as retirements.
3. **SKU and price catalog:** loads compute SKU metadata plus Retail Prices data, using local caches
  when complete and fresh.
4. **Recommendation engine:** selects compatible target SKUs and records generation, architecture,
  quota/capacity and validation caveats.
5. **Classification:** builds standalone VM retirement facts, remediation waves and sidecar previews
  for Batch, VMSS and RI cutoff planning.
6. **Validation gates:** checks source health, fact reconciliation, monitoring separation, OS-aware
  pricing and delivery readiness before writing the report.
7. **Output generation:** writes CSV, JSON, HTML and logs into the timestamped output folder.

The HTML is a presentation layer over computed facts. It does not invent new counts or reclassify rows.

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

The **Legend** control remains in the sidebar and opens a closeable guide explaining core concepts,
wave meanings, decision sections, detail-table fields, cost caveats and validation expectations.

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
  Retail Prices signals) **and** the SKU is on a retirement path (official Microsoft Learn
  announcement or per-resource Advisor signal).
- For each affected VM a `WARN` is logged and the note — with the retirement date (the "when") and the
  commitment type (Reserved Instance and/or Savings Plan) — is appended to the **Validation** column of
  the detail table.
- The dashboard shows the number of retiring VMs covered by a commitment (`CommitmentImpactCount`) in
  the info strip, pointing to the Validation column for the per-VM detail.
- The financial effect is not quantified: it is an **attention flag**, not a number.

Separately, the report includes a **Reserved Instance Cutoff Planning** Public Preview sidecar for the
`2026-07-01` stop on new purchase/renewal of Reserved VM Instances for selected legacy families. This
sidecar:

- scans standalone VMs, Azure Batch pools and VM Scale Sets;
- matches their normal Azure VM size field against the curated cutoff family list;
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
path total (an invariant enforced before the HTML is written). Assignment is **first-match** — the
first rule that matches wins, so a VM is never double-counted:

| Wave | Rule (first match wins) |
|---|---|
| **0 — Urgent retirement deadline** | `RetirementRiskLevel` is `Critical` or `High` |
| **1 — Advisor-confirmed sensitive workloads** | source gate `LiveAdvisorArg` **and** `SensitiveWorkload` |
| **2 — Sensitive workload, same-generation resize** | `SensitiveWorkload` **and not** `GenerationChange` |
| **3 — Cross-family Gen1→Gen2** | `GenerationChange` **and** the target changes VM family |
| **4 — Low-complexity same-generation resize** | everything else |

Order matters and resolves the ambiguous rows without double counting: an Advisor-confirmed sensitive
Domain Controller that also changes generation lands in **Wave 1** (not Wave 3), and a `High`-risk row
lands in **Wave 0** (not Wave 3) even if it is cross-family. Each entry carries:

- a **rationale** built from the row's `RecommendationBasis` (e.g. *burstable continuity*, *cross-family
  migration*, *same-shape refresh*), plus a Gen1→Gen2 caution when it applies;
- a deterministic **cost caveat** (`Get-RemediationCostFlag`): a delta above **+30%** that also crosses
  VM families is flagged as a *compute-class change* (e.g. burstable/basic → compute-optimized), **not**
  a pure price rise — validate the workload truly needs sustained CPU;
- a class-conditioned **checklist** (`Get-RemediationChecklist`): an always-on quota/capacity check plus
  conditional items for generation change, cross-family, sensitive workload and RI/SP coverage.

No AI is involved — the plan is a pure function of the report facts.

### Worked example (9 retirement-path VMs)

With the first-match rules above, this distribution is deterministic and mutually exclusive:

- Wave 0: `1` VM (`test`) because risk is `High` (deadline < 24 months)
- Wave 1: `1` VM (`ric-vm-dc`) because it is `LiveAdvisorArg` + sensitive
- Wave 2: `2` VMs (`ric-vm-adcon`, `vm-adfs`) because they are sensitive and same-generation
- Wave 3: `3` VMs (`ric-vm-0-lan1`, `ric-vm-0-lan2`, `ric-vm-1-lan1`) because they are cross-family Gen1->Gen2
- Wave 4: `2` VMs (`contorsoclient`, `vm3-win-1`) because they fall in none of the earlier classes

Result: `1 + 1 + 2 + 3 + 2 = 9`, which reconciles with the retirement path total.

Two first-match edge cases are intentionally resolved by order:

- `ric-vm-dc` is generation-changing and cross-family, but it stays in **Wave 1** (Advisor-confirmed + sensitive) and is not pushed to Wave 3.
- `test` is cross-family and generation-changing, but it stays in **Wave 0** due to `High` urgency and is not pushed to Wave 3.

This is why changing rule order changes outcomes.

## Coverage and disclaimer

The report is **not an official Microsoft tool** and its coverage is not exhaustive. The HTML output
makes this explicit with a disclaimer banner (top and footer) and an **Analysis Coverage** section:

- **What it covers:** Azure Advisor recommendations in the *Reliability &rarr; Service Upgrade and
  Retirement* subcategory, across all SKU families (no fixed list), with retirement date / retiring
  feature when available, plus Microsoft Learn SKU-family exposures (Stream B). Public Preview: Azure
  Batch pools and VM Scale Sets are scanned as separate resources and matched by their normal Azure VM
  size fields (`vmSize` and `sku.name`); Reserved VM Instance cutoff planning is matched from a curated
  FinOps family list.
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
| `-MaxRecommendedVcpuIncreaseRatio` | `double` | `1.5` | Maximum allowed vCPU increase ratio for a candidate (1.5 = +50%). |
| `-MaxRecommendedMemoryIncreaseRatio` | `double` | `1.5` | Maximum allowed memory increase ratio for a candidate. |
| `-MaxRecommendedCostIncreasePercent` | `double` | `20` | Maximum tolerated retail cost increase percentage for a candidate. |
| `-MinRecommendedPerfRatio` | `double` | `0.95` | Minimum performance (index) ratio of the candidate relative to the current SKU. |
| `-EquivalentVcpuTolerancePercent` | `double` | `15` | vCPU percentage tolerance to consider a candidate "equivalent". |
| `-EquivalentMemoryTolerancePercent` | `double` | `20` | Memory percentage tolerance to consider a candidate "equivalent". |
| `-AllowArchitectureChange` | `switch` | off | Allows candidates with a different CPU architecture (x64↔Arm64); by default it stays within the same architecture. |

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
| `-RequireLiveRetirementSource` | `bool` | `$false` | If `$true` and **both** live sources fail, the script terminates with an error instead of proceeding with partial data. |
| `-AdvisorRetirementTypeIdBlocklist` | `string[]` | 2 GUIDs (Dependency Agent / VM Insights Map) | Advisor Type IDs that are monitoring lifecycle signals and must **never** become compute SKU retirements. |
| `-AdvisorRetirementNameBlockPattern` | `string` | agent/monitoring regex | Fallback text match (Option B) to exclude agent/monitoring recommendations not present in the blocklist. |

### Persistent cache

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-UsePersistentCache` | `bool` | `$true` | Enables the local file cache for the SKU catalog and Retail prices. |
| `-CacheRoot` | `string` | `<OutputRoot>\cache` | Cache folder; if omitted uses the `cache` subfolder of `OutputRoot`. |
| `-SkuCacheTtlHours` | `int` | `168` | TTL (hours) of the SKU catalog cache (168 = 7 days). |
| `-RetailCacheTtlHours` | `int` | `24` | TTL (hours) of the Retail prices cache. |
| `-ForceRefreshCache` | `switch` | off | Forces the refresh of **all** caches (SKU catalog + Retail prices + RI/SP signals). |

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
| `sku_modernization_report.csv` | CSA/Engineer, FinOps | Flat per-VM retirement-path dataset. Use in Excel/Power BI for filtering by VM, region, current SKU, recommended SKU, wave, cost delta and validation notes. |
| `sku_modernization_report.json` | Automation, audit, downstream tooling | Full structured report data. Use when another script, dashboard or pipeline needs the report facts without scraping HTML. |
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
  are covered by live sources; with `-RequireLiveRetirementSource $true` the script terminates if both
  live sources fail. A "retirement finding" is a VM actually on a retirement path (live Advisor/Learn
  signal), **not** every analyzed VM: a VM with no retirement signal does not lower the source-health
  ratio.
- **OS-aware prices.** For the same SKU the Retail API exposes distinct meters for Windows and Linux
  (the Windows meter is more expensive). The price used for each VM respects the inventory's `OsType`,
  falling back to the cheapest meter when the specific meter is not available.

## Robustness (paging and cache)

- **Resource Graph paging via SkipToken.** All ARG queries (VM inventory, Advisor retirement signals,
  Dependency Agent presence) page through the `SkipToken` cursor instead of the numeric `-Skip`, which
  on large tenants is unreliable/capped and can truncate results.
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
  - `OK`: every retirement finding is backed by a live source (Advisor ARG / Microsoft Learn).
  - `WARN`: at least one live source is available but coverage is incomplete (logged, non-blocking).
  - `BLOCK`: no live source available — report generation is refused.
  - **Denominator = retirement findings only.** A "finding" is a VM actually on a retirement path
    (live Advisor/Learn signal). A VM with no retirement signal is *not* counted, so it cannot inflate
    the "stale/unknown" ratio or produce a false `WARN`.
- **`Assert-ReportConsistency`** — hard invariants that throw on failure:
  - `AdvisorConfirmed + SkuFamily == RetireCount` (retirement-path quadrature).
  - `CostCovered + CostMissing == RetireCount`.
  - `SkuChangeWithGenChange + SkuChangeWithoutGenChange == recommended-SKU rows`.
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
