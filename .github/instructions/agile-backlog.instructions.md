---
applyTo: "**/*"
---

# Agile Backlog Instructions

This repository uses Agile backlog management.

When working with backlog items, always classify work using this taxonomy:

- Epic
- Feature
- User Story
- Task
- Bug
- Spike
- Enabler
- Technical Debt

For User Stories, use this format:

As a [persona], I want [capability], so that [outcome].

Every backlog item should include:
- Title
- Description
- Agile type
- Priority
- Rationale
- Acceptance criteria
- Dependencies
- Estimate
- Labels
- Definition of Ready status

Use Given / When / Then acceptance criteria where possible.

Do not treat all work as user stories. Technical work may be a Task, Enabler, Spike, or Technical Debt item.

Prioritize using the model in `docs/product/prioritization-model.md`. If no model is defined, use WSJF:

WSJF = (Business Value + Time Criticality + Risk Reduction / Opportunity Enablement) / Job Size

If information is missing, do not guess silently. Add an “Assumptions” section and mark the item as `needs-po-review`.