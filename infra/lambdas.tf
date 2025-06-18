// IAM Role for Lambda Execution
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "secrets_manager_access" {
  name        = "lambda-secrets-manager-access"
  description = "Allows Lambda functions to access specific secrets in Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = [for secret in aws_secretsmanager_secret.secrets : secret.arn]
      },
    ]
  })
}

// Create archive for each lambda function dynamically
data "archive_file" "lambda_zips" {
  for_each    = { for lambda in local.lambda_dirs : lambda => lambda }
  type        = "zip"
  source_dir  = "../lambdas/${each.value}"
  output_path = "${path.module}/.data/${each.value}.zip"
  excludes    = ["node_modules/*", "package.json", "package-lock.json"]
}

// Package the Lambda layer dependencies if package.json exists in lambdas/ directory
resource "null_resource" "package_layer" {
  provisioner "local-exec" {
    command = <<-EOC
      mkdir -p .data
      if [ -f "../lambdas/package.json" ]; then
          echo "Packaging layer dependencies..."
          rm -rf .data/layer
          mkdir -p .data/layer/nodejs
          cp ../lambdas/package.json .data/layer/nodejs/
          cp ../lambdas/package-lock.json .data/layer/nodejs/ 2>/dev/null || true
          (cd .data/layer/nodejs && npm install --only=prod)
          (cd .data/layer && zip -r ../dependencies-layer.zip nodejs)
      else
          echo "No ../lambdas/package.json found; creating an empty dependencies-layer.zip."
          touch .data/empty.txt
          zip .data/dependencies-layer.zip .data/empty.txt
          rm .data/empty.txt
      fi
    EOC
    interpreter = ["/bin/bash", "-c"]
  }
  // Trigger repackaging when package.json changes (if exists)
  triggers = {
    package_json = try(filemd5("../lambdas/package.json"), "none")
  }
}

// Add external data block to compute the hash of dependencies-layer.zip
data "external" "layer_zip_hash" {
  program = [
    "bash",
    "-c",
    <<-EOF
      if [ -f ".data/dependencies-layer.zip" ]; then
        echo "{\"hash\": \"$(openssl dgst -sha256 -binary .data/dependencies-layer.zip | base64)\"}"
      else
        echo "{\"hash\": \"\"}"
      fi
    EOF
    ,
  ]
  depends_on = [null_resource.package_layer]
}

// Modify the aws_lambda_layer_version resource to use the external data for source_code_hash
resource "aws_lambda_layer_version" "layer" {
  layer_name          = "dependencies-layer"
  filename            = "${path.module}/.data/dependencies-layer.zip"
  source_code_hash    = data.external.layer_zip_hash.result.hash
  compatible_runtimes = ["nodejs22.x"]
  depends_on          = [null_resource.package_layer]
}

// Create a Lambda function resource for each lambda directory
resource "aws_lambda_function" "lambdas" {
  for_each         = local.lambda_environments
  function_name    = each.key
  filename         = data.archive_file.lambda_zips[each.value.lambda_name].output_path
  source_code_hash = filebase64sha256(data.archive_file.lambda_zips[each.value.lambda_name].output_path)
  handler          = "index.handler" // Adjust as needed
  runtime          = "nodejs22.x"      // Adjust runtime if needed
  role             = aws_iam_role.lambda_exec.arn
  layers           = [aws_lambda_layer_version.layer.arn]
  publish          = each.value.env_name == "production"
  environment {
    variables = merge(
      each.value.variables,
      { SECRET_ARN = aws_secretsmanager_secret.secrets[each.value.env_name].arn }
    )
  }
}

resource "aws_lambda_alias" "lambda_alias" {
  for_each      = aws_lambda_function.lambdas
  name          = "live"
  description   = "Live alias for ${local.lambda_environments[each.key].env_name} environment"
  function_name = each.value.function_name
  function_version = each.value.version

  lifecycle {
    create_before_destroy = true
  }
}

output "lambda_functions" {
  value = { for k, v in aws_lambda_function.lambdas : k => v.function_name }
}

output "lambda_aliases" {
  value = { for k, v in aws_lambda_alias.lambda_alias : k => v.arn }
}

locals {
  lambda_dirs = distinct([
    for f in fileset("../lambdas", "**") :
    split("/", f)[0] if length(split("/", f)) > 1 && split("/", f)[0] != "node_modules"
  ])

  environments = {
    development = {
      ENVIRONMENT = "development"
      LOG_LEVEL   = "debug"
    }
    production = {
      ENVIRONMENT = "production"
      LOG_LEVEL   = "info"
    }
  }

  lambda_environments = {
    for pair in setproduct(local.lambda_dirs, keys(local.environments)) :
    "${pair[0]}-${pair[1]}" => {
      lambda_name = pair[0]
      env_name    = pair[1]
      variables   = local.environments[pair[1]]
    }
  }
}
