# 9. Proving it later

**Question it answers:** can a reviewer who was not there establish, from the stored
record alone, what an agent did, and trust that the record is whole and unaltered?
**Status:** not built as a chapter. The queries exist and were used to close phase 1;
immutability and long retention do not exist.
**Tools:** ClickHouse, MinIO, the run-level attributes from chapter 5.

## The experiment, as planned

Package the checks this project has already relied on into one place a reviewer can run,
and add the two it does not have.

1. **Completeness.** Zero spans whose parent was never exported. The query from chapter 3.
2. **Reconciliation.** Agent-side token sums equal gateway-side sums for the same run.
   The check from chapter 5. Any difference is a missing or duplicated span.
3. **No double counting.** One `chat` span per model call per layer, and a documented rule
   for which layer is authoritative for usage. Until the conventions can mark an
   intermediary span, the rule is local and must be written down.
4. **No content.** The grep from chapter 2, over the whole run, on both the hot store and
   the archive.
5. **Run comparison.** Two runs of the same incident, side by side: domains covered, tool
   calls, evidence items, tokens, outcome. What "the agent behaved differently" means in
   numbers.
6. **Immutability.** ClickHouse cannot promise a row was not changed. An archived trace in
   MinIO with versioning, and a per-run digest recorded at write time, can show that the
   copy read later is the copy written then.

## What you should see, when built

One command that takes a run id and prints a receipt: complete, reconciled, content-free,
archived, with the digest. A reviewer with read access to the store and nothing else can
reproduce it.

## In an enterprise

An auditor does not read traces; they run checks. The value of this chapter is that every
check is a query over the standard tables, using standard attribute names where they
exist and named local ones where they do not, so the same checks run against any
Collector-to-ClickHouse deployment.

## Read more

- LEARNINGS.md: *Phase 1 write-up* (2026-09-13), the done-criterion table, which is the
  first version of this receipt done by hand.
