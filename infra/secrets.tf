resource "aws_iam_role_policy_attachment" "secrets_manager_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.secrets_manager_access.arn
}

resource "aws_secretsmanager_secret" "secrets" {
  for_each = local.environments
  name     = "lambda-secrets3-${each.key}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "secret_versions" {
  for_each      = aws_secretsmanager_secret.secrets
  secret_id     = each.value.id
  secret_string = jsonencode({ "DATABASE_PASSWORD" = "placeholder-for-${each.key}" })
}
