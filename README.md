# terraform-platform (sandbox)

A minimal, personal sandbox to test Terraform CI mechanisms — saved-plan apply, per-stack concurrency, PR comments, scheduled drift detection — against a real GitHub Actions + Azure OIDC pipeline.

One resource group, one storage account. Total cost is a few cents a month — well inside a $200 credit.

## ⚠️ Before you start: check which Azure account you're on

Your `az` CLI session may currently be authenticated against a **work** tenant/subscription. Every command below targets whatever subscription `az account show` currently points to. Run:

```bash
az account show
```

If it's not your personal account, log into the right one explicitly before continuing:

```bash
az login                      # opens a browser, pick your personal account
az account set --subscription <YOUR_PERSONAL_SUBSCRIPTION_ID>
az account show               # confirm before proceeding
```

## Troubleshooting: `(SubscriptionNotFound) Subscription <id> was not found`

Seen on the very first resource-creating command (e.g. `az storage account create`), even though `az account show` reports that same subscription as `Enabled` and default. This is a fresh free-trial subscription symptom: most resource providers start **unregistered** until first use, and Azure sometimes reports that as `SubscriptionNotFound` instead of the clearer `MissingSubscriptionRegistration`. Fix (one-time, free, no billable resources created):

```bash
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Authorization   # needed later, for the role assignment step

# registration takes a minute or two - poll until it flips to "Registered"
az provider show --namespace Microsoft.Storage --query registrationState -o tsv
```

Re-run whatever command failed once `Microsoft.Storage` shows `Registered`.

## Troubleshooting: `... was disallowed by Azure: The selected region is currently not accepting new customers`

A genuine Azure free-trial restriction, not a scaffold problem: some regions are closed to new free-trial subscriptions for capacity reasons, and which ones varies per account (see the `aka.ms/locationineligible` link in the error). It's scoped per resource-type + region, not the whole region — a resource group in that region still works fine (it's free, unrestricted metadata); it's specifically the storage account (a real billable resource) being blocked. A failed attempt for this reason creates nothing and costs nothing, so it's safe to just try other regions:

```bash
LOCATION=northeurope   # closest alternative to westeurope, usually open
```

If that also fails, this loop finds a working region without guessing one at a time (every failed attempt is a no-op, only the first success creates anything):

```bash
for LOCATION in northeurope eastus2 centralus southcentralus uksouth swedencentral; do
  echo "Trying $LOCATION..."
  if az storage account create \
    --name "${STATE_SA}test" \
    --resource-group "$STATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --min-tls-version TLS1_2 >/dev/null 2>&1; then
    echo "$LOCATION works — cleaning up the test account, use this region below"
    az storage account delete --name "${STATE_SA}test" --resource-group "$STATE_RG" --yes
    break
  fi
done
```

Once you've found a working region, use it for `$LOCATION` in every step below — storage accounts don't need to match their resource group's region, so an already-created resource group in a restricted region (e.g. `tfplatform-state-rg` in `westeurope`) is still fine to keep using.

## Prerequisites

- `az` CLI, logged into your **personal** Azure account (confirmed above)
- `terraform` CLI (>= 1.9.0)
- `gh` CLI — you have two accounts logged in; switch to the personal one:
  ```bash
  gh auth switch --user lucchmielowski
  gh auth status   # confirm "Active account: true" for lucchmielowski
  ```

Everything in this section is run by hand, once. Nothing here is automated by me or by Terraform — see "Why the bootstrap steps are manual" below.

## 1. Bootstrap remote state storage

Terraform's own state has to live somewhere before Terraform can run — it can't create the storage that holds its own state (chicken-and-egg), so this is plain `az` CLI.

```bash
LOCATION=northeurope
STATE_RG=tfplatform-state-rg
STATE_SA=tfplatformstate$RANDOM   # must be globally unique, 3-24 lowercase alphanumeric

az group create --name "$STATE_RG" --location "$LOCATION"

az storage account create \
  --name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --min-tls-version TLS1_2

az storage container create \
  --account-name "$STATE_SA" \
  --name tfstate \
  --auth-mode login
```

Note `$STATE_RG` and `$STATE_SA` — you'll need them for `TF_BACKEND_RESOURCE_GROUP` / `TF_BACKEND_STORAGE_ACCOUNT` below and for your first local `terraform init`.

## 2. OIDC: let GitHub Actions authenticate without a stored secret

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
GH_USER=lucchmielowski
REPO=terraform-platform

APP_ID=$(az ad app create --display-name "terraform-platform-gh-oidc" --query appId -o tsv)
az ad sp create --id "$APP_ID"

# One federated credential per trigger type this workflow actually uses.
az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"gh-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${GH_USER}/${REPO}:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"

az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"gh-pull-request\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${GH_USER}/${REPO}:pull_request\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

Now create the mock resource group and scope the role assignment to it — **not** to the whole subscription, following a least-privilege pattern for per-environment SPNs:

