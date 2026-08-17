package main

import rego.v1

# Evaluated against `terraform show -json tfplan` by conftest - see
# .github/workflows/plan-apply.yml. Each rule inspects `resource_changes`,
# which covers creates and updates (the state *after* this plan applies),
# so a deny here means "this plan would leave real infrastructure violating
# the rule", not just "the current .tf text looks wrong".

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "azurerm_storage_account"
	rc.change.after.min_tls_version != "TLS1_2"
	msg := sprintf("%s: min_tls_version must be \"TLS1_2\" (got %q)", [rc.address, rc.change.after.min_tls_version])
}

deny contains msg if {
	some rc in input.resource_changes
	rc.change.after.tags
	not rc.change.after.tags.managed_by
	msg := sprintf("%s: missing required tag \"managed_by\"", [rc.address])
}
