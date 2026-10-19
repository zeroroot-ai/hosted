output "api_origin_host" {
  description = "Host portion of the HTTP API endpoint, for use as a CloudFront origin domain."
  value       = replace(aws_apigatewayv2_api.this.api_endpoint, "https://", "")
}

