param(
    [string]$TargetLang = ""
)

# TLS fix for PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ==========================================================
# INIT
# ==========================================================

if ($TargetLang -and $TargetLang.Trim() -ne "") {
    $TargetLangs = $TargetLang.Split(",") |
        ForEach-Object { $_.Trim().ToLower() } |
        Where-Object { $_ -ne "" } |
        Select-Object -Unique
}
else {
    $TargetLangs = @()
}

# ==========================================================
# PATHS + ENV
# ==========================================================

$BaseDir = Join-Path $PSScriptRoot "data"
$OutputDir = Join-Path $BaseDir "output"
$LogDir = Join-Path $BaseDir "logs"

$CheckpointFile = Join-Path $BaseDir "processed_ids.txt"
$LogFile = Join-Path $LogDir "run.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$configPath = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configPath) { . $configPath }

$HeyPocketToken = if ($env:HEYPOCKET_API_TOKEN) { $env:HEYPOCKET_API_TOKEN } else { $HEYPOCKET_API_TOKEN }
$TranslatorKey  = if ($env:MS_TRANSLATOR_KEY)   { $env:MS_TRANSLATOR_KEY }   else { $MS_TRANSLATOR_KEY }

$TranslatorRegion = "westus2"

if (-not $HeyPocketToken) { throw "HEYPOCKET_API_TOKEN missing" }
if (-not $TranslatorKey)  { throw "MS_TRANSLATOR_KEY missing" }

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
   "$ts | Export Started" | Tee-Object -FilePath $LogFile -Append

$SystemLang = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLower()

if ($TargetLang -and $TargetLang.Trim() -ne "") {

	
    "Target Language(s): $TargetLang" | Tee-Object -FilePath $LogFile -Append
}

"System Language: $SystemLang" | Tee-Object -FilePath $LogFile -Append

# ==========================================================
#  LOGS
# ==========================================================

	function Log {
		param([string]$msg)
		$line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
		$line | Out-File -Append $LogFile
		Write-Output $msg
	}

# ==========================================================
# CHECKPOINT
# ==========================================================


$processedIds = @{}

if (Test-Path $CheckpointFile) {
    Get-Content $CheckpointFile | ForEach-Object {
        if ($_ -and $_.Trim()) { $processedIds[$_.Trim()] = $true }
    }
}

# ==========================================================
# HELPERS
# ==========================================================

function Parse-SSE($raw) {
    foreach ($line in ($raw -split "`n")) {
        if ($line -like "data:*") {
            try { return ($line.Substring(5).Trim() | ConvertFrom-Json) } catch {}
        }
    }
}

function Extract-McpJson($Response) {
    if ($Response.result.data) { return $Response.result.data }

    if ($Response.result.content) {
        foreach ($c in $Response.result.content) {
            if ($c.text) {
                try {
                    $parsed = $c.text | ConvertFrom-Json
                    if ($parsed.data) { return $parsed.data }
                } catch {}
            }
        }
    }
    return @()
}

function Get-FlagEmoji($code) {
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($code)

        if ($culture.Name -match "-") {
            $region = $culture.Name.Split('-')[1]
        } else {
            switch ($code.ToLower()) {
                "en" { $region = "GB" }
                "es" { $region = "ES" }
                "fr" { $region = "FR" }
                "de" { $region = "DE" }
                "pt" { $region = "PT" }
                "zh" { $region = "CN" }
                "ar" { $region = "SA" }
                "ja" { $region = "JP" }
                "ko" { $region = "KR" }
                default { return "" }
            }
        }

        $first  = 0x1F1E6 + ([int][char]$region[0] - [int][char]'A')
        $second = 0x1F1E6 + ([int][char]$region[1] - [int][char]'A')

        return [System.Char]::ConvertFromUtf32($first) + [System.Char]::ConvertFromUtf32($second)

    } catch {
        return ""
    }
}


function Get-LanguageDisplay($code) {
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($code)

        if ($SystemLang -eq "en") {
            $name = $culture.EnglishName.Split('(')[0].Trim()
        } else {
            $name = $culture.NativeName.Split('(')[0].Trim()
        }

        $name = $name.Substring(0,1).ToUpper() + $name.Substring(1)

    } catch {
        $name = $code.ToUpper()
    }

    "$((Get-FlagEmoji $code)) $name"
}

function Format-Time($ms) {
    if (-not $ms) { return "00:00" }

    $ts = [TimeSpan]::FromMilliseconds($ms)

    if ($ts.Hours -gt 0) {
        return "{0:00}:{1:00}:{2:00}" -f $ts.Hours, $ts.Minutes, $ts.Seconds
    } else {
        return "{0:00}:{1:00}" -f $ts.Minutes, $ts.Seconds
    }
}

# ==========================================================
# TRANSLATION
# ==========================================================

