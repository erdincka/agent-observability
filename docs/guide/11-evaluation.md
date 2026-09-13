# 11. Evaluation: was it right (optional)

**Question it answers:** observability says what the agent did; evaluation says whether
it was right. An audit committee asks both.
**Status:** deferred, and not on the MVP path. Listed because the brief keeps it.
**Tools:** MLflow, if adopted.

## Why it is here at all

The incident corpus already contains the seed of an evaluation set: `no-evidence` is the
one incident with a knowable right answer, and the analyser saying "insufficient
evidence" is the pass condition. Chapter 5's run-level attributes are the features an
evaluation would score on.

## Why it is not built

Three unknowns at once is what sank the previous project. The governance chapters come
first. If this chapter is built, it should reuse the run-level attributes rather than add
a second way of describing a run.
