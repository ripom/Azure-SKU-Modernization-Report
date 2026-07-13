# Changelog

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
