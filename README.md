# terraform-platform (sandbox)

A minimal, personal sandbox for validating a Terraform CI redesign before it lands in production. For first-time setup, see **[INSTALL.md](INSTALL.md)**.

## Why this exists

A bare-bones `terraform plan` + `apply` GitHub Actions pipeline (the kind you get by following the first tutorial you find) tends to carry the same four gaps:

1. **No PR comments** — plan output only goes to the job's Step Summary; reviewers have to click into Actions to see what a PR would change.
2. **No protection against a stale apply silently overwriting someone else's change** — `apply` independently re-derives its own plan from scratch instead of consuming what was actually reviewed at the `plan` step. Nothing stops it from applying a materially different diff than what a human approved, if the real state moved in between (e.g. someone else's apply landed in the gap).
3. **State drift goes undetected** — no scheduled plan-only workflow, so real state can silently diverge from what `main` declares, with nobody finding out until the next incidental plan run.
4. **No concurrency control** at the GitHub Actions level — only the backend's blob state lease serializes execution, which is a blocking wait/retry, not a visible queue. This directly compounds problem #2.

This repo is a small, low-stakes pipeline (`.github/workflows/plan-apply.yml` + `drift-detect.yml`) built to design and validate fixes for all four before applying the same pattern anywhere it'd actually be costly to get wrong.

## The four mechanisms being validated

### 1. Saved-plan apply (fixes #2)
`plan` runs with `-out=tfplan` and uploads it as an artifact only when there's a real diff (`exitcode == 2`). `apply` downloads that exact artifact and runs `terraform apply tfplan` — no `-auto-approve`, no fresh re-plan. A saved plan file embeds the backend state's serial/lineage, so `terraform apply <planfile>` natively refuses with `Saved plan is stale` if the real state moved since the plan was computed. This is the actual fix: Terraform does the "fail closed if diverged" work for free.

Residual risk, not eliminated: the saved plan file contains **unredacted** values for anything needed to compute the plan, including fields marked `sensitive` (that flag only redacts CLI/JSON display). Mitigated here by 5-day artifact retention, not removed.

### 2. Per-stack concurrency (also fixes #2, defense in depth)
Two job-level `concurrency:` blocks — `plan` cancels a superseded run (a stale plan for an old push is worthless, keeps PR feedback fast), `apply` queues instead of cancelling (killing a real in-flight infrastructure mutation mid-execution is dangerous). A queued second apply's saved plan will very likely be stale by the time it runs anyway, so mechanism #1 rejects it instead of silently reapplying an outdated diff.

### 3. PR comment with plan diff (fixes #1)
Sticky comment (marker-based find-or-create/update) posted by the `plan` job via `actions/github-script`, carrying counts (add/change/destroy) and a link to the run — never the raw resource-level plan text inline, both because of GitHub's comment size limit and because a PR comment is far more visible/cacheable than a gated run log, so it should carry a summary + link, not full attribute values.

### 4. Scheduled drift detection (fixes #3)
`drift-detect.yml` runs a read-only `terraform plan` (no `-out`, never feeds an apply) on a daily cron plus `workflow_dispatch`. A drifted or failed run opens (or comments on) a GitHub issue labeled `drift`; a clean run closes it. Scaling this to many stacks would mean one explicit named job per stack rather than a `strategy: matrix` — matrixed job outputs collapse to the last-completed instance, which would silently break an aggregating notify step that needs a result per stack.

## Deliberately out of scope

- **Resource-tag-based provenance tracking** — dropped in favor of GitHub Environment deployment history, which already answers "which branch/run last applied here" for free.
- **Locking down which branch can approve an apply** — apply-from-branch is treated here as intentional, allowed behavior; the mechanisms above make an approved apply *consistent with what was reviewed*, they don't change *who* can approve it or *from where*.

## Things to try

- **Concurrency**: push two commits to a PR in quick succession. The first `plan` run should show **cancelled** in the Actions tab, not queued or racing the second.
- **Saved-plan staleness**: open a PR, let it plan, don't approve the apply yet. In another terminal, drift the resource out-of-band:
  ```bash
  az storage account update --name <storage-account-name> --resource-group tfplatform-rg --set tags.manual=drift
  ```
  Now approve the apply. It should **fail** with Terraform's native `Saved plan is stale` error instead of silently applying.
- **PR comment**: push a second commit to the same PR. The existing plan comment should update in place, not get duplicated.
- **Drift detection**: after drifting the tag as above, run the **Drift Detect** workflow manually (`workflow_dispatch`). Confirm the job summary shows the drift and a GitHub issue labeled `drift` gets opened. Fix the drift (re-run the apply, or revert the tag by hand) and re-run drift-detect — the issue should get a closing comment and close automatically.

## Cost

Resource group: free. Two `Standard_LRS` storage accounts (state + mock resource) with negligible data: a few cents a month combined. See INSTALL.md's teardown commands when you're done.
