data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Create a single REST API to expose all Lambda functions
resource "aws_api_gateway_rest_api" "lambdas" {
  name        = "lambdas-apiv1"
  description = "REST API exposing Lambda functions"
}

# One path resource per Lambda (base name), independent of environment
resource "aws_api_gateway_resource" "lambda_resource" {
  for_each    = toset(local.lambda_dirs)
  rest_api_id = aws_api_gateway_rest_api.lambdas.id
  parent_id   = aws_api_gateway_rest_api.lambdas.root_resource_id
  path_part   = each.value
}

# Allow API Gateway to invoke each Lambda alias
resource "aws_lambda_permission" "api_gateway" {
  for_each    = aws_lambda_alias.lambda_alias
  statement_id  = "AllowAPIGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  qualifier     = each.value.name  # alias name (e.g., live)
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lambdas.execution_arn}/*/*"
}

# -----------------------------------------------------------------------------
# Child resource /{userId} under each Lambda route
# -----------------------------------------------------------------------------
resource "aws_api_gateway_resource" "lambda_id_resource" {
  for_each    = aws_api_gateway_resource.lambda_resource
  rest_api_id = each.value.rest_api_id
  parent_id   = each.value.id
  path_part   = "{userId}"
}

resource "aws_api_gateway_method" "lambda_id_method" {
  for_each      = aws_api_gateway_resource.lambda_id_resource
  rest_api_id   = each.value.rest_api_id
  resource_id   = each.value.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_id_integration" {
  for_each                = aws_api_gateway_method.lambda_id_method
  rest_api_id             = each.value.rest_api_id
  resource_id             = each.value.resource_id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${each.key}-$${stageVariables.env}:live/invocations"
}

# Extend lambda permission to include ANY method and nested path (/*)
resource "aws_lambda_permission" "api_gateway_id" {
  for_each     = aws_lambda_alias.lambda_alias
  statement_id = "AllowAPIGatewayInvoke-Id-${each.key}"
  action       = "lambda:InvokeFunction"
  function_name = each.value.function_name
  qualifier     = each.value.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lambdas.execution_arn}/*/*/{userId}"
}

# Deploy the API
resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda_id_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.lambdas.id

  triggers = {
    redeploy = sha1(jsonencode(aws_api_gateway_integration.lambda_id_integration))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Two stages: dev and prod. Stage variable "env" will be substituted in integration URI.
resource "aws_api_gateway_stage" "stage" {
  for_each      = {
    dev  = "development"
    prod = "production"
  }

  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.lambdas.id
  stage_name    = each.key

  variables = {
    env = each.value
  }
}

output "rest_api_endpoints" {
  description = "Invoke URLs for each stage"
  value = {
    for k, v in aws_api_gateway_stage.stage : k => "https://${aws_api_gateway_rest_api.lambdas.id}.execute-api.${data.aws_region.current.name}.amazonaws.com/${v.stage_name}"
  }
}
