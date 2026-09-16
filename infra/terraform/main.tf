data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base_name}-${local.suffix}"
  resource_group_name = local.resource_group_name
  location            = local.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.common_tags
}

resource "azurerm_application_insights" "this" {
  name                         = "appi-${local.base_name}-${local.suffix}"
  resource_group_name          = local.resource_group_name
  location                     = local.location
  application_type             = "web"
  workspace_id                 = azurerm_log_analytics_workspace.this.id
  local_authentication_enabled = false
  tags                         = local.common_tags
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                          = local.key_vault_name
  resource_group_name           = local.resource_group_name
  location                      = local.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = true
  tags                          = local.common_tags

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# ---------------------------------------------------------------------------
# Release store and tool queues
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "this" {
  name                            = local.storage_account_name
  resource_group_name             = local.resource_group_name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # Entra ID only: no shared key or connection string can be issued or leaked.
  shared_access_key_enabled = false

  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "this" {
  for_each = toset(local.release_containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_queue" "this" {
  for_each = toset(local.function_queues)

  name               = each.value
  storage_account_id = azurerm_storage_account.this.id
}

# ---------------------------------------------------------------------------
# Knowledge
# ---------------------------------------------------------------------------

resource "azurerm_search_service" "this" {
  count = var.deploy_ai_search ? 1 : 0

  name                = local.search_service_name
  resource_group_name = local.resource_group_name
  location            = local.location
  sku                 = var.ai_search_sku
  replica_count       = 1
  partition_count     = 1
  semantic_search_sku = var.ai_search_sku == "basic" ? "free" : "standard"

  # Entra ID only: no admin or query keys are issued.
  local_authentication_enabled  = false
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure AI Foundry
# ---------------------------------------------------------------------------

resource "azurerm_cognitive_account" "foundry" {
  name                  = local.foundry_account_name
  resource_group_name   = local.resource_group_name
  location              = local.location
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = local.foundry_account_name

  local_auth_enabled            = false
  public_network_access_enabled = var.public_network_access_enabled

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# azurerm does not yet model allowProjectManagement, which turns an AIServices account into a
# Foundry account that can host projects. azapi sets it without recreating the account.
resource "azapi_update_resource" "enable_project_management" {
  type        = "Microsoft.CognitiveServices/accounts@2025-06-01"
  resource_id = azurerm_cognitive_account.foundry.id

  body = {
    properties = {
      allowProjectManagement = true
    }
  }
}

resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = local.foundry_project_name
  parent_id = azurerm_cognitive_account.foundry.id
  location  = local.location
  tags      = local.common_tags

  body = {
    properties = {
      displayName = "${var.workload_name} agents (${var.environment_name})"
      description = "Prompt agents deployed by the CI/CD accelerator."
    }
  }

  identity {
    type = "SystemAssigned"
  }

  response_export_values = ["identity.principalId", "properties.endpoints"]

  depends_on = [azapi_update_resource.enable_project_management]
}

resource "azurerm_cognitive_deployment" "model" {
  for_each = { for deployment in var.model_deployments : deployment.name => deployment }

  name                 = each.value.name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
  rai_policy_name        = "Microsoft.DefaultV2"
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "foundry" {
  name                       = "diag-to-law"
  target_resource_id         = azurerm_cognitive_account.foundry.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-to-law"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# Role assignments
# ---------------------------------------------------------------------------

locals {
  project_principal_id = azapi_resource.foundry_project.output.identity.principalId
}

resource "azurerm_role_assignment" "project_search_reader" {
  count = var.deploy_ai_search ? 1 : 0

  scope                = azurerm_search_service.this[0].id
  role_definition_name = local.roles.search_index_data_reader
  principal_id         = local.project_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "project_queue_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = local.roles.storage_queue_data_contributor
  principal_id         = local.project_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "project_key_vault_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = local.roles.key_vault_secrets_user
  principal_id         = local.project_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment_azure_ai_user" {
  count = var.deployment_principal_id == "" ? 0 : 1

  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = local.roles.azure_ai_user
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment_key_vault_secrets_user" {
  count = var.deployment_principal_id == "" ? 0 : 1

  scope                = azurerm_key_vault.this.id
  role_definition_name = local.roles.key_vault_secrets_user
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment_blob_contributor" {
  count = var.deployment_principal_id == "" ? 0 : 1

  scope                = azurerm_storage_account.this.id
  role_definition_name = local.roles.storage_blob_data_contributor
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "operator_azure_ai_user" {
  count = var.agent_operator_principal_id == "" ? 0 : 1

  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = local.roles.azure_ai_user
  principal_id         = var.agent_operator_principal_id
  principal_type       = "Group"
}
