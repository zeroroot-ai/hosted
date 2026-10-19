variable "name" {
  description = "Short identifier for this surface (e.g. \"docs\", \"www\"). Used for resource names."
  type        = string
}

variable "domain_name" {
  description = "Fully-qualified hostname this surface is served at (e.g. docs.zeroroot.ai)."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name holding the published export."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN covering domain_name. MUST be issued in us-east-1: CloudFront reads certificates from that region only."
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone the A/AAAA alias records are written into."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (NA + EU) is the cheap default; widen only when there is measured traffic elsewhere."
  type        = string
  default     = "PriceClass_100"
}

variable "redirect_hosts" {
  description = "Extra hostnames served by this distribution that 301 to domain_name (e.g. the apex redirecting to www). Empty for a surface with no aliases."
  type        = list(string)
  default     = []
}

variable "api_origin_enabled" {
  description = "Whether this surface has an /api/* origin. A STATIC flag, deliberately separate from api_origin_host: the host comes from another module and is unknown at plan time, and Terraform cannot evaluate a count or a dynamic block from an unknown value."
  type        = bool
  default     = false
}

variable "api_origin_host" {
  description = "Second origin for /api/* — a Lambda Function URL host. Read only when api_origin_enabled is true. Making the API same-origin with the site is what removes the need for CORS entirely."
  type        = string
  default     = ""
}

variable "content_security_policy" {
  description = "The Content-Security-Policy header of this surface. It must equal the one the site's own nginx.conf sets, so the container and the edge serve one policy. Empty sets no CSP header."
  type        = string
  default     = ""
}
