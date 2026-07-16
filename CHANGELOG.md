# Changelog

## Unreleased

## v0.11 - 2026-07-16

- Fixed single-subscription scope handling. A lone `-SubscriptionIds` result now remains array-shaped, so
  initial context selection uses the complete subscription GUID instead of indexing its first character.
- Added defensive tenant isolation to subscription discovery. Enabled subscriptions returned by Az.Accounts
  are accepted only when their `TenantId` matches the effective tenant.
- Reused existing Az PowerShell authentication without unnecessary login prompts. The script now evaluates
  saved contexts for the effective tenant, skips stale or unusable entries, and selects the first context that
  can retrieve enabled subscriptions.
- Validated the currently active context as well as inactive saved contexts. If no saved context is operational,
  the script falls back to `Connect-AzAccount` instead of continuing with an unusable token and reporting an
  empty subscription scope.
- Azure Lighthouse delegated-subscription scenarios have not been tested in v0.11 and are not guaranteed;
  tenant isolation may exclude subscriptions whose owning tenant differs from the effective tenant.
- Updated authentication and scope regressions; the Pester 5.7.1 baseline now contains 178 passing tests.

## v0.10 - 2026-07-15

- Fixed Resource SKUs REST retrieval for a single analyzed region. PowerShell no longer unwraps the one-item
  query-target collection and throws on `.Count` under strict mode before making the REST request.
- Kept VM, Batch pool and VMSS Resource Graph results array-shaped at the main workflow call sites. Added
  one-result regressions for those inventories and Retail pricing, complementing the existing Compute SKU,
  Advisor, commitment and Release Communications query coverage.

## v0.9 - 2026-07-15

- Replaced hard parity gates for local temporary storage, maximum NICs and maximum data disks with explicit
  per-row validation warnings. These SKU ceilings no longer force an oversized target when actual usage is
  unknown.
- Changed candidate ranking to prioritize the lowest validated Retail price within the same family. For
  cross-family and retirement fallback candidates, proportional vCPU/memory proximity is evaluated first and
  Retail price breaks equally close shapes.
- Added warning details for loss or type change of resource/cache/local NVMe storage and reductions in maximum
  NIC or data-disk counts; the same warnings appear in the checklist and migration risks.
- Added structured target-equivalence output (`CandidateEquivalenceStatus`, details and selection reason) and
  surfaced it in report facts, remediation checklists and the HTML engineer table. Non-equivalent targets list
  exact current-to-target differences for compute, storage, disks, NICs and networking capabilities.
- Added a fixed nearest-fit disclaimer and per-row fit-confidence summary to the HTML engineer view. The report
  now explicitly requires validation of family/workload profile, burstability, CPU, storage, disk/NIC limits,
  licensing and application behavior before migration. Structured equivalence details now also flag known
  commercial workload-profile and Intel/AMD changes, including general-purpose to compute-optimized moves.
- Deduplicated the engineer view so each fact appears once per row: the selection rationale is shown only under
  `Why selected`, the capability differences only under `Compared capabilities`, and the recommendation note now
  carries only the additional migration cautions (generation, CPU vendor, sensitive workload). The Validation
  cell no longer repeats the full difference list.
- Added the normalized SKU name as the final candidate-ranking tie-break so equal candidates remain stable when
  Azure API/catalog input order changes.
- Added explicit correctness gates for byte-identical target mappings across repeated identical runs.
- Added family-level successor affinity for basic A-series VMs without hardcoding individual SKU matches: B is
  preferred first, D second, and generic cross-family candidates only after both families fail the existing hard
  and cost gates. Tests pin `A1_v2 -> B2als_v2 -> W3` and D fallback when B exceeds the cost ceiling.
- Updated the nine-row wave fixture to the current live 1/2/4/2 distribution instead of the obsolete `N/A`
  A-series state.
- Removed five redundant source-text assertions already covered by configurable-threshold behavior, the full
  32-case floor matrix and fail-closed planner tests. The suite now favors observable behavior over brittle
  function-definition matching.
- Added named literal floor pins for the live `test`, `ric-vm-dc` and `A1_v2 -> B2als_v2` regressions, plus
  an explicit guard keeping date thresholds out of the fact-to-floor resolver. A temporary-copy mutation check
  confirmed the floor matrix fails when cross-family complexity is incorrectly changed from W3 to W4.
- Re-audited the regression suite and replaced the standalone Savings Plan source-text check with a behavioral
  Retail request test. Removed a redundant renderer-definition assertion already covered by generated HTML.
- Added regressions proving that A-family recommendations reach generic fallback when both preferred successor
  families fail hard gates, that recommendation wording does not route waves, and that the RI/SP impact flag is
  advisory and cannot alter wave assignment.
- The optimized Pester 5.7.1 baseline contains 164 passing tests.

