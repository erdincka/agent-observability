# 10. Dashboards as code

**Question it answers:** how does a platform team look at all of this every day, and can
the view be versioned and reviewed like the rest of the platform?
**Status:** not built. Perses is not deployed. The ClickHouse trace-query plugin it needs
is an open upstream PR from this project.
**Tools:** Perses, ClickHouse.

## The experiment, as planned

1. Deploy Perses against the same ClickHouse.
2. Author, in code, one dashboard per audit question: activity per agent and route, token
   and reasoning usage, outcomes, denials, completeness.
3. Use the trace-query plugin to open a trace from a table row.

## Where it stands

- Perses's ClickHouse datasource had no trace query. The plugin was written and submitted:
  CONTRIBUTIONS item 1, [perses/plugins#813](https://github.com/perses/plugins/pull/813).
- OpenLIT remains the phase 1 UI. Its limits, documented in chapter 5, are part of why a
  dashboards-as-code layer is worth having: what it cannot filter, a query can.

## Read more

- CONTRIBUTIONS item 1.
- LEARNINGS.md: *Three things verified before deploying anything* (2026-09-09).
