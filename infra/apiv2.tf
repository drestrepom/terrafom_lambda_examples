# Create a single HTTP API using API Gateway V2 for exposing Lambda functions
resource "aws_apigatewayv2_api" "lambdas" {
  for_each      = local.environments          # keys: "development", "production"
  name          = "lambdas-apiv2-${each.key}"
  protocol_type = "HTTP"
}

# Create an integration for each Lambda alias
resource "aws_apigatewayv2_integration" "lambda_integration" {
  for_each               = aws_lambda_alias.lambda_alias

  # Select the correct API based on the environment of each alias
  api_id                 = aws_apigatewayv2_api.lambdas[local.lambda_environments[each.key].env_name].id

  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = each.value.invoke_arn
  payload_format_version = "2.0"
}

# Create a route for each Lambda integration. Routes are configured as GET /{lambdaName}/{userId}
# resource "aws_apigatewayv2_route" "lambda_route" {
#   for_each  = aws_apigatewayv2_integration.lambda_integration

#   api_id    = aws_apigatewayv2_api.lambdas[local.lambda_environments[each.key].env_name].id
#   route_key = "GET /${local.lambda_environments[each.key].lambda_name}/{region}/{userId}"
#   target    = "integrations/${aws_apigatewayv2_integration.lambda_integration[each.key].id}"
# }

resource "aws_apigatewayv2_route" "hello1_get" {
  for_each = local.environments
  api_id    = aws_apigatewayv2_api.lambdas[each.key].id
  route_key = "GET /hello1"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration["hello1-${each.key}"].id}"
}

resource "aws_apigatewayv2_route" "hello2_post" {
  for_each = local.environments
  api_id    = aws_apigatewayv2_api.lambdas[each.key].id
  route_key = "POST /hello2"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration["hello2-${each.key}"].id}"
}

# -----------------------------------------------------------------------------
# Deployment per API (environment)
# -----------------------------------------------------------------------------
resource "aws_apigatewayv2_deployment" "api_deployment" {
  for_each    = aws_apigatewayv2_api.lambdas

  api_id      = each.value.id
  description = "HTTP API deployment for ${each.key} environment"

  # Re-deploy when any integration or route changes
  triggers = {
    redeployment = sha1(jsonencode(aws_apigatewayv2_integration.lambda_integration))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Default stage ($default) per API, referencing the deployment
resource "aws_apigatewayv2_stage" "default" {
  for_each      = aws_apigatewayv2_api.lambdas
  api_id        = each.value.id
  name          = "$default"
  deployment_id = aws_apigatewayv2_deployment.api_deployment[each.key].id
  auto_deploy   = false
}

# Allow API Gateway to invoke each Lambda alias
resource "aws_lambda_permission" "api_gateway_v2" {
  for_each     = aws_lambda_alias.lambda_alias
  statement_id = "AllowAPIGatewayInvokeV2-${each.key}"
  action       = "lambda:InvokeFunction"
  function_name= each.value.function_name
  qualifier    = each.value.name
  principal    = "apigateway.amazonaws.com"
  source_arn   = "${aws_apigatewayv2_api.lambdas[local.lambda_environments[each.key].env_name].execution_arn}/*/*"
}

# Output the invoke URLs for each stage
output "rest_api_endpoints_v2" {
  description = "Invoke URLs for each environment"
  value = {
    for env, api in aws_apigatewayv2_api.lambdas : env => "https://${api.id}.execute-api.${data.aws_region.current.name}.amazonaws.com"
  }
}