```bash
MOCK_RG=tfplatform-rg
az group create --name "$MOCK_RG" --location "$LOCATION"

az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MOCK_RG}"
```

`infra/main.tf` creates this same resource group via Terraform (`azurerm_resource_group.this`) — that's fine, `az group create` here is just to have somewhere to scope the role assignment to before Terraform's first run; Terraform will manage it going forward (no import needed if the name matches and it's still empty, or just delete it and let the first apply create it fresh — either works).

Note `$APP_ID`, `$SUBSCRIPTION_ID`, `$TENANT_ID` for the GitHub environment variables below.

**Note**: this sandbox uses the *same* SPN for both the `sandbox` (plan) and `sandbox-apply` (apply) environments. A more locked-down setup would give the plan job only read access, so a malicious or buggy branch can't mutate anything from the ungated side — worth trying here too, but not required for the four mechanisms in scope.

## 3. Create the GitHub repo and push

```bash
cd /Users/lucchmielowski/Projects/terraform-platform
git init
git add .
git commit -m "Initial scaffold"

gh repo create "${GH_USER}/${REPO}" --private --source=. --remote=origin
git push -u origin main
```

## 4. Configure GitHub Environments

Two environments, using a dual `{env}` / `{env}-apply` pattern — this is what actually gives you the manual-approval gate to click through when testing.

```bash
gh api --method PUT "repos/${GH_USER}/${REPO}/environments/sandbox"
gh api --method PUT "repos/${GH_USER}/${REPO}/environments/sandbox-apply" \
  -f "reviewers[][type]=User" -F "reviewers[][id]=$(gh api user --jq .id)"
```

The second command sets yourself as the required reviewer on `sandbox-apply` — if it errors on the array syntax, just do it once by hand: repo **Settings → Environments → sandbox-apply → Required reviewers → add yourself**.

Then set the same five variables on **both** environments (Settings → Environments → `<env>` → Environment variables):

| Variable | Value |
|---|---|
| `ARM_CLIENT_ID` | `$APP_ID` from step 2 |
| `ARM_SUBSCRIPTION_ID` | `$SUBSCRIPTION_ID` from step 2 |
| `ARM_TENANT_ID` | `$TENANT_ID` from step 2 |
| `TF_BACKEND_RESOURCE_GROUP` | `$STATE_RG` from step 1 |
| `TF_BACKEND_STORAGE_ACCOUNT` | `$STATE_SA` from step 1 |

## 5. First local init (and commit the lock file)

```bash
cd infra
terraform init \
  -backend-config="resource_group_name=${STATE_RG}" \
  -backend-config="storage_account_name=${STATE_SA}"
terraform fmt -check
terraform validate
cd ..
git add infra/.terraform.lock.hcl
git commit -m "Add terraform provider lock file"
git push
```

Committing `.terraform.lock.hcl` means CI resolves the exact same provider versions you just tested locally.

## 6. First run

Open a PR that touches `infra/main.tf` (e.g. add a tag), or just push to `main` / run `workflow_dispatch` on **Terraform Plan & Apply**. Watch the `plan` job comment on the PR, then approve the `sandbox-apply` gate to actually create the resources.

## Why the bootstrap steps are manual

The storage account holding remote state can't be created by the Terraform it backs, and the OIDC trust has to exist before any workflow can authenticate at all. Everything past this point (the actual resource group + storage account under test) is Terraform-managed.

## Things to try

Once the pipeline is live, these exercise the four mechanisms this sandbox exists to validate:

- **Concurrency**: push two commits to a PR in quick succession. The first `plan` run should show **cancelled** in the Actions tab, not queued or racing the second.
- **Saved-plan staleness (the actual "lock" fix)**: open a PR, let it plan, don't approve the apply yet. In another terminal, drift the resource out-of-band:
  ```bash
  az storage account update --name <storage-account-name> --resource-group tfplatform-rg --set tags.manual=drift
  ```
  Now approve the apply. It should **fail** with Terraform's native `Saved plan is stale` error instead of silently applying — that's the mechanism that prevents "someone else's apply erasing my reviewed changes."
- **PR comment**: push a second commit to the same PR. The existing plan comment should update in place, not get duplicated.
- **Drift detection**: after drifting the tag as above, run the **Drift Detect** workflow manually (`workflow_dispatch`). Confirm the job summary shows the drift and a GitHub issue labeled `drift` gets opened. Fix the drift (re-run the apply, or revert the tag by hand) and re-run drift-detect — the issue should get a closing comment and close automatically.

## Cost

Resource group: free. Two `Standard_LRS` storage accounts (state + mock resource) with negligible data: a few cents a month combined. Nowhere close to the $200 credit even left running for a while — but there's no harm in tearing it down when you're done:

```bash
az group delete --name tfplatform-rg --yes --no-wait
az group delete --name tfplatform-state-rg --yes --no-wait
az ad app delete --id "$APP_ID"
```
