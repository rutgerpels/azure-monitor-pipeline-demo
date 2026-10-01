# Build a live demo of Azure Monitor pipeline

## Context

We are presenting Azure Monitor pipeline to a customer's observability platform engineering team (network infrastructure focus). They have a large on-premises estate that is being onboarded to Azure Arc and want to consolidate telemetry from many sites into Azure Monitor. They only adopt generally available features, so clearly separate GA from preview in anything you build.

The session is 30 minutes with roughly 15 minutes of live demo. The presenter needs a repeatable, low-risk setup that can be deployed from scratch in one go and torn down afterwards.

## Ask

Build a self-contained, scriptable demo environment for Azure Monitor pipeline that shows these four scenes:

1. **Agentless ingestion from network devices** — Syslog/CEF sources (simulated, named like switches and firewalls) send to the pipeline; records land auto-schematized in Log Analytics.
2. **Filter and reshape before data leaves the site** — a pipeline transformation drops noise and trims fields; show the ingestion volume before vs. after.
3. **Connectivity loss and backfill** — persistent buffering enabled; cut the cluster's outbound connectivity, keep sending, restore, and show the data backfilling.
4. **Operate it as a platform** — the pipeline's own health/performance signals and heartbeat, ready to show in Log Analytics.

Optionally include an OTLP log client as a fifth scene, labelled as preview.

## Constraints

- Azure region: West Europe.
- Keep it minimal and cheap: a single small Kubernetes cluster is fine. Prefer a supported lightweight distribution.
- Everything as code (Bicep or Terraform plus shell/PowerShell), with a single deploy script, a single teardown script, and a README with the demo run-book (step-by-step for each scene, including the exact commands and KQL queries to run live).
- Include saved KQL queries for each scene and a fallback plan if something fails live.
- Use current Microsoft Learn documentation for Azure Monitor pipeline as the source of truth for prerequisites, supported configurations and GA/preview status. Do not rely on memory.

## Out of scope

- Slides or customer-facing narrative.
- Production hardening beyond what the demo needs.
