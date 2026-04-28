param(
  [string]$Key = "1b659b8307cd4a298ddbca2475b43912",
  [string]$Gateway = "https://apim-hack26test.azure-api.net",
  [string]$Deployment = "gpt-5-mini",
  [string]$ApiVersion = "2024-10-21"
)

$uri = "$Gateway/openai/deployments/$Deployment/chat/completions?api-version=$ApiVersion"
$body = @{ messages = @(@{ role = "user"; content = "Say hello in 5 words." }) } | ConvertTo-Json -Compress

Write-Host "POST $uri" -ForegroundColor Cyan
try {
  $r = Invoke-RestMethod -Method Post -Uri $uri `
    -Headers @{ "Ocp-Apim-Subscription-Key" = $Key; "Content-Type" = "application/json" } `
    -Body $body
  Write-Host "OK" -ForegroundColor Green
  $r | ConvertTo-Json -Depth 8
} catch {
  $resp = $_.Exception.Response
  Write-Host "STATUS: $($resp.StatusCode)" -ForegroundColor Yellow
  if ($resp) {
    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
    Write-Host $reader.ReadToEnd()
  } else {
    Write-Host $_.Exception.Message
  }
}
