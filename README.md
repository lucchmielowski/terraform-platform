# terraform-platform (sandbox)

A minimal, personal sandbox to test Terraform CI mechanisms — saved-plan apply, per-stack concurrency, PR comments, scheduled drift detection — against a real GitHub Actions + Azure OIDC pipeline.

For first-time setup (bootstrapping remote state, OIDC trust, GitHub environments), see **[INSTALL.md](INSTALL.md)**.

This README instead tracks the actual failure modes this sandbox has been used to reproduce and fix, one per use case. Each one was hit for real, diagnosed against the live pipeline, and fixed — this doubles as a regression checklist: if any of these come back, the fix is already written down.

## Use case 1: `ARM_*` vars missing → "a Tenant ID must be configured when authenticating with OIDC"

**Symptom**: `terraform init`/plan fails immediately with `azurerm` complaining OIDC is missing a Tenant ID and Client ID.

**Cause**: The `sandbox` / `sandbox-apply` GitHub environments had zero variables configured — `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` all resolved to empty strings.

**Fix**: Set them as GitHub **environment variables** (not secrets — none of these are sensitive; the real access control is the federated credential trust + RBAC role assignment, not secrecy of an ID). See INSTALL.md step 4.

## Use case 2: Federated credential subject mismatch (immutable IDs)

**Symptom**: `terraform init` fails with `AADSTS700213: No matching federated identity record found for presented assertion subject 'repo:owner@OWNER_ID/repo@REPO_ID:environment:sandbox'`.

**Cause**: GitHub's OIDC token `sub` claim uses the immutable-ID format `repo:<owner_login>@<owner_id>/<repo_name>@<repo_id>:environment:<name>`, not the plain `repo:<owner>/<repo>:environment:<name>` format. A federated credential configured with the plain form never matches.

**Fix**: Look up the real owner/repo IDs (`gh api repos/{owner}/{repo} -q '"owner=\(.owner.login)@\(.owner.id) repo=\(.name)@\(.id)"'`) and use them verbatim in the federated credential's `subject`.

## Use case 3: Plan always reports "no changes", even when it isn't

**Symptom**: The PR comment and job summary always say "✅ no changes", even on a plan that clearly shows `N to add` in the raw log.

**Cause**: `hashicorp/setup-terraform` installs a wrapper script around the `terraform` binary by default (to expose `stdout`/`stderr`/`exitcode` as step outputs). The wrapper always exits `0` to the shell so it can finish writing its own outputs — which silently breaks any script relying on `terraform plan -detailed-exitcode`'s real exit code (`2` = changes). `plan_exit=${PIPESTATUS[0]}` reads the wrapper's `0`, never the real `2`.

**Fix**: Set `terraform_wrapper: false` on every `hashicorp/setup-terraform` step that a script inspects the exit code of (`plan-apply.yml` × 2, `drift-detect.yml` × 1).

## Use case 4: Stale/orphaned state lock after a cancelled run

**Symptom**: `terraform init`/`plan` hangs on "Acquiring state lock..." for minutes, or later fails outright with `Error acquiring the state lock`.

**Cause**: The `plan` job's concurrency group (`cancel-in-progress: true`) kills an in-flight run when a newer one supersedes it — including mid-lock-hold. The killed process never releases its lease on the state blob, leaving it orphaned. In the worse case the lease exists but its `terraformlockid` metadata is empty (a torn write), which `terraform force-unlock <id>` can't target at all since there's no ID to give it.

**Fix**:
- If the lock ID is known and metadata is intact: `terraform force-unlock <LOCK_ID>` (confirm nothing is genuinely still running first — check `gh run list`).
- If metadata is empty/malformed: break the lease directly on the blob:
  ```bash
  KEY=$(az storage account keys list --account-name <STATE_SA> --resource-group <STATE_RG> --query "[0].value" -o tsv)
  az storage blob lease break --account-name <STATE_SA> --container-name tfstate --blob-name terraform-platform.tfstate --account-key "$KEY"
  ```

**Known risk, not yet fixed**: this concurrency setup can strand a lock on every cancelled mid-flight run. Worth deciding whether to accept it (locks are always recoverable, as above) or add an explicit unlock/cleanup step.

## Use case 5: Pre-existing resource not in state ("already exists")

**Symptom**: `terraform apply` fails with `a resource with the ID ".../resourceGroups/tfplatform-rg" already exists - to be managed via Terraform this resource needs to be imported into the State.`

**Cause**: The resource group existed in Azure (created out-of-band — e.g. by hand during OIDC bootstrap, see INSTALL.md step 2) but was never recorded in Terraform's state.

**Fix**: Confirm the real resource is empty/safe to adopt (`az resource list --resource-group <rg> -o table`), then bring it under management:
```bash
terraform import azurerm_resource_group.this /subscriptions/<sub>/resourceGroups/<rg>
```

## Use case 6: Import succeeds, but plan now wants to destroy+recreate anyway

**Symptom**: After importing, `terraform plan` shows `# azurerm_resource_group.this must be replaced` with `location` as the forcing attribute.

**Cause**: The real resource was created in a different region than the Terraform config's `variables.tf` default. Resource group location is immutable — any mismatch forces a destroy-and-recreate, not an in-place update.

**Fix**: Decide which side is correct — usually cheaper to make the config match reality (`variables.tf` default) than to destroy/recreate real infrastructure. Always read the full plan before approving; "must be replaced" on anything non-empty is a stop-and-check moment, not a rubber-stamp.

## Things to try

Once the pipeline is healthy end-to-end, these exercise the four mechanisms this sandbox exists to validate:

- **Concurrency**: push two commits to a PR in quick succession. The first `plan` run should show **cancelled** in the Actions tab, not queued or racing the second.
- **Saved-plan staleness (the actual "lock" fix)**: open a PR, let it plan, don't approve the apply yet. In another terminal, drift the resource out-of-band:
  ```bash
  az storage account update --name <storage-account-name> --resource-group tfplatform-rg --set tags.manual=drift
  ```
  Now approve the apply. It should **fail** with Terraform's native `Saved plan is stale` error instead of silently applying — that's the mechanism that prevents "someone else's apply erasing my reviewed changes."
- **PR comment**: push a second commit to the same PR. The existing plan comment should update in place, not get duplicated.
- **Drift detection**: after drifting the tag as above, run the **Drift Detect** workflow manually (`workflow_dispatch`). Confirm the job summary shows the drift and a GitHub issue labeled `drift` gets opened. Fix the drift (re-run the apply, or revert the tag by hand) and re-run drift-detect — the issue should get a closing comment and close automatically.

## Cost

Resource group: free. Two `Standard_LRS` storage accounts (state + mock resource) with negligible data: a few cents a month combined. See INSTALL.md's "Cost" section for teardown commands.
