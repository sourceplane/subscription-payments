terraform {
  required_version = ">= 1.15.0"

  # State lives on the platform (SB1): the runner exports TF_HTTP_* per job
  # (address = …/state/tfstate/{component}/{env}, run token as password), so
  # this block stays empty — no S3 bucket, no AWS role, no workspaces (the
  # environment is in the address).
  backend "http" {}

  required_providers {
    supabase = {
      source = "supabase/supabase"
      # Pinned below 1.6: from 1.6.0 the provider reads /billing/addons on
      # every project create/read, and Supabase does not serve billing
      # endpoints to OAuth tokens yet ("does not support oauth access") —
      # which is exactly the credential the platform brokers.
      version = "~> 1.5.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

# --- Providers ---

# Authenticates via the SUPABASE_ACCESS_TOKEN env var (provider-native): a
# short-lived Management-API token minted per run from the workspace's
# Supabase integration, resolved into the job env by orun.
provider "supabase" {}

# --- Variables (standard Orun parameters) ---

variable "orgName" {
  type    = string
  default = "sourceplane"
}

variable "owner" {
  type    = string
  default = "sourceplane"
}

variable "repo" {
  type    = string
  default = "subscription-payments"
}

variable "namespace" {
  type    = string
  default = "sourceplane"
}

variable "namespacePrefix" {
  type    = string
  default = ""
}

variable "lane" {
  type    = string
  default = "verify"
}

variable "environment" {
  type    = string
  default = "stage"
}

variable "component" {
  type    = string
  default = "supabase"
}

variable "stackName" {
  type    = string
  default = "supabase"
}

variable "terraformDir" {
  type    = string
  default = "terraform"
}

variable "terraformVersion" {
  type    = string
  default = "1.15.3"
}

# Supabase target identity. supabaseRegion comes from the component's
# `spec.parameters`; supabaseOrgId is injected as TF_VAR_supabaseOrgId from the
# workspace's SUPABASE_ORG_ID secret (org-id connection fact). Both are
# required (no default) so a missing value fails plan loudly instead of
# silently pointing at the wrong org or region.
variable "supabaseOrgId" {
  type = string
}

variable "supabaseRegion" {
  type = string
}

# The workers.dev subdomain the app's Worker answers on (the component's
# `workersDevSubdomain` parameter, surfaced as TF_VAR_workersDevSubdomain —
# the same value apps/web/component.yaml carries). Required, like the two
# above: Supabase Auth sends its links to this origin.
variable "workersDevSubdomain" {
  type = string
}

# Whether a new user must confirm their email before signing in (the
# component's `authEmailConfirmation` parameter). Off by default, because a
# fresh project sends email only to its organization's own members until it
# has an SMTP server of its own: with confirmation on, nobody else could sign
# up. Turn it on once SMTP is set (the product's README, "Supabase Auth
# email").
variable "authEmailConfirmation" {
  type    = bool
  default = false
}

# --- Locals ---

locals {
  supabase_org_id = var.supabaseOrgId
  supabase_region = var.supabaseRegion
  project_name    = "${var.repo}-${var.environment}"
  # The environment's Worker, as apps/web/component.yaml names it:
  # <repo>-web-<env> on the account's workers.dev subdomain.
  app_origin = "https://${var.repo}-web-${var.environment}.${var.workersDevSubdomain}.workers.dev"
}

# --- Generate database password ---

resource "random_password" "db_password" {
  length  = 32
  special = true
  # Avoid characters that cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}|:,.<>?"
}

# --- Supabase project ---

resource "supabase_project" "this" {
  organization_id   = local.supabase_org_id
  name              = local.project_name
  database_password = random_password.db_password.result
  region            = local.supabase_region
}

# --- Outputs ---
#
# Credentials leave this module ONLY through the outputs component.yaml's
# `secretOutputs` names, which the runner lease-publishes onto the project's
# environment rung after the apply (never argv, never a log): Lumen's three
# database credentials below, which db-migrate reads, and the `wiring`
# document further down, which the app's deploy reads. No Secrets Manager.

output "project_ref" {
  description = "Supabase project reference ID"
  value       = supabase_project.this.id
}

output "project_name" {
  description = "Supabase project name"
  value       = supabase_project.this.name
}

output "project_url" {
  description = "Supabase project URL"
  value       = "https://${supabase_project.this.id}.supabase.co"
}

output "database_password" {
  description = "Generated database password (sensitive; wired to orun secrets)"
  value       = random_password.db_password.result
  sensitive   = true
}

output "connection_uri" {
  description = "Direct Postgres connection URI (sensitive; wired to orun secrets)"
  value       = "postgresql://postgres:${random_password.db_password.result}@db.${supabase_project.this.id}.supabase.co:5432/postgres"
  sensitive   = true
}

# --- The project, up ---
#
# The provider returns from a create as soon as the Management API accepts it,
# and a project takes minutes to come up. Its API keys and its Auth
# configuration are read and written below; both wait here until the project
# reports ACTIVE_HEALTHY (ten minutes at most). On an adopted or existing
# project this answers at once. Same tools as adopt.tf: bash, curl, jq and the
# brokered SUPABASE_ACCESS_TOKEN in the environment.

resource "terraform_data" "project_ready" {
  triggers_replace = [supabase_project.this.id]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      PROJECT_REF = supabase_project.this.id
    }
    command = <<-EOT
      set -uo pipefail
      for _ in $(seq 1 60); do
        status="$(curl -fsS --retry 2 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
          "https://api.supabase.com/v1/projects/$PROJECT_REF" | jq -r '.status // empty')"
        [ "$status" = ACTIVE_HEALTHY ] && { echo "supabase: $PROJECT_REF is $status"; exit 0; }
        echo "supabase: $PROJECT_REF is $${status:-not answering yet}; waiting"
        sleep 10
      done
      echo "supabase: $PROJECT_REF did not report ACTIVE_HEALTHY within ten minutes" >&2
      exit 1
    EOT
  }
}

