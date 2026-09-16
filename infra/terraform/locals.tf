locals {
  base_name = lower("${var.workload_name}${var.environment_name}")
  suffix    = substr(sha1("${var.subscription_id}-${var.resource_group_name}-${local.base_name}"), 0, 8)

  resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  location            = var.create_resource_group ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.existing[0].location

  foundry_account_name = substr("aif${local.base_name}${local.suffix}", 0, 24)
  foundry_project_name = "proj-${var.workload_name}-${var.environment_name}"
  key_vault_name       = substr("kv-${local.base_name}-${local.suffix}", 0, 24)
  storage_account_name = substr("st${local.base_name}${local.suffix}", 0, 24)
  search_service_name  = substr("srch-${local.base_name}-${local.suffix}", 0, 60)

  common_tags = merge({
    workload    = var.workload_name
    environment = var.environment_name
    managedBy   = "foundry-prompt-agent-cicd-accelerator"
  }, var.tags)

  # Built-in role definition names used with azurerm_role_assignment.
  roles = {
    key_vault_secrets_user         = "Key Vault Secrets User"
    storage_blob_data_contributor  = "Storage Blob Data Contributor"
    storage_queue_data_contributor = "Storage Queue Data Contributor"
    search_index_data_reader       = "Search Index Data Reader"
    azure_ai_user                  = "Azure AI User"
  }

  release_containers = ["agent-releases", "agent-packages"]
  function_queues    = ["entitlement-input", "entitlement-output"]
}