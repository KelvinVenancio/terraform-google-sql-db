/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  master_instance_name     = var.random_instance_name ? "${var.name}-${random_id.suffix[0].hex}" : var.name
  ip_configuration_enabled = length(keys(var.ip_configuration)) > 0 ? true : false

  ip_configurations = {
    enabled  = var.ip_configuration
    disabled = {}
  }

  databases = { for db in var.additional_databases : db.name => db }
  users     = { for u in var.additional_users : u.name => u }

  // HA method using REGIONAL availability_type requires binary logs to be enabled
  binary_log_enabled = var.availability_type == "REGIONAL" ? true : lookup(var.backup_configuration, "binary_log_enabled", null)
  backups_enabled    = var.availability_type == "REGIONAL" ? true : lookup(var.backup_configuration, "enabled", null)

  retained_backups = lookup(var.backup_configuration, "retained_backups", null)
  retention_unit   = lookup(var.backup_configuration, "retention_unit", null)
}

resource "random_id" "suffix" {
  count = var.random_instance_name ? 1 : 0

  byte_length = 4
}

resource "google_sql_database_instance" "default" {
  provider            = google-beta
  project             = var.project_id
  name                = local.master_instance_name
  database_version    = var.database_version
  region              = var.region
  encryption_key_name = var.encryption_key_name
  deletion_protection = var.deletion_protection

  settings {
    tier                        = var.tier
    activation_policy           = var.activation_policy
    availability_type           = var.availability_type
    deletion_protection_enabled = var.deletion_protection_enabled
    dynamic "backup_configuration" {
      for_each = [var.backup_configuration]
      content {
        binary_log_enabled             = local.binary_log_enabled
        enabled                        = local.backups_enabled
        start_time                     = lookup(backup_configuration.value, "start_time", null)
        location                       = lookup(backup_configuration.value, "location", null)
        transaction_log_retention_days = lookup(backup_configuration.value, "transaction_log_retention_days", null)

        dynamic "backup_retention_settings" {
          for_each = local.retained_backups != null || local.retention_unit != null ? [var.backup_configuration] : []
          content {
            retained_backups = local.retained_backups
            retention_unit   = local.retention_unit
          }
        }
      }
    }
    dynamic "insights_config" {
      for_each = var.insights_config != null ? [var.insights_config] : []

      content {
        query_insights_enabled  = true
        query_string_length     = lookup(insights_config.value, "query_string_length", 1024)
        record_application_tags = lookup(insights_config.value, "record_application_tags", false)
        record_client_address   = lookup(insights_config.value, "record_client_address", false)
      }
    }
    dynamic "deny_maintenance_period" {
      for_each = var.deny_maintenance_period
      content {
        end_date   = lookup(deny_maintenance_period.value, "end_date", null)
        start_date = lookup(deny_maintenance_period.value, "start_date", null)
        time       = lookup(deny_maintenance_period.value, "time", null)
      }
    }
    dynamic "ip_configuration" {
      for_each = [local.ip_configurations[local.ip_configuration_enabled ? "enabled" : "disabled"]]
      content {
        ipv4_enabled       = lookup(ip_configuration.value, "ipv4_enabled", null)
        private_network    = lookup(ip_configuration.value, "private_network", null)
        require_ssl        = lookup(ip_configuration.value, "require_ssl", null)
        allocated_ip_range = lookup(ip_configuration.value, "allocated_ip_range", null)

        dynamic "authorized_networks" {
          for_each = lookup(ip_configuration.value, "authorized_networks", [])
          content {
            expiration_time = lookup(authorized_networks.value, "expiration_time", null)
            name            = lookup(authorized_networks.value, "name", null)
            value           = lookup(authorized_networks.value, "value", null)
          }
        }
      }
    }

    disk_autoresize       = var.disk_autoresize
    disk_autoresize_limit = var.disk_autoresize_limit

    disk_size    = var.disk_size
    disk_type    = var.disk_type
    pricing_plan = var.pricing_plan
    user_labels  = var.user_labels
    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = lookup(database_flags.value, "name", null)
        value = lookup(database_flags.value, "value", null)
      }
    }

    location_preference {
      zone                   = var.zone
      secondary_zone         = var.secondary_zone
      follow_gae_application = var.follow_gae_application
    }

    maintenance_window {
      day          = var.maintenance_window_day
      hour         = var.maintenance_window_hour
      update_track = var.maintenance_window_update_track
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size
    ]
  }

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }

  depends_on = [null_resource.module_depends_on]
}

resource "google_sql_database" "default" {
  count      = var.enable_default_db ? 1 : 0
  name       = var.db_name
  project    = var.project_id
  instance   = google_sql_database_instance.default.name
  charset    = var.db_charset
  collation  = var.db_collation
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "google_sql_database" "additional_databases" {
  for_each   = local.databases
  project    = var.project_id
  name       = each.value.name
  charset    = lookup(each.value, "charset", null)
  collation  = lookup(each.value, "collation", null)
  instance   = google_sql_database_instance.default.name
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "random_password" "user-password" {
  keepers = {
    name = google_sql_database_instance.default.name
  }

  length     = 32
  special    = false
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "random_password" "additional_passwords" {
  for_each = local.users
  keepers = {
    name = google_sql_database_instance.default.name
  }
  length     = 32
  special    = true
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "google_sql_user" "default" {
  count    = var.enable_default_user ? 1 : 0
  name     = var.user_name
  project  = var.project_id
  instance = google_sql_database_instance.default.name
  host     = var.user_host
  password = var.user_password == "" ? random_password.user-password.result : var.user_password
  depends_on = [
    null_resource.module_depends_on,
    google_sql_database_instance.default,
    google_sql_database_instance.replicas,
  ]
}

resource "google_sql_user" "additional_users" {
  for_each = local.users
  project  = var.project_id
  name     = each.value.name
  password = each.value.random_password ? random_password.additional_passwords[each.value.name].result : each.value.password
  host     = each.value.host == null ? var.user_host : each.value.host
  instance = google_sql_database_instance.default.name
  type     = coalesce(each.value.type, "BUILT_IN")
  depends_on = [
    null_resource.module_depends_on,
    google_sql_database_instance.default,
    google_sql_database_instance.replicas,
  ]
}

resource "null_resource" "module_depends_on" {
  triggers = {
    value = length(var.module_depends_on)
  }
}
