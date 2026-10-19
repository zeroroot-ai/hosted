resource "aws_cloudfront_distribution" "this" {
  default_cache_behavior {
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }
}
