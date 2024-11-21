# output "cur_report_arn" {
#   description = "ARN of the Cost and Usage Report"
#   value       = var.create_cur ? aws_bcmdataexports_export.this[0].export_arn : null
# }

output "cur_bucket_arn" {
  description = "ARN of the S3 Bucket where the Cost and Usage Report is delivered"
  value       = aws_s3_bucket.this.arn
}

output "cur_bucket_name" {
  description = "Name of the S3 Bucket where the Cost and Usage Report is delivered"
  value       = aws_s3_bucket.this.bucket
}