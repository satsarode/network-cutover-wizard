output "api_base_url" {
  description = "Base URL for the Network Cutover Wizard API"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}
