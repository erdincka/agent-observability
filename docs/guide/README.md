# The guide

Read in order. Each chapter is one experiment: the question it answers, what to run, what
to look at, what you should see, what it means, where it breaks, and what changes in an
enterprise. The built chapters are reproducible today on [this lab](../lab-environment.md);
the unbuilt ones are honest plans with their decisions listed.

| # | Chapter | Audit question | Status |
| -: | :- | :- | :- |
| 0 | [The stack, and how the pieces relate](00-the-stack.md) | all four | built |
| 1 | [One span, end to end](01-one-span.md) | can you prove it | built |
| 2 | [The gateway as a control point](02-the-gateway.md) | what did it do, on whose behalf | built |
| 3 | [The agent trace](03-the-agent-trace.md) | what did it do | built |
| 4 | [Tools over MCP](04-tools-over-mcp.md) | what did it do, with what data access | built, one fix pending |
| 5 | [Attribution per agent](05-attribution.md) | what did it do, by how much | built, names to align |
| 6 | [Identity](06-identity.md) | on whose behalf | not built |
| 7 | [Authorization](07-authorization.md) | with what data access | not built |
| 8 | [Content, redaction and retention](08-content-and-retention.md) | with what data access, can you prove it | not built |
| 9 | [Proving it later](09-proving-it.md) | can you prove it | not built |
| 10 | [Dashboards as code](10-dashboards.md) | all four | not built |
| 11 | [Evaluation](11-evaluation.md) | was it right | deferred |

The [governance matrix](../governance-matrix.md) is the cross-cutting view: every
sub-question, its control, its evidence, and its status.

## The appendices

- [LEARNINGS.md](../../LEARNINGS.md), the chronological log. Dead ends kept in.
- [CONTRIBUTIONS.md](../../CONTRIBUTIONS.md), the upstream gaps, one PR filed.
- [TODO.md](../../TODO.md), deferred work.