function Translate-Batch($texts, $toLang) {

    if ($texts.Count -eq 0) { return $texts }

    Write-Host "Translating $($texts.Count) -> $toLang"

    $uri = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=$toLang"

    $headers = @{
        "Ocp-Apim-Subscription-Key"    = $TranslatorKey
        "Ocp-Apim-Subscription-Region" = $TranslatorRegion
    }

    # ✅ always build array payload
		$payloadObjects = @()

		foreach ($t in $texts) {
			$payloadObjects += @{ Text = $t }
		}

		$payload = $payloadObjects | ConvertTo-Json -Depth 5

		# ✅ FORCE ARRAY FORM IF SINGLE OBJECT
		if ($payload.Trim().StartsWith("{")) {
			$payload = "[$payload]"
		}

    try {
        # ✅ switch to Invoke-RestMethod (handles JSON + UTF8 correctly)
        $resp = Invoke-RestMethod `
            -Uri $uri `
            -Method POST `
            -Headers $headers `
            -ContentType "application/json; charset=utf-8" `
            -Body $payload

        if ($resp -isnot [array]) { $resp = @($resp) }

        $results = @()
        foreach ($item in $resp) {
            $results += $item.translations[0].text
        }

        return ,$results

    } catch {
        Write-Host "TRANSLATION ERROR"
        return ,$texts
    }
}
# ==========================================================
# MCP SETUP
# ==========================================================

$Headers = @{
    Authorization = "Bearer $HeyPocketToken"
    "Content-Type" = "application/json"
    Accept = "application/json, text/event-stream"
}

$Uri = "https://public.heypocketai.com/mcp"
$Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# INIT (FIXED)
$initRaw = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @'
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
'@ -WebSession $Session

Parse-SSE $initRaw.Content | Out-Null
$Headers["mcp-session-id"] = $initRaw.Headers["mcp-session-id"]

# INITIALIZED (FIXED)
Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @'
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
'@ -WebSession $Session | Out-Null

# ==========================================================
# SEARCH
# ==========================================================

$searchRaw = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_pocket_conversations","arguments":{"query":"a"}}}
'@ -WebSession $Session

$records = Extract-McpJson (Parse-SSE $searchRaw.Content)

$ids = @{}
foreach ($r in $records) {
    foreach ($rec in $r.recordings) {
        if ($rec.recordingId) { $ids[$rec.recordingId] = $true }
    }
}

$newIds = @{}
foreach ($id in $ids.Keys) {
    if (-not $processedIds.ContainsKey($id)) { $newIds[$id] = $true }
}

if ($newIds.Count -eq 0) {
    Write-Output "No new recordings"
    return
}

# ==========================================================
# FETCH
# ==========================================================

$idArray = $newIds.Keys | ConvertTo-Json

$detailsRaw = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @"
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_pocket_conversation","arguments":{"recording_ids": $idArray}}}
"@ -WebSession $Session

$full = Extract-McpJson (Parse-SSE $detailsRaw.Content)

# ==========================================================
# PROCESS
# ==========================================================

$processedNow = @()

foreach ($rec in $full) {

    if (-not $rec.transcriptSegments) { continue }

    $texts = @()
    $segments = @()
    $seen = @{}

    # --- build texts with dedupe ---
    foreach ($seg in $rec.transcriptSegments) {
        if ($seg.text) {

#            $clean = ($seg.text -replace "\s+", " ").Trim()
			 $clean = $seg.text.Trim()

            if ($clean -and -not $seen.ContainsKey($clean)) {
                $texts += $clean
                $segments += $seg
                $seen[$clean] = $true
            }
        }
    }

    # --- translations ---
    $translations = @{}

    if ($TargetLangs.Count -gt 0) {
        foreach ($lang in $TargetLangs) {
            $translations[$lang] = Translate-Batch @($texts) $lang
        }
    }

    # --- original ---
    $body = "<h2>Original</h2>"

    for ($i=0; $i -lt $texts.Count; $i++) {
        $ts = Format-Time $segments[$i].start
        $body += "<p><span style='color:#888;font-size:11px;'>[$ts]</span> $($texts[$i])</p>"
    }

    # --- translated ---
    foreach ($lang in $TargetLangs) {

        $transArray = @($translations[$lang])
        if (-not $transArray) { continue }

        $langLines = @()

        for ($i=0; $i -lt $texts.Count; $i++) {

            $tran = "$($transArray[$i])"
            $orig = $texts[$i]
            $ts = Format-Time $segments[$i].start

            if ($tran -and $tran -ne $orig) {
                $langLines += "<p><span style='color:#888;font-size:11px;'>[$ts]</span> $tran</p>"
            }
        }

        if ($langLines.Count -gt 0) {
            $langDisplay = Get-LanguageDisplay $lang
            $body += "<h2 style='margin-top:20px;'>$langDisplay Translation</h2>"
            $body += ($langLines -join "")
        }
    }

    # EXPORT (unchanged)
    $title = ($rec.recordingTitle -replace '[\\/:*?"<>|]', '_')
    $file  = Join-Path $OutputDir "$title.enex"
    $created = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

    $enml = "<?xml version='1.0' encoding='UTF-8'?><!DOCTYPE en-note SYSTEM 'http://xml.evernote.com/pub/enml2.dtd'><en-note>$body</en-note>"

    $export = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export2.dtd">
<en-export export-date="$created">
<note>
<title>$title</title>
<content><![CDATA[$enml]]></content>
<created>$created</created>
<tag>heypocket</tag>
<tag>transcript</tag>
</note>
</en-export>
"@

    $Utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($file, $export, $Utf8Bom)

    $processedNow += $rec.recordingId
}

if ($processedNow.Count -gt 0) {
    $processedNow | Add-Content $CheckpointFile
}
$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
"$ts | Completed: $($processedNow.Count) new exports" | Tee-Object -FilePath $LogFile -Append

