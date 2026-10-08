# The guide

Read in order. Each chapter is one experiment: the question it answers, what to run, what
to look at, what you should see, what it means, where it breaks, and what changes in an
enterprise. Every chapter is reproducible today on [this lab](../lab-environment.md).

| # | Chapter | Audit question | Status |
| -: | :- | :- | :- |
| 0 | [The stack, and how the pieces relate](00-the-stack.md) | all four | built |
| 1 | [One span, end to end](01-one-span.md) | can you prove it | built |
| 2 | [The gateway as a control point](02-the-gateway.md) | what did it do, on whose behalf | built |
| 3 | [The agent trace](03-the-agent-trace.md) | what did it do | built |
| 4 | [Tools over MCP](04-tools-over-mcp.md) | what did it do, with what data access | built |
| 5 | [Attribution per agent](05-attribution.md) | what did it do, by how much | built |
| 6 | [Identity](06-identity.md) | on whose behalf | built |
| 7 | [Authorization](07-authorization.md) | with what data access | built |
| 8 | [Content, redaction and retention](08-content-and-retention.md) | with what data access, can you prove it | built |
| 9 | [Proving it later](09-proving-it.md) | can you prove it | built |
| 10 | [Dashboards as code](10-dashboards.md) | all four | built |
| 11 | [Evaluation](11-evaluation.md) | was it right | built |

The [governance matrix](../governance-matrix.md) is the cross-cutting view: every
sub-question, its control, its evidence, and its status.

## The appendices

- [Limitations and alternatives](../alternatives.md): where each layer fell short, what
  has moved in the ecosystem since, and what a reader could choose instead.
- [CONTRIBUTIONS.md](../../CONTRIBUTIONS.md), the fourteen upstream gaps, one filed as a PR.
- [TODO.md](../../TODO.md), what was still open when the project concluded.
- `LEARNINGS.md`, the chronological log with the dead ends kept in. It is the author's
  working file and is not published; references to it throughout the guide point there
  deliberately.
