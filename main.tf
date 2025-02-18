data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "automation" {
  count = var.use_existing_rg == true ? 1 : 0
  name  = var.aa_rg
}

resource "azurerm_resource_group" "automation" {
  count    = var.use_existing_rg == true ? 0 : 1
  name     = var.aa_rg
  location = var.location
  tags     = var.rg_tags
}

data "azurerm_automation_account" "automation" {
  count               = var.use_existing_aa == true ? 1 : 0
  name                = var.aa_name
  resource_group_name = var.use_existing_rg == true ? data.azurerm_resource_group.automation[0].name : azurerm_resource_group.automation[0].name
}

resource "azurerm_automation_account" "automation" {
  count               = var.use_existing_aa == true ? 0 : 1
  name                = var.aa_name
  resource_group_name = var.use_existing_rg == true ? data.azurerm_resource_group.automation[0].name : azurerm_resource_group.automation[0].name
  location            = var.location
  identity {
    type = "SystemAssigned"
  }

  sku_name = var.aa_sku

  tags = var.aa_tags
}

resource "azurerm_automation_schedule" "bimonthly" {
  name                    = var.schedule_name
  resource_group_name     = var.use_existing_rg == true ? data.azurerm_resource_group.automation[0].name : azurerm_resource_group.automation[0].name
  automation_account_name = var.use_existing_aa == true ? data.azurerm_automation_account.automation[0].name : azurerm_automation_account.automation[0].name
  frequency               = var.schedule_frequency
  interval                = var.schedule_interval
  timezone                = var.schedule_timezone
  description             = var.schedule_description
}


resource "azurerm_automation_powershell72_module" "posh_acme" {
  name                  = "Posh-ACME"
  automation_account_id = var.use_existing_aa == true ? data.azurerm_automation_account.automation[0].id : azurerm_automation_account.automation[0].id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Posh-ACME/${var.posh_acme_version}"
  }
}

data "azurerm_key_vault" "kv" {
  count               = var.use_existing_kv == true ? 1 : 0
  name                = var.kv_name
  resource_group_name = var.kv_rg
}

resource "azurerm_key_vault" "kv" {
  count                       = var.use_existing_kv == true ? 0 : 1
  name                        = var.kv_name
  location                    = var.location
  resource_group_name         = var.use_existing_rg == true ? data.azurerm_resource_group.automation[0].name : azurerm_resource_group.automation[0].name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = var.kv_delete_retention
  purge_protection_enabled    = var.kv_purge_protection

  sku_name = var.kv_sku

  enable_rbac_authorization = true
}

resource "azurerm_role_assignment" "kv" {
  count                = var.use_existing_kv == true ? 0 : 1
  scope                = azurerm_key_vault.kv[0].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id

  lifecycle {
    ignore_changes = [
      principal_id #to avoid intial role assignment to be rewritten when alternating between local run and CI run with different principals, changes are ignored
    ]
  }
}

resource "random_password" "posh_acme" {
  length           = 16
  special          = true
  override_special = "@!-+[]"
}

resource "azurerm_key_vault_secret" "posh_acme" {
  name         = "posh-acme"
  value        = random_password.posh_acme.result
  key_vault_id = var.use_existing_kv == true ? data.azurerm_key_vault.kv[0].id : azurerm_key_vault.kv[0].id

  lifecycle {
    ignore_changes = [value]
  }
  depends_on = [azurerm_role_assignment.kv] #local.check_role_dependency
}

resource "azurerm_automation_runbook" "acme_le" {
  for_each                = var.certs
  name                    = "letsencrypt_${each.key}"
  resource_group_name     = var.use_existing_rg == true ? data.azurerm_resource_group.automation[0].name : azurerm_resource_group.automation[0].name
  location                = var.location
  automation_account_name = var.use_existing_aa == true ? data.azurerm_automation_account.automation[0].name : azurerm_automation_account.automation[0].name

  log_verbose  = "false" #"true"
  log_progress = "true"
  description  = "Powershell script using posh-acme to generate letsencrypt certificates"
  runbook_type = "PowerShell72"

  content = templatefile("${path.module}/assets/acme.ps1.tmpl", {
    subid       = data.azurerm_client_config.current.subscription_id,
    ca          = each.value.ca,
    cn          = each.value.cn,
    sans        = each.value.sans,
    contact     = each.value.contact,
    vault_name  = var.use_existing_kv == true ? data.azurerm_key_vault.kv[0].name : azurerm_key_vault.kv[0].name,
    secret_name = each.key
  })
}

data "azurerm_dns_zone" "automation_dns" {
  for_each            = var.certs
  name                = each.value.dns_zone_name
  resource_group_name = each.value.dns_zone_rg
}
resource "azurerm_role_assignment" "automation_dns" {
  for_each             = var.certs
  scope                = data.azurerm_dns_zone.automation_dns[each.key].id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = var.use_existing_aa == true ? data.azurerm_automation_account.automation[0].identity[0].principal_id : azurerm_automation_account.automation[0].identity[0].principal_id
}
