# ----------------------------------------------------------------------------
# The lead path: a contact-sales endpoint with no server behind it.
#
# In plain words: someone fills in the form, and an email arrives in the sales
# inbox. Nothing else runs.
#
# The Lambda is exposed by a Function URL and attached as a SECOND ORIGIN on
# the site's own CloudFront distribution, at /api/contact-sales. That is the
# whole design decision, and it is what deletes work rather than adding it:
# the form and the endpoint share an origin, so the browser makes a
# same-origin request and the dashboard route's CORS apparatus — origin
# allowlist, OPTIONS preflight, Vary: Origin, 403-on-unknown-origin — is not
# ported. It is deleted.
#
# Delivery is SNS, not SES: no verified domain identity, no production-access
# request, and lead mail stays off the reputation of the sender that carries
# signup verification (launch blocker 2).
#
# Rate limiting is the account's own Lambda concurrency ceiling, currently 10.
# A WAF rate rule costs ~$6/mo against a ~$2/mo site, for a form nobody has
# submitted yet. See the note on the function resource below.
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-lead-path"
  description        = "Execution role for the ${var.name} contact-sales function. Publishes to one SNS topic and writes its own logs."
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_sns_topic" "leads" {
  name = "${var.name}-contact-sales-leads"
}

# The subscription is created PendingConfirmation. AWS emails the address a
# confirmation link, and mail only flows once a human clicks it. Terraform
# cannot confirm it, and should not — a subscription nobody accepted is a lead
# path nobody is reading.
resource "aws_sns_topic_subscription" "inbox" {
  topic_arn = aws_sns_topic.leads.arn
  protocol  = "email"
  endpoint  = var.sales_inbox
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "PublishLeads"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.leads.arn]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.name}-lead-path"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.execution.json
}

# Declared explicitly rather than left to Lambda's implicit creation, so the
# retention is bounded. An implicitly-created group never expires.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}-contact-sales"
  retention_in_days = 30
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/.build/${var.name}-contact-sales.zip"
}

resource "aws_lambda_function" "this" {
  function_name = "${var.name}-contact-sales"
  description   = "Turns a contact-sales submission into an SNS email. Second origin on the ${var.name} distribution."
  role          = aws_iam_role.this.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  timeout       = 10
  memory_size   = 256

  filename         = data.archive_file.source.output_path
  source_code_hash = data.archive_file.source.output_base64sha256

  # NO reserved_concurrent_executions, and not by omission.
  #
  # This account's total Lambda concurrency is 10, and AWS refuses any
  # reservation that would drop unreserved concurrency below 10 — so no
  # function here can reserve anything at all. It is also redundant: with a
  # ceiling of 10 account-wide, this function cannot exceed 10 concurrent
  # executions whatever it asks for. The account limit IS the rate limit, and
  # it is tighter than the reservation originally written here.
  #
  # If the account limit is ever raised, revisit this — the bound disappears
  # with it. A WAF rate rule is the next step up, at ~$6/mo.

  environment {
    variables = {
      LEAD_TOPIC_ARN = aws_sns_topic.leads.arn
    }
  }


  depends_on = [
    aws_iam_role_policy.execution,
    aws_cloudwatch_log_group.this,
  ]
}

# ----------------------------------------------------------------------------
# The public edge of the function: an HTTP API, not a Function URL.
#
# A Function URL was tried first and does not work here, for two stacked
# reasons that are both AWS constraints rather than configuration mistakes:
#
#   1. With AWS_IAM auth and a CloudFront Origin Access Control, the caller
#      must sign the PAYLOAD. CloudFront's OAC cannot do that for a request
#      with a body, and the usual workaround — hash the body at the edge —
#      needs Lambda@Edge, because CloudFront Functions have no access to the
#      request body at all. Measured: every request was rejected before the
#      handler ran.
#   2. With NONE auth, the resource policy granting `Principal: "*"` is not
#      honoured in this account, so the URL answers 403 even to a direct call.
#
# The failure was also invisible: the distribution's 403-to-404 mapping
# fetched the error page from the S3 origin, so the symptom presented as an S3
# AccessDenied unrelated to the real fault.
#
# An HTTP API is public by design and needs no signing, which is the correct
# shape for an endpoint whose entire job is to accept anonymous submissions.
# The design intent is unchanged: it is still a second ORIGIN on the site's own
# distribution, so the browser makes a same-origin request and no CORS exists.
# ----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-contact-sales"
  description   = "Public edge for the ${var.name} contact-sales function. Fronted by CloudFront at /api/contact-sales."
  protocol_type = "HTTP"

  # No cors_configuration, deliberately. The browser only ever reaches this
  # through the site's own distribution, so every request is same-origin.
  # Declaring CORS here would re-create the cross-origin coupling this design
  # exists to delete.
}

resource "aws_apigatewayv2_integration" "this" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

# The path is spelled out rather than a catch-all: this API answers exactly one
# route, and anything else is a 404 from API Gateway rather than a request the
# function has to reason about.
resource "aws_apigatewayv2_route" "post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/contact-sales"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Access logs off on purpose: CloudFront already records the request, and the
  # function logs the lead shape. A third copy of the same event, carrying
  # submitter data, is a liability rather than an aid.
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
