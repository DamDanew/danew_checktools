$files = @(
    "$env:USERPROFILE\.claude\projects\h--Danew-CheckTool\18c27c1a-8d51-49ed-b59f-70fb2ed53640.jsonl",
    "$env:USERPROFILE\.claude\projects\h--Danew-CheckTool\c528d71e-6bcf-4929-98e5-0d28eaab5a0c.jsonl",
    "$env:USERPROFILE\.claude\projects\h--Danew-CheckTool\42d38368-772d-4c98-9a85-38da48cb584c.jsonl"
)

$bashCmds = @{}
$mcpTools = @{}

function Get-LeadToken($cmd) {
    $cmd = $cmd.Trim()
    $cmd = [regex]::Replace($cmd, '^([A-Z_]+=\S+\s+)+', '')
    $cmd = [regex]::Replace($cmd, '^(sudo|timeout\s+\d+)\s+', '')
    $tokens = ($cmd -split '\s+') | Where-Object { $_ -ne '' }
    if (-not $tokens -or $tokens.Count -eq 0) { return $null }
    $prog = $tokens[0]
    $sub = if ($tokens.Count -gt 1) { $tokens[1] } else { $null }
    if ($prog -in @('powershell','pwsh')) { return $prog }
    $multiword = @('git','gh','docker','kubectl','npm','yarn','npx','node','python','python3','bun','pip')
    if ($sub -and ($prog -in $multiword)) {
        return "$prog $sub"
    }
    return $prog
}

foreach ($file in $files) {
    if (-not (Test-Path $file)) { Write-Host "MISSING: $file"; continue }
    $lines = [System.IO.File]::ReadAllLines($file)
    Write-Host "Scanning $([System.IO.Path]::GetFileName($file)) ($($lines.Count) lines)..."
    foreach ($line in $lines) {
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
            if ($obj.message.role -ne 'assistant') { continue }
            foreach ($item in $obj.message.content) {
                if ($item.type -ne 'tool_use') { continue }
                $name = $item.name
                if ($name -eq 'Bash') {
                    $cmd = [string]$item.input.command
                    $first = ($cmd -split '&&|;|\|')[0].Trim()
                    $lead = Get-LeadToken $first
                    if ($lead) {
                        if (-not $bashCmds.ContainsKey($lead)) { $bashCmds[$lead] = 0 }
                        $bashCmds[$lead]++
                    }
                } elseif ($name -like 'mcp__*') {
                    if (-not $mcpTools.ContainsKey($name)) { $mcpTools[$name] = 0 }
                    $mcpTools[$name]++
                }
            }
        } catch {}
    }
}

Write-Host ""
Write-Host "=== BASH TOP 40 ==="
$bashCmds.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 40 | ForEach-Object {
    Write-Host ("  " + $_.Value.ToString().PadLeft(4) + "  " + $_.Key)
}
Write-Host ""
Write-Host "=== MCP TOP 20 ==="
$mcpTools.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
    Write-Host ("  " + $_.Value.ToString().PadLeft(4) + "  " + $_.Key)
}
