resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-rg"
  location = var.location

  tags = {
    purpose    = "terraform-platform-sandbox"
    managed_by = "terraform"
  }
}

# Storage account names must be globally unique, 3-24 lowercase alphanumeric
# characters - random_id sidesteps picking a name by hand.
resource "random_id" "storage_suffix" {
  byte_length = 4
}

resource "azurerm_storage_account" "this" {
  name                = "${var.name_prefix}${random_id.storage_suffix.hex}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = {
    purpose    = "terraform-platform-sandbox"
    managed_by = "terraform"
    new_tag    = "test"
  }
}
