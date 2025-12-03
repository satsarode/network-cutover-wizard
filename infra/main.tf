terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

############################
# DynamoDB: Cutover projects
############################

resource "aws_dynamodb_table" "cutover_projects" {
  name         = "ncw-cutover-projects"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "projectId"

  attribute {
    name = "projectId"
    type = "S"
  }

  tags = {
    Name        = "NetworkCutoverWizardProjects"
    Environment = "dev"
  }
}

#########################
# IAM Roles and Policies
#########################

# Lambda role
resource "aws_iam_role" "lambda_role" {
  name = "ncw-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Basic Lambda + DynamoDB + StepFunctions
resource "aws_iam_policy" "lambda_policy" {
  name        = "ncw-lambda-policy"
  description = "Permissions for Network Cutover Wizard Lambdas"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.cutover_projects.arn
      },
      {
        Effect = "Allow"
        Action = [
          "states:StartExecution",
          "states:DescribeExecution"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

#########################
# Lambda: API
#########################

data "archive_file" "api_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/api/lambda_function.py"
  output_path = "${path.module}/../lambdas/api.zip"
}

resource "aws_lambda_function" "api" {
  function_name = "ncw-api"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "lambda_function.handler"

  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  environment {
    variables = {
      PROJECTS_TABLE   = aws_dynamodb_table.cutover_projects.name
      STATE_MACHINE_ARN = aws_sfn_state_machine.cutover_state_machine.arn
    }
  }
}

#########################
# Lambda: Workflow (steps)
#########################

data "archive_file" "workflow_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/workflow/lambda_function.py"
  output_path = "${path.module}/../lambdas/workflow.zip"
}

resource "aws_lambda_function" "workflow" {
  function_name = "ncw-workflow"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "lambda_function.handler"

  filename         = data.archive_file.workflow_zip.output_path
  source_code_hash = data.archive_file.workflow_zip.output_base64sha256

  environment {
    variables = {
      PROJECTS_TABLE = aws_dynamodb_table.cutover_projects.name
    }
  }
}

#########################
# Step Functions
#########################

resource "aws_iam_role" "sfn_role" {
  name = "ncw-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "sfn_policy" {
  name        = "ncw-sfn-policy"
  description = "Allow Step Functions to invoke workflow Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.workflow.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sfn_attach" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = aws_iam_policy.sfn_policy.arn
}

resource "aws_sfn_state_machine" "cutover_state_machine" {
  name     = "ncw-cutover-state-machine"
  role_arn = aws_iam_role.sfn_role.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Network Cutover Orchestration: Precheck -> Execute -> Validate",
    StartAt = "Precheck",
    States = {
      Precheck = {
        Type = "Task",
        Resource = aws_lambda_function.workflow.arn,
        Parameters = {
          "step" : "precheck",
          "projectId.$" : "$.projectId"
        },
        Next = "ExecuteAutomation"
      },
      ExecuteAutomation = {
        Type = "Task",
        Resource = aws_lambda_function.workflow.arn,
        Parameters = {
          "step" : "execute",
          "projectId.$" : "$.projectId"
        },
        Next = "Validate"
      },
      Validate = {
        Type = "Task",
        Resource = aws_lambda_function.workflow.arn,
        Parameters = {
          "step" : "validate",
          "projectId.$" : "$.projectId"
        },
        End = true
      }
    }
  })
}

#########################
# API Gateway HTTP API
#########################

resource "aws_apigatewayv2_api" "http_api" {
  name          = "ncw-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# Routes:
# POST /projects          -> create project
# GET  /projects          -> list
# GET  /projects/{id}     -> get details
# POST /projects/{id}/start -> start cutover

resource "aws_apigatewayv2_route" "create_project_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /projects"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "list_projects_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /projects"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "get_project_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /projects/{projectId}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "start_cutover_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /projects/{projectId}/start"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_api" "http_api" {
  name          = "ncw-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = false
    allow_headers     = ["content-type"]
    allow_methods     = ["GET", "OPTIONS", "POST"]
    allow_origins     = ["*"]
    expose_headers    = []
    max_age           = 0
  }
}

#########################
# Permissions: API -> Lambda
#########################

resource "aws_lambda_permission" "allow_apigw_invoke_api" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}
