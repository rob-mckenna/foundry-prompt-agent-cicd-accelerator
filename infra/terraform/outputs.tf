output "foundry_account_name" {
  description = "Foundry account name. Use for config/environments/<env>.json foundry.accountName."
  value       = azurerm_cognitive_account.foundry.name
}

output "foundry_project_name" {
  description = "Foundry project name. Use for foundry.projectName."
  value       = azapi_resource.foundry_project.name
}

output "foundry_project_endpoint" {
  description = "Agent Service data plane endpoint. Use verbatim for foundry.projectEndpoint."
  value       = "https://${azurerm_cognitive_account.foundry.custom_subdomain_name}.services.ai.azure.com/api/projects/${azapi_resource.foundry_project.name}"
}

output "foundry_project_principal_id" {
  description = "Managed identity principal id of the project. Grant it access to any data source the agents read."
  value       = local.project_principal_id
}

output "key_vault_name" {
  description = "Key Vault name. Use for keyVault.name."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI. Use for keyVault.uri."
  value       = azurerm_key_vault.this.vault_uri
}

output "release_store_account_name" {
  description = "Storage account holding release records. Use for releaseStore.accountName."
  value       = azurerm_storage_account.this.name
}

output "queue_service_endpoint" {
  description = "Queue service endpoint. Use for the FUNCTION_QUEUE_ENDPOINT overlay variable."
  value       = azurerm_storage_account.this.primary_queue_endpoint
}

output "ai_search_endpoint" {
  description = "Azure AI Search endpoint, empty when deploy_ai_search is false."
  value       = var.deploy_ai_search ? "https://${azurerm_search_service.this[0].name}.search.windows.net" : ""
}

output "application_insights_connection_string" {
  description = "Application Insights connection string for agent telemetry dashboards."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "model_deployment_names" {
  description = "Model deployment names available to agent overlays."
  value       = [for deployment in azurerm_cognitive_deployment.model : deployment.name]
}
