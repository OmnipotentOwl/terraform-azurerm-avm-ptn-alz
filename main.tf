data "alz_archetype_keys" "this" {
  base_archetype                   = var.base_archetype
  policy_assignments_to_add        = keys(var.policy_assignments_to_add)
  policy_assignments_to_remove     = var.policy_assignments_to_remove
  policy_definitions_to_add        = var.policy_definitions_to_add
  policy_definitions_to_remove     = var.policy_definitions_to_remove
  policy_set_definitions_to_add    = var.policy_set_definitions_to_add
  policy_set_definitions_to_remove = var.policy_set_definitions_to_remove
  role_definitions_to_add          = var.role_definitions_to_add
  role_definitions_to_remove       = var.role_definitions_to_remove
}

data "alz_archetype" "this" {
  id = var.id
  defaults = {
    location                           = var.default_location
    log_analytics_workspace_id         = var.default_log_analytics_workspace_id
    private_dns_zone_resource_group_id = var.default_private_dns_zone_resource_group_id
  }
  display_name                     = var.display_name
  base_archetype                   = var.base_archetype
  parent_id                        = var.parent_id
  policy_assignments_to_add        = var.policy_assignments_to_add
  policy_assignments_to_remove     = var.policy_assignments_to_remove
  policy_definitions_to_add        = var.policy_definitions_to_add
  policy_definitions_to_remove     = var.policy_definitions_to_remove
  policy_set_definitions_to_add    = var.policy_set_definitions_to_add
  policy_set_definitions_to_remove = var.policy_set_definitions_to_remove
  role_definitions_to_add          = var.role_definitions_to_add
  role_definitions_to_remove       = var.role_definitions_to_remove
}

resource "azurerm_management_group" "this" {
  name                       = data.alz_archetype.this.id
  display_name               = data.alz_archetype.this.display_name
  parent_management_group_id = format("/providers/Microsoft.Management/managementGroups/%s", data.alz_archetype.this.parent_id)

  depends_on = [time_sleep.before_management_group_creation]
}

data "azurerm_subscription" "this" {
  for_each        = var.subscription_ids
  subscription_id = each.key
}

resource "azurerm_management_group_subscription_association" "this" {
  for_each            = var.subscription_ids
  management_group_id = azurerm_management_group.this.id
  subscription_id     = data.azurerm_subscription.this[each.key].id
}

resource "azurerm_policy_definition" "this" {
  for_each = local.alz_policy_definitions_decoded

  name                = each.key
  description         = try(each.value.properties.description, "")
  display_name        = try(each.value.properties.displayName, "")
  policy_type         = try(each.value.properties.policyType, "Custom")
  mode                = each.value.properties.mode
  management_group_id = azurerm_management_group.this.id
  metadata            = jsonencode(try(each.value.properties.metadata, {}))
  policy_rule         = jsonencode(try(each.value.properties.policyRule, {}))
  parameters          = try(each.value.properties.parameters, null) != null && try(each.value.properties.parameters, {}) != {} ? jsonencode(each.value.properties.parameters) : null
}

resource "azurerm_policy_set_definition" "this" {
  for_each = local.alz_policy_set_definitions_decoded

  name                = each.key
  display_name        = try(each.value.properties.displayName, "")
  policy_type         = try(each.value.properties.policyType, "Custom")
  management_group_id = azurerm_management_group.this.id
  metadata            = jsonencode(try(each.value.properties.metadata, {}))
  parameters          = try(each.value.properties.parameters, null) != null && try(each.value.properties.parameters, {}) != {} ? jsonencode(each.value.properties.parameters) : null

  depends_on = [azurerm_policy_definition.this]

  dynamic "policy_definition_reference" {
    for_each = try(each.value.properties.policyDefinitions, [])

    content {
      policy_definition_id = policy_definition_reference.value.policyDefinitionId
      parameter_values     = try(jsonencode(policy_definition_reference.value.parameters), jsonencode({}))
      policy_group_names   = try(policy_definition_reference.value.groupNames, [])
      reference_id         = try(policy_definition_reference.value.policyDefinitionReferenceId, "")
    }
  }

  dynamic "policy_definition_group" {
    for_each = try(each.value.properties.policyDefinitionGroups, [])

    content {
      name                            = policy_definition_group.value.name
      display_name                    = try(policy_definition_group.value.displayName, "")
      description                     = try(policy_definition_group.value.description, "")
      category                        = try(policy_definition_group.value.category, "")
      additional_metadata_resource_id = try(policy_definition_group.value.additionalMetadataId, "")
    }
  }
}

