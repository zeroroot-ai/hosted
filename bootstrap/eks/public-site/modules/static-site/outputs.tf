output "bucket_name" {
  description = "Name of the bucket the publish workflow syncs into."
  value       = aws_s3_bucket.this.id
}

output "distribution_id" {
  description = "CloudFront distribution ID. The publish workflow invalidates against this."
  value       = aws_cloudfront_distribution.this.id
}

