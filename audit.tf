/**
 * Copyright 2023 Google LLC
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

# Create dataset for monitoring
module "bigquery_audit" {
  source = "github.com/terraform-google-modules/terraform-google-bigquery?ref=v6.1.1"

  project_id   = module.project_services.project_id
  dataset_id   = each.value
  dataset_name = each.value
  description  = "Dataset ${each.value} created by terraform"
  location     = var.bq_location

  # List of datasets to create
  for_each = toset([var.monitoring_dataset])
}

# Create audit table outline.
# This table contains just the fields needed for materialized views. The actual audit
# table will be expanded for all new columns once data starts flowing in.
resource "google_bigquery_table" "cloudaudit_table" {

  # Only create table after the dataset is created
  depends_on = [
    module.bigquery_audit
  ]

  dataset_id    = var.monitoring_dataset
  table_id      = "cloudaudit_googleapis_com_data_access"
  friendly_name = "cloudaudit_googleapis_com_data_access"
  project       = module.project_services.project_id

  labels              = {}
  schema              = file("${path.module}/audit_schema.json")
  deletion_protection = false

  time_partitioning {
    type                     = "DAY"
    expiration_ms            = null
    field                    = "timestamp"
    require_partition_filter = false
  }

  lifecycle {
    ignore_changes = [
      encryption_configuration, # managed by google_bigquery_dataset.main.default_encryption_configuration
      schema                    # logs router will expand the schema
    ]
  }
}


# Create the materialized view on the audit table
#
# This materialized view will extract and format common JSON fields for BigQuery audit logs,
# including DBT metadata.
#
data "template_file" "bigquery_jobs_view" {
  template = file("${path.module}/bigquery_jobs_view.sql")
  vars = {
    monitoring_dataset = var.monitoring_dataset
  }
}

resource "google_bigquery_table" "bigquery_materialized_view" {
  project             = module.project_services.project_id
  dataset_id          = var.monitoring_dataset
  friendly_name       = "bigquery_jobs"
  table_id            = "bigquery_jobs"
  description         = "BigQuery jobs (with DBT extras) logical view"
  deletion_protection = false

  #time_partitioning {
  #  field = "job_stats.create_time"
  #  type  = "DAY"
  #}

  materialized_view {
    query = data.template_file.bigquery_jobs_view.rendered
  }

  depends_on = [
    google_bigquery_table.cloudaudit_table
  ]

  lifecycle {
    ignore_changes = [
      encryption_configuration
    ]
  }
}

# Create the next level view on the materialized view.
#
# This view will extract DBT-job-level metadata and bring it to
# all of the individual DBT jobs.
data "template_file" "dbt_jobs_view" {
  template = file("${path.module}/dbt_jobs_view.sql")
  vars = {
    monitoring_dataset = var.monitoring_dataset
  }
}

resource "google_bigquery_table" "dbt_view" {
  project             = module.project_services.project_id
  dataset_id          = var.monitoring_dataset
  friendly_name       = "dbt_jobs"
  table_id            = "dbt_jobs"
  description         = "DBT jobs (with DBT metadata) logical view"
  deletion_protection = false

  view {
    query          = data.template_file.dbt_jobs_view.rendered
    use_legacy_sql = false
  }

  depends_on = [
    google_bigquery_table.bigquery_materialized_view
  ]

  #lifecycle {
  #  ignore_changes = [
  #    encryption_configuration
  #  ]
  #}
}


# Create the audit level sink into BigQuery
#
resource "google_logging_project_sink" "cloud_audit_sink" {
  name                   = "bigquery_audit_export"
  project                = module.project_services.project_id
  filter                 = "protoPayload.metadata.\"@type\"=\"type.googleapis.com/google.cloud.audit.BigQueryAuditMetadata\""
  destination            = "bigquery.googleapis.com/projects/${module.project_services.project_id}/datasets/${var.monitoring_dataset}"
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
  depends_on = [
    google_bigquery_table.cloudaudit_table
  ]
}

resource "google_project_iam_member" "bigquery_sink_member" {
  project = module.project_services.project_id
  role    = "roles/bigquery.dataEditor"
  member  = element(concat(google_logging_project_sink.cloud_audit_sink[*].writer_identity, [""]), 0)
}