- Enforced `MinRecommendedPerfRatio` in the final candidate gate shared by same-family, same-shape,
  burstable and cross-family recommendation strategies; fallback paths can no longer bypass the configured
  performance floor.
- Made Compute SKU availability and restriction evaluation subscription-aware. Each subscription now gets
  its own region-scoped catalog and cache entry, and recommendation computation uses only the catalog for the
  VM's subscription.
- Added fail-safe handling for a per-subscription catalog failure: affected VM rows remain in the report for
  manual review rather than inheriting another subscription's availability data.
- Ensured the non-REST `Get-AzComputeResourceSku` fallback switches to the requested subscription context
  before collecting catalog data.
- Fixed mixed-model performance comparisons: when ACU metadata exists for only one side, both current and
  candidate SKUs are evaluated with the same generation-aware heuristic before enforcing the performance floor.
- Fixed recommendation ranking under PowerShell strict mode when candidate filtering returns exactly one
  same-vendor SKU; the result is now retained as a collection before evaluating its count.
- Added a governed retirement fallback: when same-family and same-shape selection finds no target, retiring
  SKUs search compatible non-retiring x64 families, permit upsize and may switch Intel/AMD. Availability,
  architecture, workload class, required Premium/Ultra/Accelerated Networking features and performance remain
  hard gates; `N/A` now means those gates made a target impossible, and a target already on a known retirement
  path is never proposed.
- Made candidate cost and ordinary upsize ceilings ranking/disclosure inputs only for the final retirement
  fallback, so they cannot suppress the last hard-compatible alternative. x64/ARM boundaries, regional and
  subscription availability, required Premium/Ultra/Accelerated Networking features and the performance floor
  remain non-negotiable.
- Fixed retirement matching for constrained size names such as `DS12-1_v2` and `DS12-2_v2`; these now map
  to `Dsv2-series` and cannot be selected as supposedly non-retiring targets.
- Made the governed retirement fallback rank minimum vCPU growth, then minimum memory growth, before vendor,
  price, generation or feature score. A cheaper/newer oversized target can no longer outrank a smaller
  compatible candidate.
- Fixed constrained-vCPU evaluation to prefer Azure's `vCPUsAvailable` capability over nominal `vCPUs` in
  performance, compatibility, candidate filtering and ranking. Variants such as `F4-1amds_v7` can no longer
  masquerade as four-vCPU replacements when only one vCPU is usable.
- Added workload-class parity so general-purpose VMs cannot be recommended GPU, HPC or Confidential Compute
  targets merely because their numeric capabilities match.
- Changed retirement fallback shape ordering to minimize combined proportional CPU and memory growth before
  individual-dimension tie-breakers. This avoids trading exact CPU for disproportionate memory oversizing.
- Exposed Retail delta price coverage in the HTML report so net values are not compared across runs with
  different denominators, and relabeled report metadata as `Script version` for auditability.
- Added focused Pester regressions for every performance fallback path, per-subscription catalog loading,
  recommendation isolation, non-REST context selection, report metadata and cost-coverage disclosure. The
  retirement contract covers cross-family Intel/AMD upsize, explicit hard-gate impossibility, exclusion of
  already-retiring targets and complete target assignment whenever compatible catalog alternatives exist.
- A live validation run produced targets for all 9 retirement-path VMs, no `N/A` recommendations, full 9/9
  Retail-delta coverage and a delivery-ready result.

## v0.8 - 2026-07-14

- Added runtime release metadata: the JSON report exposes top-level `ReportVersion`, the HTML provenance
  sidebar identifies report version `v0.8`, and the activity log records the version at startup.
- Added nested progress reporting to long-running inventory, source, SKU catalog and pricing stages, with
  region/subscription/page context beneath the main execution phase.
- Made Compute SKU REST retrieval memory-bounded by querying requested regions independently and compacting
  each page immediately; an out-of-memory response with extended-location metadata now retries without that
  optional metadata.
- Fixed legacy `Standard_B1s` recommendations: when no equivalent modern shape exists, the burstable fallback
  can select the smallest compatible 2-vCPU modern B-series target while preserving memory, architecture,
  capability, regional/subscription restriction and configured retail-cost gates.
- Added CPU-vendor-aware candidate ranking. Intel/AMD continuity is preferred; a mixed-vendor x64 target is
  selected only when no same-vendor alternative exists or its known Retail price is lower, and that reason is
  surfaced in structured output and the report. ARM is a hard architecture boundary and is never proposed for
  an x64 VM, even when architecture changes are enabled.
- Documented the CPU vendor/architecture decision matrix, behavior when Retail prices or vendor metadata are
  unavailable, structured audit fields and the operational validation required for Intel/AMD changes.
