variable "subscription_id" {
  description = "Target subscription id. Supply through TF_VAR_subscription_id or ARM_SUBSCRIPTION_ID; do not commit it."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "workload_name" {
  description = "Short workload name used to build resource names. Lowercase letters and digits only."
  type        = string
  default     = "fndagents"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.workload_name))
    error_message = "workload_name must be 3-12 lowercase letters or digits."
  }
}

variable "environment_name" {
  description = "Environment short name."
  type        = string

  validation {
    condition     = contains(["dev", "test", "uat", "prod"], var.environment_name)
    error_message = "environment_name must be one of dev, test, uat, prod."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group to create or reuse."
  type        = string
}

variable "create_resource_group" {
  description = "Create the resource group. Set to false when the landing zone already provides it."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "model_deployments" {
  description = "Model deployments created on the Foundry account. The name is what agent overlays reference as model.deploymentName."
  type = list(object({
    name          = string
    model_name    = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default = [
    {
      name          = "gpt-4o-mini"
      model_name    = "gpt-4o-mini"
      model_version = "2024-07-18"
      sku_name      = "GlobalStandard"
      capacity      = 30
    }
  ]
}

variable "deploy_ai_search" {
  description = "Deploy an Azure AI Search service for retrieval augmented agents."
  type        = bool
  default     = false
}

variable "ai_search_sku" {
  description = "Azure AI Search SKU."
  type        = string
  default     = "basic"

  validation {
    condition     = contains(["basic", "standard", "standard2", "standard3"], var.ai_search_sku)
    error_message = "ai_search_sku must be basic, standard, standard2 or standard3."
  }
}

variable "deployment_principal_id" {
  description = "Object id of the CI/CD workload identity service principal. Empty disables the related role assignments."
  type        = string
  default     = ""
}

variable "agent_operator_principal_id" {
  description = "Object id of the Entra ID group of human agent operators. Empty disables the related role assignment."
  type        = string
  default     = ""
}

variable "public_network_access_enabled" {
  description = "Allow public network access to the Foundry account. Set false only when private endpoints are already in place."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}