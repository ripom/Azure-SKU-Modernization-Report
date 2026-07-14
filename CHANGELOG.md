# Changelog

## Unreleased

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