- Expanded the Pester 5 regression suite to 133 passing tests, including bounded `B1s` modernization,
  CPU-vendor ranking and rationale, ARM exclusion and region-scoped Compute SKU memory behavior.

## v0.7 - 2026-07-14

- Documented the exact official Microsoft Release Communications API endpoint and the complete default
  Compute-retirement query used by Stream C.
- Added explicit Stream C lifecycle logging for API/cache results, tenant-matched families, findings added
  after Learn priority, and duplicate matches superseded by Learn.
- Documented the evidence trust boundary: `High` represents accepted provenance and deterministic gates,
  not per-resource certainty for public SKU-family sources; the hermetic Pester suite does not replace live
  source-health or impacted-resource verification.
- Aligned current documentation with the three-source model: Release Communications is now included in
  retirement-path, public-source, source-health and RI/SP descriptions; cache documentation now covers
  its index/detail cache and API status in structured output.
- Expanded Decision Room guidance with visible count equations, per-card and per-chip tooltips, and a
  legend/README explanation of denominators, sidecar addition and non-additive RI/monitoring populations.
- Removed static RI-cutoff and Dependency Agent timeline facts. RI cutoff date and affected families now
  come from the official Release Communications commercial notice; Dependency Agent / VM Insights Map
  dates remain per-resource values supplied by Azure Advisor, with no fabricated fallback.
- Prevented Reserved VM Instance purchase/renewal announcements from being misclassified as technical
  VM-size retirement findings.
- Promoted Microsoft Release Communications to authoritative Stream C for SKU-family retirements. Records
  create findings only when structured retirement availability and announcement text deterministically match
  a SKU family in tenant inventory; Microsoft Learn retains priority for duplicate family coverage.
- Replaced the legacy Microsoft Release Communications feed endpoint with the JSON OData API and restricted its
  default query to retirement notices for Azure Dedicated Host, AKS, Azure Linux, Batch, Linux/Windows
  Virtual Machines, Virtual Machine Scale Sets and Virtual Machines (78 records when verified).
- Added a persistent complete retirement index plus one cached detail document per ID. The first run downloads
  both levels; a fresh daily cache performs no HTTP requests, while stale caches request modified-since deltas
  and refresh only changed/new details.
- Included every notice returned by the configured API query by default, removing the 12-month lookback and
  30-row rendering cap. A positive lookback remains available as an opt-in parameter. Unmatched Stream C
  notices remain Coverage context and retain official Azure Updates links.
- Removed deprecated pre-API parameter aliases and standardized Release Communications parameters and
  internal identifiers on API terminology.
- Expanded the Pester 5 regression suite to 126 passing tests, including live-source separation, dynamic
  RI-family derivation, commercial-notice exclusion, Advisor monitoring-date preservation, Stream C log
  reconciliation, empty-delta cache retention, forced refresh of fresh index/detail caches and negative
  trust cases for structured availability, retirement rings, token boundaries, conflicting dates, endpoint
  provenance and unknown-source confidence.

## v0.6 - 2026-07-13

- Replaced first-match remediation routing with deterministic urgency and complexity floors; the
  lower wave number selects the final governed lane while all applicable reason codes remain visible.
- Added a fail-closed remediation-plan invariant that recomputes the expected wave from raw row facts
  before accepting wave counts.
- Added a Pester 5 review suite with retirement-source, recommendation, cost, API-contract and report
  checks, including a literal 32-case correctness matrix for `Resolve-RemediationWaveFloor`.
- Made W3/W4 headers, wave chips, rationale and validation checklists derive from row-level facts and
  reason codes; empty or HTML-only checklist entries are suppressed.
- Normalized legacy Azure Premium Storage SKU names (`DS`/`GS`) for architectural family comparison,
  so `DS2_v2 -> D2ads_v7` is same-family while genuine family changes remain cross-family.
- Aligned the visible remediation rationale with the normalized family fact without rewriting the
  source `RecommendationBasis` retained for audit and structured outputs.
- Added explicit no-compatible-target presentation and an **Unclassified (no catalog target)** change
  bucket so change-type totals reconcile with the retirement-path total without treating missing prices
  as zero savings.
- Hardened retirement-source parsing, recommendation compatibility, Windows/Linux retail meter checks,
  delivery-readiness reconciliation and presentation encoding based on the new regression suite.
- Documented how to run the Pester review suite and updated remediation-wave semantics for v0.6.

## v0.5 - 2026-07-13

