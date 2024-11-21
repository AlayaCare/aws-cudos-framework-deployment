data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}

###
# Aggregation S3 bucket
###
resource "aws_s3_bucket" "this" {
  # checkov:skip=CKV2_AWS_62:Due to dependencies, S3 event notifications must be configured external to the module
  # checkov:skip=CKV_AWS_144:CUR data can be backfilled on demand. Cross-region replication is not needed.
  bucket        = "${var.resource_prefix}-${data.aws_caller_identity.this.account_id}-shared"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  # checkov:skip=CKV2_AWS_67:KMS Key rotation is not in scope for this module as we do not create the key
  bucket = aws_s3_bucket.this.bucket
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_id
      sse_algorithm     = var.kms_key_id != null ? "aws:kms" : "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "this" {
  count = var.s3_access_logging.enabled ? 1 : 0

  bucket        = aws_s3_bucket.this.bucket
  target_bucket = var.s3_access_logging.bucket
  target_prefix = var.s3_access_logging.prefix
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.bucket
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.bucket
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.bucket
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.bucket
  rule {
    id     = "Object&Version Expiration"
    status = "Enabled"
    noncurrent_version_expiration {
      noncurrent_days = 32
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "bucket_policy" {
  policy_id = "CrossAccessPolicy"
  statement {
    sid     = "AllowTLS12Only"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = [1.2]
    }
  }
  statement {
    sid     = "AllowOnlyHTTPS"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = [false]
    }
  }
  statement {
    sid    = "AllowReplicationWrite"
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
    ]
    principals {
      type        = "AWS"
      identifiers = var.source_account_ids
    }
    resources = [
      "${aws_s3_bucket.this.arn}/*",
    ]
  }
  statement {
    sid    = "AllowReplicationRead"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketVersioning",
    ]
    principals {
      type        = "AWS"
      identifiers = var.source_account_ids
    }
    resources = [
      aws_s3_bucket.this.arn,
    ]
  }
  # Only add these statements if we are creating a local CUR in the destination account
  dynamic "statement" {
    for_each = var.create_cur ? [1] : []
    content {
      sid    = "AllowReadBilling"
      effect = "Allow"
      actions = [
        "s3:GetBucketAcl",
        "s3:GetBucketPolicy",
      ]
      principals {
        type = "Service"
        identifiers = [
          "billingreports.amazonaws.com",
          "bcm-data-exports.amazonaws.com",
        ]
      }
      resources = [
        aws_s3_bucket.this.arn,
        "${aws_s3_bucket.this.arn}/*",
      ]
      condition {
        test = "StringLike"
        values = [
          "arn:${data.aws_partition.this.partition}:cur:us-east-1:${data.aws_caller_identity.this.account_id}:definition/*",
          "arn:${data.aws_partition.this.partition}:bcm-data-exports:us-east-1:${data.aws_caller_identity.this.account_id}:export/*",
        ]
        variable = "aws:SourceArn"
      }
      condition {
        test     = "StringEquals"
        values   = [data.aws_caller_identity.this.account_id]
        variable = "aws:SourceAccount"
      }
    }
  }
  dynamic "statement" {
    for_each = var.create_cur ? [1] : []
    content {
      sid    = "AllowWriteBilling"
      effect = "Allow"
      actions = [
        "s3:PutObject",
      ]
      principals {
        type = "Service"
        identifiers = [
          "billingreports.amazonaws.com",
          "bcm-data-exports.amazonaws.com",
        ]
      }
      resources = [
        "${aws_s3_bucket.this.arn}/*",
      ]
      condition {
        test = "StringLike"
        values = [
          "arn:${data.aws_partition.this.partition}:cur:us-east-1:${data.aws_caller_identity.this.account_id}:definition/*",
          "arn:${data.aws_partition.this.partition}:bcm-data-exports:us-east-1:${data.aws_caller_identity.this.account_id}:export/*",
        ]
        variable = "aws:SourceArn"
      }
      condition {
        test     = "StringEquals"
        values   = [data.aws_caller_identity.this.account_id]
        variable = "aws:SourceAccount"
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}

###
# CUR
###
resource "aws_bcmdataexports_export" "this" {
  provider = aws.useast1
  count    = var.create_cur ? 1 : 0

  depends_on = [
    aws_s3_bucket_versioning.this,
    aws_s3_bucket_policy.this
  ]

  export {
    name = "${var.resource_prefix}-${var.cur_name_suffix}"

    data_query {
      query_statement = "SELECT bill_bill_type, bill_billing_entity, bill_billing_period_end_date, bill_billing_period_start_date, bill_invoice_id, bill_invoicing_entity, bill_payer_account_id, bill_payer_account_name, cost_category, discount, discount_bundled_discount, discount_total_discount, identity_line_item_id, identity_time_interval, line_item_availability_zone, line_item_blended_cost, line_item_blended_rate, line_item_currency_code, line_item_legal_entity, line_item_line_item_description, line_item_line_item_type, line_item_net_unblended_cost, line_item_net_unblended_rate, line_item_normalization_factor, line_item_normalized_usage_amount, line_item_operation, line_item_product_code, line_item_resource_id, line_item_tax_type, line_item_unblended_cost, line_item_unblended_rate, line_item_usage_account_id, line_item_usage_account_name, line_item_usage_amount, line_item_usage_end_date, line_item_usage_start_date, line_item_usage_type, pricing_currency, pricing_lease_contract_length, pricing_offering_class, pricing_public_on_demand_cost, pricing_public_on_demand_rate, pricing_purchase_option, pricing_rate_code, pricing_rate_id, pricing_term, pricing_unit, product, product_comment, product_fee_code, product_fee_description, product_from_location, product_from_location_type, product_from_region_code, product_instance_family, product_instance_type, product_instancesku, product_location, product_location_type, product_operation, product_pricing_unit, product_product_family, product_region_code, product_servicecode, product_sku, product_to_location, product_to_location_type, product_to_region_code, product_usagetype, reservation_amortized_upfront_cost_for_usage, reservation_amortized_upfront_fee_for_billing_period, reservation_availability_zone, reservation_effective_cost, reservation_end_time, reservation_modification_status, reservation_net_amortized_upfront_cost_for_usage, reservation_net_amortized_upfront_fee_for_billing_period, reservation_net_effective_cost, reservation_net_recurring_fee_for_usage, reservation_net_unused_amortized_upfront_fee_for_billing_period, reservation_net_unused_recurring_fee, reservation_net_upfront_value, reservation_normalized_units_per_reservation, reservation_number_of_reservations, reservation_recurring_fee_for_usage, reservation_reservation_a_r_n, reservation_start_time, reservation_subscription_id, reservation_total_reserved_normalized_units, reservation_total_reserved_units, reservation_units_per_reservation, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_normalized_unit_quantity, reservation_unused_quantity, reservation_unused_recurring_fee, reservation_upfront_value, resource_tags, savings_plan_amortized_upfront_commitment_for_billing_period, savings_plan_end_time, savings_plan_instance_type_family, savings_plan_net_amortized_upfront_commitment_for_billing_period, savings_plan_net_recurring_commitment_for_billing_period, savings_plan_net_savings_plan_effective_cost, savings_plan_offering_type, savings_plan_payment_option, savings_plan_purchase_term, savings_plan_recurring_commitment_for_billing_period, savings_plan_region, savings_plan_savings_plan_a_r_n, savings_plan_savings_plan_effective_cost, savings_plan_savings_plan_rate, savings_plan_start_time, savings_plan_total_commitment_to_date, savings_plan_used_commitment FROM COST_AND_USAGE_REPORT"

      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                      = "HOURLY",
          INCLUDE_RESOURCES                     = "TRUE",
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = var.enable_split_cost_allocation_data ? "TRUE" : "FALSE",
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.this.bucket
        s3_prefix = "cur/${data.aws_caller_identity.this.account_id}"
        s3_region = data.aws_region.this.name

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }
}