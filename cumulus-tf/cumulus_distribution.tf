locals {
  distribution_api_gateway_stage = "dev"
  bucket_map_file_name           = fileexists("${path.module}/cumulus_distribution/bucket_map.yaml") ? "${path.module}/cumulus_distribution/bucket_map.yaml" : "${path.module}/cumulus_distribution/bucket_map.yaml.tmpl"
  protected_bucket_names         = [for k, v in var.buckets : v.name if v.type == "protected"]
  public_bucket_names            = [for k, v in var.buckets : v.name if v.type == "public"]
}

resource "aws_s3_bucket_object" "bucket_map_yaml_distribution" {
  bucket = var.system_bucket
  key    = "${var.prefix}/cumulus_distribution/bucket_map.yaml"
  content = templatefile(local.bucket_map_file_name, {
    protected_buckets = local.protected_bucket_names,
    public_buckets    = local.public_bucket_names
  })
  etag = md5(templatefile(local.bucket_map_file_name, {
    protected_buckets = local.protected_bucket_names,
    public_buckets    = local.public_bucket_names
  }))
  tags = var.tags
}

module "cumulus_distribution" {
  source                    = "https://github.com/nasa/cumulus/releases/download/v9.3.0/terraform-aws-cumulus.zip//tf-modules/cumulus_distribution"
  deploy_to_ngap            = true
  prefix                    = var.prefix
  api_gateway_stage         = local.distribution_api_gateway_stage
  api_url                   = var.cumulus_distribution_url
  bucket_map_file           = aws_s3_bucket_object.bucket_map_yaml_distribution.id
  bucketname_prefix         = ""
  cmr_acl_based_credentials = true
  cmr_environment           = var.cmr_environment
  cmr_provider              = var.cmr_provider
  lambda_subnet_ids         = local.ngap_subnet_ids
  oauth_client_id           = var.csdap_client_id
  oauth_client_password     = var.csdap_client_password
  oauth_host_url            = var.csdap_host_url
  oauth_provider            = "cognito"
  permissions_boundary_arn  = local.permissions_boundary_arn
  buckets                   = var.buckets
  system_bucket             = var.system_bucket
  tags                      = local.tags
  vpc_id                    = data.aws_vpc.ngap_vpc.id
}