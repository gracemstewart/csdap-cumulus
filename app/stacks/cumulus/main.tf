locals {
  bucket_names = join(" ", values(var.buckets)[*].name)
  bucket_map_yaml = templatefile("${path.module}/templates/bucket_map.yaml.tmpl", {
    protected_buckets = [for k, v in var.buckets : v.name if v.type == "protected"],
    public_buckets    = [for k, v in var.buckets : v.name if v.type == "public"]
  })

  elasticsearch_alarms            = jsondecode("<%= json_output('data-persistence.elasticsearch_alarms') %>")
  elasticsearch_domain_arn        = jsondecode("<%= json_output('data-persistence.elasticsearch_domain_arn') %>")
  elasticsearch_hostname          = jsondecode("<%= json_output('data-persistence.elasticsearch_hostname') %>")
  elasticsearch_security_group_id = jsondecode("<%= json_output('data-persistence.elasticsearch_security_group_id') %>")

  ensure_buckets_exist_script = "${path.module}/bin/ensure-buckets-exist.sh"

  rds_security_group         = jsondecode("<%= json_output('rds-cluster.security_group_id') %>")
  rds_user_access_secret_arn = jsondecode("<%= json_output('rds-cluster.user_credentials_secret_arn') %>")

  tags = merge(var.tags, { Deployment = var.prefix })
}

resource "null_resource" "ensure_buckets_exist" {
  triggers = {
    bucket_names = local.bucket_names
    script_hash  = filebase64sha256(local.ensure_buckets_exist_script)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "${local.ensure_buckets_exist_script} ${local.bucket_names}"
  }
}

#-------------------------------------------------------------------------------
# DATA
#-------------------------------------------------------------------------------

data "aws_ssm_parameter" "ecs_image_id" {
  name = "image_id_ecs_amz2"
}

# Cognito client ID/password

# Earthdata Login (EDL) credentials.  For DEVELOPMENT deployments, these should
# be your own credentials for https://uat.urs.earthdata.nasa.gov/.  Otherwise,
# these should be credentials for an EDL "service" account.


#-------------------------------------------------------------------------------
# RESOURCES
#-------------------------------------------------------------------------------

resource "random_string" "token_secret" {
  length  = 32
  special = true
}

resource "aws_s3_bucket_object" "bucket_map_yaml_distribution" {
  bucket  = var.system_bucket
  key     = "${var.prefix}/cumulus_distribution/bucket_map.yaml"
  content = local.bucket_map_yaml
  etag    = md5(local.bucket_map_yaml)
  tags    = var.tags
}

#-------------------------------------------------------------------------------
# MODULES
#-------------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"
}

module "cma" {
  source = "../../modules/cma"

  prefix      = var.prefix
  bucket      = var.system_bucket
  cma_version = var.cumulus_message_adapter_version
}

module "cumulus_distribution" {
  source = "https://github.com/nasa/cumulus/releases/download/<%= cumulus_version %>/terraform-aws-cumulus.zip//tf-modules/cumulus_distribution"

  api_gateway_stage         = "dev"
  api_url                   = var.cumulus_distribution_url
  bucket_map_file           = aws_s3_bucket_object.bucket_map_yaml_distribution.id
  bucketname_prefix         = ""
  buckets                   = var.buckets
  cmr_acl_based_credentials = true
  cmr_environment           = var.cmr_environment
  cmr_provider              = var.cmr_provider
  deploy_to_ngap            = true
  lambda_subnet_ids         = module.vpc.subnets.ids
  oauth_client_id           = data.aws_ssm_parameter.csdap_client_id.value
  oauth_client_password     = data.aws_ssm_parameter.csdap_client_password.value
  oauth_host_url            = var.csdap_host_url
  oauth_provider            = "cognito"
  permissions_boundary_arn  = local.permissions_boundary_arn
  prefix                    = var.prefix
  system_bucket             = var.system_bucket
  tags                      = local.tags
  vpc_id                    = module.vpc.vpc_id
}

module "discover_granules_workflow" {
  source = "https://github.com/nasa/cumulus/releases/download/<%= cumulus_version %>/terraform-aws-cumulus.zip//tf-modules/workflow"

  prefix          = var.prefix
  name            = "DiscoverAndQueueGranules"
  workflow_config = module.cumulus.workflow_config
  system_bucket   = var.system_bucket
  tags            = local.tags

  state_machine_definition = templatefile("${path.module}/templates/discover-granules-workflow.asl.json", {
    ingest_granule_workflow_name : module.ingest_and_publish_granule_workflow.name,
    discover_granules_task_arn : module.cumulus.discover_granules_task.task_arn,
    queue_granules_task_arn : module.cumulus.queue_granules_task.task_arn,
    start_sf_queue_url : module.cumulus.start_sf_queue_url
  })
}

module "ingest_and_publish_granule_workflow" {
  source = "https://github.com/nasa/cumulus/releases/download/<%= cumulus_version %>/terraform-aws-cumulus.zip//tf-modules/workflow"