resource "azurerm_management_group_policy_assignment" "this" {
  for_each = local.alz_policy_assignments_decoded

  name                 = each.key
  management_group_id  = azurerm_management_group.this.id
  policy_definition_id = each.value.properties.policyDefinitionId
  display_name         = try(each.value.properties.displayName, "")
  description          = try(each.value.properties.description, "")
  enforce              = try(each.value.properties.enforce, "Default") == "Default" ? true : false
  metadata             = jsonencode(try(each.value.properties.metadata, {}))
  parameters           = try(each.value.properties.parameters, null) != null && try(each.value.properties.parameters, {}) != {} ? jsonencode(each.value.properties.parameters) : null
  location             = try(each.value.location, null)
  not_scopes           = try(each.value.properties.notScopes, [])

  depends_on = [time_sleep.before_policy_assignments]

  dynamic "identity" {
    for_each = try(each.value.identity.type, "None") != "None" ? [each.value.identity] : []

    content {
      type         = identity.value.type
      identity_ids = identity.value.type == "SystemAssigned" ? [] : toset(keys(identity.value.userAssignedIdentities))
    }
  }

  dynamic "non_compliance_message" {
    for_each = try(each.value.properties.nonComplianceMessages, [])

    content {
      content                        = non_compliance_message.value.message
      policy_definition_reference_id = try(non_compliance_message.value.policyDefinitionReferenceId, null)
    }
  }

  dynamic "resource_selectors" {
    for_each = try(each.value.properties.resourceSelectors, [])

    content {
      name = resource_selectors.value.name

      dynamic "selectors" {
        for_each = try(resource_selectors.value.selectors, [])

        content {
          kind   = selectors.value.kind
          in     = try(selectors.value.in, null)
          not_in = try(selectors.value.notIn, null)
        }
      }
    }
  }

  dynamic "overrides" {
    for_each = try(each.value.properties.overrides, [])

    content {
      value = overrides.value.value

      dynamic "selectors" {
        for_each = try(overrides.value.selectors, [])

        content {
          in     = try(selectors.value.in, null)
          not_in = try(selectors.value.notIn, null)
        }
      }
    }
  }
}

resource "azurerm_role_definition" "this" {
  for_each = local.alz_role_definitions_decoded

  name        = each.key
  description = try(each.value.properties.description, null)
  scope       = azurerm_management_group.this.id
  permissions {
    actions          = try(one(each.value.properties.permissions).actions, [])
    not_actions      = try(one(each.value.properties.permissions).notActions, [])
    data_actions     = try(one(each.value.properties.permissions).dataActions, [])
    not_data_actions = try(one(each.value.properties.permissions).notDataActions, [])
  }
  assignable_scopes = try(each.value.properties.assignableScopes, [])
}

resource "azurerm_role_assignment" "this" {
  for_each             = var.role_assignments
  scope                = azurerm_management_group.this.id
  principal_id         = each.value.principal_id
  role_definition_id   = each.value.role_definition_id != "" ? each.value.role_definition_id : null
  role_definition_name = each.value.role_definition_name != "" ? each.value.role_definition_name : null
  description          = each.value.description
}

resource "alz_policy_role_assignments" "this" {
  id          = data.alz_archetype.this.id
  assignments = local.policy_role_assignments
  depends_on  = [time_sleep.before_policy_role_assignments]
}

resource "time_sleep" "before_management_group_creation" {
  create_duration  = var.delays.before_management_group.create
  destroy_duration = var.delays.before_management_group.destroy
}

resource "time_sleep" "before_policy_assignments" {
  count            = local.alz_policy_assignments_decoded != {} ? 1 : 0
  create_duration  = var.delays.before_policy_assignments.create
  destroy_duration = var.delays.before_policy_assignments.destroy
  triggers = {
    policy_definitions     = jsonencode(azurerm_policy_definition.this)
    policy_set_definitions = jsonencode(azurerm_policy_set_definition.this)
  }

  depends_on = [
    azurerm_policy_definition.this,
    azurerm_policy_set_definition.this,
  ]
}

resource "time_sleep" "before_policy_role_assignments" {
  count            = local.alz_policy_assignments_decoded != {} ? 1 : 0
  create_duration  = var.delays.before_policy_role_assignments.create
  destroy_duration = var.delays.before_policy_role_assignments.destroy

  triggers = {
    policy_assignments = jsonencode(azurerm_management_group_policy_assignment.this)
  }

  depends_on = [azurerm_management_group_policy_assignment.this]
}