- Added Microsoft Release Communications as Stream C official-communications context.
- Added the initial Release Communications source controls and history-window parameters.
- Added communication classification into **Corroborated**, **FinOps** and **Review-only** buckets in the Coverage tab.
- Tightened Corroborated matching to require a retirement notice with compute context and an explicit per-notice VM series mention; short family tokens such as `B` or `F` are no longer accepted.
- Added non-fatal source fetching: feed failures are logged and rendered as unavailable, while report numbers remain unchanged.
- Hardened source parsing for BOM/encoding edge cases so a valid response is not rendered as unavailable after a successful HTTP fetch.
- Added a count invariant so communications context cannot alter retirement counts, source split, monitoring counts or remediation wave totals.
- Added `ReleaseCommunicationContext` to the JSON output and sidebar provenance/status for source checks.
- Fixed sidebar subscription provenance so the subscription count comes from the resolved in-scope subscription set, not only from subscriptions that produced report rows; mismatches are now logged explicitly.
- Updated the anonymized rendered HTML example to the v0.5 report layout, including communications context, scope-based subscription provenance and the latest Decision Room totals.
- Documented the initial Stream C semantics: communications were context-only and never created retirement rows, CSV rows, waves or backlog items.

## v0.4 - 2026-07-13

- Added always-visible **Preview Sidecar Coverage** counts in the CSA / Engineer view so VMSS and Batch scanned/impacted totals remain visible even when a sidecar has zero affected resources.
- Added Azure Batch Management REST fallback discovery so Batch pools are listed per Batch account across the subscription scope even when Azure Resource Graph does not return pool child resources.
- Added `-BatchManagementApiVersion` to control the Azure Batch Management API contract version used by the Batch pool fallback.
- Updated Batch inventory logging to show Resource Graph pool discovery, Batch account discovery and Azure Batch Management REST pool listing separately.

## v0.3 - 2026-07-13

- Added **Azure Batch Pool Exposure** as a Public Preview capability: Batch pool `vmSize` values are scanned from Resource Graph and matched against the existing live VM-size retirement sources, while remaining separate from VM counts and remediation waves.
- Added **Virtual Machine Scale Set Exposure** as a Public Preview capability: VMSS `sku.name` values are scanned from Resource Graph and matched against the existing live VM-size retirement sources, while remaining separate from VM counts and remediation waves.
- Added **Reserved Instance Cutoff Planning** as a Public Preview FinOps sidecar: VM, Batch pool and VMSS size families affected by the `2026-07-01` Reserved VM Instance new purchase/renewal cutoff are flagged separately from retirement counts and remediation waves.
- Hardened Public Preview sidecars so empty Batch/VMSS inventories are treated as zero-row previews instead of blocking report generation.
- Updated the Executive Summary and Decision Room to show aggregate compute exposure across standalone VMs, VMSS and Batch while keeping detailed remediation tables separated by resource type.
- Reorganized the HTML report into a left-sidebar, CSS-only section switcher for audience-specific views: Executive Overview, CSA / Engineer, Project Plan, FinOps and Coverage.
- Made the HTML layout fluid and responsive: dashboard panes use available viewport width, cards reflow automatically, and wide detail tables keep horizontal scrolling instead of squeezing columns.
- Added a **Preview Remediation Queue** for affected VMSS and Batch resources, using operational remediation patterns for scale-set model updates and Batch pool replacement/drain workflows.
- Clarified RI cutoff labels so resources in cutoff families are presented as planning signals, not as proof of active Reserved Instance purchases in the subscription.
- Compact RI cutoff reporting in HTML by grouping rows by VM-size family and resource count, leaving per-resource detail in the structured CSV/JSON outputs.
- Changed the CSA / Engineer detail table ordering to follow execution sequence (`W0` to `W4`), then retirement date and VM name, instead of the upstream evidence-source ordering.
- Documented the Public Preview coverage model, sidecar non-blocking behavior, RI cutoff limitations and VMSS/Batch operational remediation model.

## v0.2 - 2026-07-12

- Reworked the HTML dashboard into a decision-oriented report with a **Decision Room**, risk-vs-effort matrix, execution scenarios and an "If We Do Nothing" countdown.
- Moved the CSA / Engineer detail table higher in the report and placed Remediation Plan plus Monitoring Lifecycle near the end of the report flow.
- Refined remediation wave labels for clearer execution semantics: time-critical, Advisor + sensitive, sensitive validation, architecture and low complexity.
- Added a closeable **Legend** overlay from the sidebar to explain core concepts, wave meanings, decision sections, detail-table fields, cost caveats and validation expectations.
- Added inline information icons/tooltips beside key KPIs and report sections.
- Completed a conservative lint cleanup: ScriptAnalyzer warnings are clean while preserving report facts, calculations, classification rules and output logic.

## v0.1 - Initial baseline

- Deterministic Azure SKU modernization report with CSV, JSON and self-contained HTML output.
- LIVE-only retirement source model using Azure Advisor Resource Graph and Microsoft Learn markdown.
- Separate monitoring lifecycle tracking for Dependency Agent / VM Insights Map signals.
- Deterministic remediation wave plan and delivery-readiness consistency gates.
