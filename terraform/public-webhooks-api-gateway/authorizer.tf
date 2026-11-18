data "archive_file" "source_allowlist" {
  count = var.enable_source_allowlist ? 1 : 0
  type  = "zip"
  source {
    content  = file("${path.module}/authorizer/index.py")
    filename = "index.py"
  }
  source {
    content = jsonencode(sort([
      for cidr in var.allowed_source_cidrs : try(
        "${cidrhost(cidr, 0)}/${tonumber(split("/", cidr)[1])}", ""
      )
    ]))
    filename = "cidrs.json"
  }
  output_path = "${path.module}/.terraform/source-allowlist.zip"
}

resource "aws_iam_role" "source_allowlist" {
  count       = var.enable_source_allowlist ? 1 : 0
  name_prefix = "${var.name}-source-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_lambda_function" "source_allowlist" {
  count            = var.enable_source_allowlist ? 1 : 0
  function_name    = "${var.name}-source-allowlist"
  role             = aws_iam_role.source_allowlist[0].arn
  runtime          = "python3.13"
  handler          = "index.handler"
  filename         = data.archive_file.source_allowlist[0].output_path
  source_code_hash = data.archive_file.source_allowlist[0].output_base64sha256
  timeout          = 5

  tracing_config {
    mode = "Active"
  }
  depends_on = [aws_iam_role_policy.tracing]
}

resource "aws_iam_role_policy" "tracing" {
  count = var.enable_source_allowlist ? 1 : 0
  role  = aws_iam_role.source_allowlist[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    }]
  })
}

resource "aws_apigatewayv2_authorizer" "source_allowlist" {
  count                             = var.enable_source_allowlist ? 1 : 0
  api_id                            = aws_apigatewayv2_api.webhooks.id
  name                              = "source-allowlist"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.source_allowlist[0].invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
}

resource "aws_lambda_permission" "source_allowlist" {
  count         = var.enable_source_allowlist ? 1 : 0
  statement_id  = "AllowSourceAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.source_allowlist[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhooks.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.source_allowlist[0].id}"
}
