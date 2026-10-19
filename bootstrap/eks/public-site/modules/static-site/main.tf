# ----------------------------------------------------------------------------
# One public web surface: a private S3 bucket, read only by a CloudFront
# distribution through an Origin Access Control.
#
# The bucket is NEVER a website endpoint and never public. S3 website hosting
# only speaks HTTP and cannot be reached by OAC, so the bucket would have to be
# world-readable and the CDN would become advisory — anyone could fetch the
# origin directly and bypass it. REST origin + OAC keeps the only public door
# on CloudFront.
#
# Because the origin is REST rather than a website endpoint, S3 does not resolve
# a directory to its index document. `/docs/` would return the S3 XML listing
# error instead of `docs/index.html`. A CloudFront Function fixes that at the
# edge (see index_rewrite below) — and it is the ONLY rewrite in this design,
# which is why docs-site#56 moved the rest into the export itself.
# ----------------------------------------------------------------------------

locals {
  origin_id     = "s3-${var.name}"
  api_origin_id = "lambda-${var.name}"
}

# ----------------------------------------------------------------------------
# Bucket
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  # A permanent resident of this account: the site must outlive each
  # teardown. eks-post-destroy-verify.sh exempts it by service (CloudFront,
  # S3, ACM) and by the `www-*` name of the lead path, in arn_retained().
  # No tag exempts a resource (ADR-0070, hosted#411).
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3, deliberately not KMS. Every object here is public content
      # served to anonymous readers, so a CMK protects nothing, and CloudFront
      # reading KMS objects needs a key grant that buys no confidentiality.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-publishes"
    status = "Enabled"

    filter {}

    # Versioning is on so a bad publish can be rolled back, but a static site
    # accumulates a full copy per deploy. Thirty days is far longer than any
    # rollback window and stops the bucket growing without bound.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ----------------------------------------------------------------------------
# Bucket policy — CloudFront only, TLS only
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "AllowCloudFrontRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.this.arn}/*"]

    # Scopes the grant to THIS distribution. Without it, any CloudFront
    # distribution in any AWS account could read the bucket.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ----------------------------------------------------------------------------
# CloudFront
# ----------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = var.name
  description                       = "OAC for ${var.domain_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Resolve a directory request to its index document. A REST S3 origin does no
# index resolution, so `/docs/` must become `/docs/index.html` before it
# reaches the bucket.
#
# This is the ONE rewrite in the design. Everything else the sites need is
# baked into the exports themselves (docs-site#56), because a rule that lives
# only at the edge means the same bytes are broken everywhere else.
resource "aws_cloudfront_function" "index_rewrite" {
  name    = "${var.name}-index-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Host redirect + index resolution for ${var.domain_name}"
  publish = true

  # Two jobs, in this order:
  #
  #   1. Send any aliased host to the canonical one with a 301. That is how the
  #      apex reaches www without a second distribution, a second certificate or
  #      a redirect bucket — one distribution carries both aliases and the edge
  #      decides. A redirect bucket would need S3 website hosting, which speaks
  #      only HTTP and forces the bucket public.
  #
  #   2. Resolve a directory request to its index document. A REST S3 origin
  #      does no index resolution, so `/docs/` must become `/docs/index.html`
  #      before it reaches the bucket.
  #
  # Job 2 is the ONLY content rewrite in this design. Everything else the sites
  # need is baked into their exports (docs-site#56), because a rule that lives
  # only at the edge leaves the same bytes broken everywhere else.
  code = <<-JS
    var CANONICAL = '${var.domain_name}';

    function handler(event) {
      var request = event.request;
      var host = request.headers.host ? request.headers.host.value : CANONICAL;

      if (host !== CANONICAL) {
        var qs = '';
        for (var k in request.querystring) {
          qs += (qs ? '&' : '?') + k +
            (request.querystring[k].value ? '=' + request.querystring[k].value : '');
        }
        return {
          statusCode: 301,
          statusDescription: 'Moved Permanently',
          headers: { location: { value: 'https://' + CANONICAL + request.uri + qs } },
        };
      }

      var uri = request.uri;
      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
      } else if (!uri.split('/').pop().includes('.')) {
        // Extensionless path: treat it as a directory so /docs and /docs/
        // resolve to the same document.
        request.uri = uri + '/index.html';
      }

      return request;
    }
  JS
}

