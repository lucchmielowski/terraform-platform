terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend config on purpose: resource_group_name / storage_account_name / key
  # are supplied via `terraform init -backend-config=...` in CI (and locally), so this
  # file never hardcodes a specific state account.
  backend "azurerm" {
    container_name = "tfstate"
    key            = "terraform-platform.tfstate"
  }
}

provider "azurerm" {
  features {}
}
