# 10. Dashboards as code

**Question it answers:** how does a platform team look at all of this every day, and can
the view be versioned and reviewed like the rest of the platform?
**Status:** built 2026-09-13. Perses over the same ClickHouse, four dashboards as JSON in
the repository, and the trace view through the plugin this project contributed upstream.
**Tools:** Perses v0.54.0; the ClickHouse plugin from perses/plugins#813.

## Run

```bash
make perses-image        # stock Perses plus the ClickHouse trace-query plugin, built from the PR commit
make perses              # the read-only ClickHouse user, the provisioning ConfigMap, the chart, the route
make perses-dashboards   # after editing deploy/90-perses/provisioning/*.json
```

Then `http://perses.kube.local`, project *Agent observability lab*. Or
`kubectl port-forward -n agent-obs-platform svc/perses 18080:8080`.

## What you should see

Four dashboards, one per audit question, and nothing created in the UI:

| Dashboard | Panels |
| :- | :- |
| 1. What did the agents do? | runs, input tokens per agent, reasoning tokens, outcomes stacked worst-first, calls by the model that actually served them, tool calls per server, run duration |
| 2. On whose behalf, and was it allowed? | calls per principal, calls per key alias, tool decisions allow/deny, gateway refusals by kind, guardrail verdicts, 429s, data access by resource |
| 3. Can you prove it later? | dangling parents (must be 0), agent vs gateway token sums, spans redacted per service, traces routed to the restricted store |
| 4. Audit: runs and traces | a table of runs, a table of flagged runs, and the Gantt view of any trace, read from ClickHouse |

Clicking a trace name in either table opens it on **5. Trace detail**, a dashboard whose
only job is to show one trace. Two things had to be true for that single click to work.

The table's `links.trace` needs a TraceTable newer than the one Perses v0.54.0 bundles:
0.11.0 has no `links.trace` option at all, so the click does nothing and the id has to be
pasted by hand. `apps/perses/Dockerfile` therefore builds TraceTable 0.12.0-beta.3 from the
same commit as the ClickHouse plugin.

And the link has to target a *different* dashboard. Pointed at the dashboard it already
sits on, the click does not take effect until the page is reloaded — the trace id reaches
the URL but the variable, and so the Gantt, keeps its old value (CONTRIBUTIONS.md item 14).
Arriving at another dashboard mounts it fresh and the variable is read from the URL. The
audit page keeps its own Gantt panel for a trace id typed or pasted in by hand. The Gantt shows every service
in the run, with the tool servers' spans nested under the workflow's.

## What it means

**Dashboards are files.** `deploy/90-perses/provisioning/` holds the project, a Secret
that points at a mounted password file, the datasource, and the four dashboards, as
JSON. `make perses-dashboards` publishes them as a ConfigMap; Perses reads the folder at
start and every ten minutes. A change is a diff in a pull request, which is the
reviewable artefact an enterprise wants for "what does the audit team see".

**The trace view is the contribution, closing a loop that opened on day one.** Perses's
ClickHouse datasource shipped with time-series and log queries and no trace query; the
Gantt and trace-table panels existed and nothing could feed them from ClickHouse
(CONTRIBUTIONS item 1). The plugin was written, submitted upstream, and here it runs in
the lab that needed it: the image is stock Perses with the archive built from the PR
commit, cloned from the fork at build time so nothing local is required.

**Perses reads as a user that can only read.** `perses_reader` has SELECT on the two
telemetry databases and nothing else; its password is a mounted file the provisioned
Secret refers to, never a value in a provisioning file.

**The time-series plugin's contract is simple and worth knowing.** SQL with `{start}` and
`{end}` placeholders, a `time` column, and every other column a numeric series. A string
column cannot be a series, so "calls per principal" is a count and a distinct count, not
one line per person. That is a limitation of the plugin, and, for a dashboard about
people, arguably a feature.

## Where it breaks

- Panels that filter by attribute value are only as good as the attribute vocabulary: a
  new outcome value or a renamed key needs a dashboard change, in code, reviewed.
- Perses units are strings (`"seconds"`), and a struct where a string was expected fails
  the whole dashboard at provisioning time with a CUE error that names every alternative.
  Correct, verbose, and the reason `make perses-logs` is a target.
- The plugin archive bundled with stock Perses cannot be removed in a distroless final
  stage, so the image ships a second archive directory and the Deployment points at it.
- The OpenLIT UI remains for what it is good at, a per-trace GenAI view. Its filter and
  vocabulary limits (chapter 5) are why the dashboards live here.

## In an enterprise

Dashboards-as-code is not a preference, it is how the view the audit team sees becomes a
controlled artefact: versioned, diffed, approved, and rebuilt from the repository. Perses
being early (CNCF sandbox) shows: fewer panels, a smaller ecosystem, and a plugin that had
to be written. It also means a strong example here is novel there, which is the reason
it was chosen.

## Read more

- `apps/perses/Dockerfile`, `deploy/90-perses/`, CONTRIBUTIONS item 1.
- LEARNINGS.md, 2026-09-13: *Chapters 9 and 10*.