# --- API keys: the app's wiring document ---
#
# The app talks to Supabase from the browser and from the Worker with the
# project URL and the publishable (anon) key — public by design; row-level
# security is what protects the data — and its webhook sync and customer
# mapping use the service-role key, which bypasses row-level security and is
# a SECRET. All three leave this module in ONE document, WIRING_SUPABASE:
# the app's deploy renders the first two into its wrangler config (and its
# build inlines them), and pushes the third to the Worker as a Worker secret.
# The document as a whole is an orun secret; no key is a separate output.

data "supabase_apikeys" "this" {
  project_ref = supabase_project.this.id
  depends_on  = [terraform_data.project_ready]
}

output "wiring" {
  description = "Wiring document for the app's deploy (pushed to orun secrets as WIRING_SUPABASE): the project URL, the anon key and the service-role key"
  value = jsonencode({
    supabase_url              = "https://${supabase_project.this.id}.supabase.co"
    supabase_anon_key         = data.supabase_apikeys.this.anon_key
    supabase_service_role_key = data.supabase_apikeys.this.service_role_key
  })
  sensitive = true
}

# --- Auth ---
#
# A fresh project's Auth sends its links to http://localhost:3000 and asks
# every new user to confirm an email address it can deliver only to the
# organization's own members. So the app's Worker is the Site URL and the one
# allowed redirect origin, and sign-up signs the user straight in unless
# `authEmailConfirmation` is on. Only these three keys are managed; every
# other Auth setting — SMTP, providers, templates — stays the project's own,
# and the dashboard can change it (the product's README, "Supabase Auth
# email").

resource "supabase_settings" "this" {
  project_ref = supabase_project.this.id

  auth = jsonencode({
    site_url           = local.app_origin
    uri_allow_list     = "${local.app_origin}/**"
    mailer_autoconfirm = !var.authEmailConfirmation
  })

  depends_on = [terraform_data.project_ready]
}