  prefix          = var.prefix
  name            = "IngestAndPublishGranule"
  workflow_config = module.cumulus.workflow_config
  system_bucket   = var.system_bucket
  tags            = local.tags

  state_machine_definition = templatefile("${path.module}/templates/ingest-and-publish-granule-workflow.asl.json", {
    sync_granule_task_arn : module.cumulus.sync_granule_task.task_arn,
    add_missing_file_checksums_task_arn : module.cumulus.add_missing_file_checksums_task.task_arn,
    fake_processing_task_arn : module.cumulus.fake_processing_task.task_arn,
    files_to_granules_task_arn : module.cumulus.files_to_granules_task.task_arn,
    move_granules_task_arn : module.cumulus.move_granules_task.task_arn,
    update_granules_cmr_metadata_file_links_task_arn : module.cumulus.update_granules_cmr_metadata_file_links_task.task_arn,
    post_to_cmr_task_arn : module.cumulus.post_to_cmr_task.task_arn
  })
}

module "cumulus" {
  source = "https://github.com/nasa/cumulus/releases/download/<%= cumulus_version %>/terraform-aws-cumulus.zip//tf-modules/cumulus"

  prefix         = var.prefix
  deploy_to_ngap = true

  cumulus_message_adapter_lambda_layer_version_arn = module.cma.lambda_layer_version_arn

  vpc_id            = module.vpc.vpc_id
  lambda_subnet_ids = module.vpc.subnets.ids
  archive_api_url   = var.archive_api_url

  ecs_cluster_instance_image_id   = data.aws_ssm_parameter.ecs_image_id.value
  ecs_cluster_instance_subnet_ids = length(var.ecs_cluster_instance_subnet_ids) == 0 ? module.vpc.subnets.ids : var.ecs_cluster_instance_subnet_ids
  ecs_cluster_min_size            = 1
  ecs_cluster_desired_size        = 1
  ecs_cluster_max_size            = 2
  key_name                        = var.key_name

  rds_security_group         = local.rds_security_group
  rds_user_access_secret_arn = local.rds_user_access_secret_arn
  rds_connection_heartbeat   = true

  urs_url             = var.urs_url
  urs_client_id       = data.aws_ssm_parameter.urs_client_id.value
  urs_client_password = data.aws_ssm_parameter.urs_client_password.value

  metrics_es_host     = var.metrics_es_host
  metrics_es_password = var.metrics_es_password
  metrics_es_username = var.metrics_es_username

  cmr_client_id      = var.cmr_client_id
  cmr_environment    = var.cmr_environment
  cmr_oauth_provider = var.cmr_oauth_provider
  cmr_provider       = var.cmr_provider
  # Earthdata Login (EDL) credentials.  For DEVELOPMENT deployments, these should
  # be your own credentials for https://uat.urs.earthdata.nasa.gov/.  Otherwise,
  # these should be credentials for an EDL "service" account at the EDL URL
  # specified by the 'urs_url' variable (see variables.tf for the default URL).
  cmr_username = data.aws_ssm_parameter.cmr_username.value
  cmr_password = data.aws_ssm_parameter.cmr_password.value

  launchpad_api         = var.launchpad_api
  launchpad_certificate = var.launchpad_certificate
  launchpad_passphrase  = var.launchpad_passphrase

  oauth_provider   = var.oauth_provider
  oauth_user_group = var.oauth_user_group

  saml_entity_id                  = var.saml_entity_id
  saml_assertion_consumer_service = var.saml_assertion_consumer_service
  saml_idp_login                  = var.saml_idp_login
  saml_launchpad_metadata_url     = var.saml_launchpad_metadata_url

  permissions_boundary_arn = local.permissions_boundary_arn

  system_bucket = var.system_bucket
  buckets       = var.buckets

  elasticsearch_alarms            = local.elasticsearch_alarms
  elasticsearch_domain_arn        = local.elasticsearch_domain_arn
  elasticsearch_hostname          = local.elasticsearch_hostname
  elasticsearch_security_group_id = local.elasticsearch_security_group_id

  dynamo_tables = jsondecode("<%= json_output('data-persistence.dynamo_tables') %>")

  es_index_shards = 2

  # Archive API settings
  token_secret                = random_string.token_secret.result
  archive_api_users           = length(var.api_users) > 0 ? var.api_users : [data.aws_ssm_parameter.cmr_username.value]
  archive_api_port            = var.archive_api_port
  private_archive_api_gateway = var.private_archive_api_gateway
  api_gateway_stage           = var.api_gateway_stage

  log_destination_arn          = var.log_destination_arn
  additional_log_groups_to_elk = var.additional_log_groups_to_elk

  tea_external_api_endpoint                   = var.cumulus_distribution_url
  deploy_cumulus_distribution                 = true
  deploy_distribution_s3_credentials_endpoint = false

  tags = local.tags
}