# ----------------------------------------------------------------------------
# The security response headers of this surface.
#
# The AWS managed SecurityHeadersPolicy sets no Content-Security-Policy, and a
# managed policy cannot take one. So each surface has its own policy with the
# headers the docs-site nginx.conf also sets (docs-site advisory
# GHSA-6hc8-9whc-fxfw): nosniff, the referrer policy, HSTS, a frame refusal,
# and the CSP of var.content_security_policy. A surface that sets no CSP
# (www today) gets the other headers only.
# ----------------------------------------------------------------------------
resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${var.name}-security-headers"
  comment = "Security headers of ${var.domain_name}"

  security_headers_config {
    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }

    dynamic "content_security_policy" {
      for_each = var.content_security_policy == "" ? [] : [var.content_security_policy]

      content {
        content_security_policy = content_security_policy.value
        override                = true
      }
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = var.domain_name
  default_root_object = "index.html"
  aliases             = concat([var.domain_name], var.redirect_hosts)
  price_class         = var.price_class

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = local.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  # The API origin, when this surface has one. Same distribution, same
  # hostname, so the browser makes a SAME-ORIGIN request and no CORS exists to
  # get wrong. The Function URL itself is AWS_IAM-authorised and signed by the
  # OAC below, so it cannot be called around this distribution.
  dynamic "origin" {
    for_each = var.api_origin_enabled ? [1] : []

    content {
      domain_name = var.api_origin_host
      origin_id   = local.api_origin_id

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policies, by ID because the names are not resolvable as
    # data sources in every provider version.
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  # /api/* goes to the function, uncached, POST allowed. Everything else falls
  # through to the default behaviour and is served from S3.
  dynamic "ordered_cache_behavior" {
    for_each = var.api_origin_enabled ? [1] : []

    content {
      path_pattern           = "/api/*"
      target_origin_id       = local.api_origin_id
      viewer_protocol_policy = "https-only"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

      # No function_association: the index-rewrite function would append
      # index.html to /api/contact-sales and break the call. The host redirect
      # it also performs does not matter here, because the form is only ever
      # served from the canonical host.
    }
  }

  # A missing page must answer 404, not 200. Returning the SPA shell with a
  # 200 for every unknown path is how a stale link renders "the site is
  # serving the wrong thing" instead of "that page does not exist" — the same
  # reasoning that kept a catch-all out of the nginx config.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 300
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ----------------------------------------------------------------------------
# DNS
# ----------------------------------------------------------------------------

resource "aws_route53_record" "a" {
  # UPSERT, not CREATE. external-dns wrote records for these hostnames from
  # inside the cluster; the cluster is gone but its records remain, aliased to
  # load balancers that no longer exist. A plain create fails with
  # "but it already exists" and leaves the hostname pointing at nothing.
  # Terraform owns these names now (ADR-0077), so overwriting is the correct
  # semantics rather than a workaround.
  allow_overwrite = true

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "aaaa" {
  # UPSERT, not CREATE. external-dns wrote records for these hostnames from
  # inside the cluster; the cluster is gone but its records remain, aliased to
  # load balancers that no longer exist. A plain create fails with
  # "but it already exists" and leaves the hostname pointing at nothing.
  # Terraform owns these names now (ADR-0077), so overwriting is the correct
  # semantics rather than a workaround.
  allow_overwrite = true

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# Alias records for every extra hostname this distribution answers for. They
# resolve here so the edge function can issue the 301; without them the apex
# would not reach CloudFront at all.
resource "aws_route53_record" "redirect_a" {
  # UPSERT, not CREATE. external-dns wrote records for these hostnames from
  # inside the cluster; the cluster is gone but its records remain, aliased to
  # load balancers that no longer exist. A plain create fails with
  # "but it already exists" and leaves the hostname pointing at nothing.
  # Terraform owns these names now (ADR-0077), so overwriting is the correct
  # semantics rather than a workaround.
  allow_overwrite = true

  for_each = toset(var.redirect_hosts)

  zone_id = var.route53_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "redirect_aaaa" {
  # UPSERT, not CREATE. external-dns wrote records for these hostnames from
  # inside the cluster; the cluster is gone but its records remain, aliased to
  # load balancers that no longer exist. A plain create fails with
  # "but it already exists" and leaves the hostname pointing at nothing.
  # Terraform owns these names now (ADR-0077), so overwriting is the correct
  # semantics rather than a workaround.
  allow_overwrite = true

  for_each = toset(var.redirect_hosts)

  zone_id = var.route53_zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
