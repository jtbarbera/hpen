<#
.SYNOPSIS
    Exports HeyPocket AI conversation transcripts to Evernote (.enex) files,
    with optional machine translation into one or more target languages.

.DESCRIPTION
    This script connects to the HeyPocket MCP (Model Context Protocol) API to
    search for recorded conversations, fetches transcript details for any
    recordings not already processed, and writes each one out as an .enex
    note file (importable into Evernote). If -TargetLang is supplied, each
    transcript segment is additionally translated via the Microsoft
    Translator API and appended to the note under its own section.

    Processed recording IDs are tracked in a checkpoint file so re-running
    the script only exports new recordings.

.PARAMETER TargetLang
    Comma-separated list of target language codes to translate into
    (e.g. "es,fr,de"). Leave blank to export the original transcript only.

.PARAMETER FlagStyle
    Controls how language flags render next to each translation heading:
        wave - (default) larger flag icon with a subtle static skew, so
               flags look slightly rippled/wavy. No animation.
        flat - larger flag icon, no skew.
        off  - no flag icon at all; just the language name.

.PARAMETER Help
    Show this help text and exit without connecting to any API.

.OUTPUTS
    One .enex file per recording, written to .\data\output.
    A running log is written to .\data\logs\run.log.

.NOTES
    Version: 1.1.0
        - Flag labels now render as inline waving-flag <img> tags (Twemoji
          CDN) instead of raw Unicode emoji, for reliable display in
          Evernote/Joplin's note renderer.
        - Translate-Batch now verifies the API returned the same number of
          translations as texts sent, to prevent silent text/timestamp
          misalignment on a partial/merged response.
        - Fixed a single-recording collapse bug: ConvertTo-Json on a
          one-element ID list produced a bare object instead of a JSON
          array, malforming the MCP fetch request body.
        - MCP initialize/search/fetch calls are now wrapped in try/catch
          with logged, actionable error messages instead of throwing an
          unhandled exception.
        - "No new recordings" and "search call failed" are now
          distinguished, instead of both surfacing as the same message.
        - Added Set-StrictMode -Version Latest so undeclared-variable
          typos fail fast instead of evaluating silently to $null.
        - Checkpoint file writes are now deduplicated against existing
          entries before appending.
        - Recording titles that are empty or contain only characters
          stripped by sanitization now fall back to the recording ID, so
          exports can no longer collide on a literal ".enex" filename.

    Requires environment variables (or a config.ps1 in the script folder)
    defining:
        HEYPOCKET_API_TOKEN   - Bearer token for the HeyPocket MCP API
        HEYPOCKET_MCP_URI     - MCP endpoint URL (optional; defaults to
                                 the public HeyPocket endpoint if unset)
        MS_TRANSLATOR_KEY     - Subscription key for Microsoft Translator
        MS_TRANSLATOR_REGION  - Azure region for Microsoft Translator
                                 (optional; defaults to "westus2" if unset)

.EXAMPLE
    .\hpen.ps1
    Exports all new recordings as English-only .enex files.

.EXAMPLE
    .\hpen.ps1 -TargetLang "es,fr"
    Exports all new recordings with Spanish and French translations included.

.EXAMPLE
    .\hpen.ps1 -FlagStyle off
    Exports without any flag icons next to language headings.

.EXAMPLE
    .\hpen.ps1 -TargetLang "es,fr" -FlagStyle flat
    Exports with Spanish/French translations, using larger flags with no
    wave/skew effect.

.EXAMPLE
    .\hpen.ps1 -Help
    Prints this help text and exits.

.EXAMPLE USING INCLUDE BATCH File
    run
    Exports all new recordings as English-only .enex files.

.EXAMPLE USING INCLUDE BATCH File
    run es,fr
    Exports all new recordings with Spanish and French translations included.
#>

param(
    [string]$TargetLang = "",

    # Controls how language flags render in the exported note:
    #   wave - (default) larger flag icon with a slight static wave/skew
    #   flat - larger flag icon, no wave effect
    #   off  - no flag icon at all, just the language name
    [ValidateSet("wave", "flat", "off")]
    [string]$FlagStyle = "wave",

    # Show parameter help and exit (works without API credentials set).
    [Alias("h", "?")]
    [switch]$Help
)

if ($Help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

$ScriptVersion = "1.1.0"

Set-StrictMode -Version Latest

# TLS 1.2 is required for outbound HTTPS calls on Windows PowerShell 5.1.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ==========================================================
# INIT — parse and normalize the requested target languages
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
# PATHS + ENVIRONMENT
# ==========================================================

$BaseDir   = Join-Path $PSScriptRoot "data"
$OutputDir = Join-Path $BaseDir "output"
$LogDir    = Join-Path $BaseDir "logs"

$CheckpointFile = Join-Path $BaseDir "processed_ids.txt"
$LogFile        = Join-Path $LogDir "run.log"

New-Item -ItemType Directory -Force -Path $LogDir    | Out-Null
New-Item -ItemType Directory -Force -Path $BaseDir   | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Optional local override file (not committed) for credentials during dev.
$configPath = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configPath) { . $configPath }

# Prefer environment variables; fall back to values sourced from config.ps1.
# Get-Variable -ErrorAction SilentlyContinue is used (rather than a bare
# $VarName reference) so this stays safe under Set-StrictMode when an
# optional key is present in neither the environment nor config.ps1.
function Get-OptionalVar([string]$Name) {
    $v = Get-Variable -Name $Name -ErrorAction SilentlyContinue
    if ($v) { return $v.Value }
    return $null
}

$HeyPocketToken   = if ($env:HEYPOCKET_API_TOKEN)   { $env:HEYPOCKET_API_TOKEN }   else { Get-OptionalVar "HEYPOCKET_API_TOKEN" }
$HeyPocketUri     = if ($env:HEYPOCKET_MCP_URI)     { $env:HEYPOCKET_MCP_URI }     elseif (Get-OptionalVar "HEYPOCKET_MCP_URI") { Get-OptionalVar "HEYPOCKET_MCP_URI" } else { "https://public.heypocketai.com/mcp" }
$TranslatorKey    = if ($env:MS_TRANSLATOR_KEY)     { $env:MS_TRANSLATOR_KEY }     else { Get-OptionalVar "MS_TRANSLATOR_KEY" }
$TranslatorRegion = if ($env:MS_TRANSLATOR_REGION)  { $env:MS_TRANSLATOR_REGION }  elseif (Get-OptionalVar "MS_TRANSLATOR_REGION") { Get-OptionalVar "MS_TRANSLATOR_REGION" } else { "westus2" }

if (-not $HeyPocketToken) { throw "HEYPOCKET_API_TOKEN missing" }
if (-not $TranslatorKey)  { throw "MS_TRANSLATOR_KEY missing" }

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
"$ts | Export Started (hpen.ps1 v$ScriptVersion)" | Tee-Object -FilePath $LogFile -Append

$SystemLang = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLower()

if ($TargetLang -and $TargetLang.Trim() -ne "") {
    "Target Language(s): $TargetLang" | Tee-Object -FilePath $LogFile -Append
}

"System Language: $SystemLang" | Tee-Object -FilePath $LogFile -Append

# ==========================================================
# LOGGING
# ==========================================================

function Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to both the run log and stdout.
    #>
    param([string]$msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    $line | Out-File -Append $LogFile
    Write-Output $msg
}

# ==========================================================
# CHECKPOINT — load IDs already exported in previous runs
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
    <#
    .SYNOPSIS
        Extracts and parses the first "data:" line from a Server-Sent
        Events (SSE) response body returned by the MCP endpoint.
    .PARAMETER raw
        Raw SSE response text.
    .OUTPUTS
        The parsed JSON object, or $null if no data line was found/valid.
    #>
    foreach ($line in ($raw -split "`n")) {
        if ($line -like "data:*") {
            try { return ($line.Substring(5).Trim() | ConvertFrom-Json) } catch {}
        }
    }
}

function Extract-McpJson($Response) {
    <#
    .SYNOPSIS
        Pulls the payload array out of an MCP tools/call response,
        handling both the direct-data and content-wrapped response shapes.
    .DESCRIPTION
        Guards every property access with PSObject.Properties.Name
        -contains rather than direct dot-access, since Set-StrictMode
        throws PropertyNotFoundException on a missing property instead
        of returning $null. Also detects and logs a JSON-RPC error
        envelope ({"error": {...}} with no "result"), instead of
        silently returning an empty array, which would otherwise look
        identical to "no recordings found."
    .PARAMETER Response
        Parsed JSON-RPC response object from Parse-SSE.
    .OUTPUTS
        Array of result records (empty array if none found or on error).
    #>
    if (-not $Response) { return @() }

    if (($Response.PSObject.Properties.Name -contains 'error') -and $Response.error) {
        Log "MCP call returned an error: $($Response.error.message)"
        return @()
    }

    if (($Response.PSObject.Properties.Name -contains 'result') -and $Response.result) {
        if (($Response.result.PSObject.Properties.Name -contains 'data') -and $Response.result.data) {
            return $Response.result.data
        }
        if (($Response.result.PSObject.Properties.Name -contains 'content') -and $Response.result.content) {
            foreach ($c in $Response.result.content) {
                if (($c.PSObject.Properties.Name -contains 'text') -and $c.text) {
                    try {
                        $parsed = $c.text | ConvertFrom-Json
                        if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'data') -and $parsed.data) {
                            return $parsed.data
                        }
                    } catch {}
                }
            }
        }
    }

    return @()
}

function Get-FlagEmoji($code) {
    <#
    .SYNOPSIS
        Returns an inline <img> tag for the waving-flag emoji matching a
        given language code's default region.
    .DESCRIPTION
        Resolves the region the same way as before (culture region if
        present, else a per-language default), then builds the codepoint
        pair for the Unicode regional-indicator flag sequence. Rather
        than emitting the raw emoji characters -- which render as plain
        boxed letters in Evernote/Joplin's note view, since the note
        renderer doesn't always carry an emoji-capable font -- this
        renders the flag as a small <img> sourced from the Twemoji CDN,
        so the actual waving-flag artwork displays consistently
        regardless of the reader's local font/platform.

        Output is controlled by the script-level $FlagStyle parameter:
          "off"  - returns "" (no flag rendered at all)
          "flat" - larger flag icon, no skew
          "wave" - (default) larger flag icon with a fixed skew/rotate,
                   giving a static rippled look. This is NOT an animation
                   -- CSS @keyframes don't reliably survive ENML
                   sanitization on import into Evernote/Joplin, so the
                   "wave" is just a one-time visual tilt baked into the
                   image's inline style.
    .PARAMETER code
        Two-letter (or culture-qualified) language code, e.g. "en" or "en-GB".
    .OUTPUTS
        HTML <img> tag string for the flag, or "" if the region can't be
        resolved or $FlagStyle is "off".
    #>
    if ($FlagStyle -eq "off") { return "" }

    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($code)

        if ($culture.Name -match "-") {
            $region = $culture.Name.Split('-')[1]
        }
        else {
            # No region in the culture name — fall back to a sensible default
            # country for each supported language.
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

        # Twemoji filenames are the two regional-indicator codepoints in
        # lowercase hex, joined by a hyphen, e.g. "1f1ea-1f1f8" for Spain.
        $first  = "{0:x}" -f (0x1F1E6 + ([int][char]$region[0] - [int][char]'A'))
        $second = "{0:x}" -f (0x1F1E6 + ([int][char]$region[1] - [int][char]'A'))

        $flagUrl = "https://cdn.jsdelivr.net/gh/twitter/twemoji@latest/assets/72x72/$first-$second.png"

        # Larger default size (was 18px) so the flag artwork actually reads
        # clearly at note-view scale.
        $flagSize = 28

        if ($FlagStyle -eq "wave") {
            # Static skew/rotate -- alternated by region so a row of flags
            # doesn't all lean the same way. No animation; just a one-time
            # tilt baked into the inline style.
            $skewSign = if (([int][char]$region[0] % 2) -eq 0) { "-" } else { "" }
            $style = "vertical-align:middle;display:inline-block;transform:skewY(${skewSign}6deg) rotate(${skewSign}2deg);"
        }
        else {
            # "flat" — bigger, no skew.
            $style = "vertical-align:middle;display:inline-block;"
        }

        return "<img src='$flagUrl' width='$flagSize' height='$flagSize' style='$style' alt='$region flag' />"
    }
    catch {
        return ""
    }
}

function Get-LanguageDisplay($code) {
    <#
    .SYNOPSIS
        Builds a human-readable "<flag> <Language name>" label for a
        language code, localized to the system language where possible.
    .PARAMETER code
        Two-letter language code, e.g. "es".
    .OUTPUTS
        Display string containing an inline flag <img> tag plus the
        language name, e.g. "<img .../> Spanish". Intended for direct
        embedding into the ENEX/HTML note body. If $FlagStyle is "off",
        no flag image is included and no leading space is left behind.
    #>
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($code)

        if ($SystemLang -eq "en") {
            $name = $culture.EnglishName.Split('(')[0].Trim()
        }
        else {
            $name = $culture.NativeName.Split('(')[0].Trim()
        }

        $name = $name.Substring(0,1).ToUpper() + $name.Substring(1)
    }
    catch {
        $name = $code.ToUpper()
    }

	$flag = Get-FlagEmoji $code

	if ($FlagStyle -eq "off") {
		return $name
	}

	if ($flag -ne "") {
		return "$flag $name"
	}

	return $name

}

function Format-Time($ms) {
    <#
    .SYNOPSIS
        Formats a millisecond offset as MM:SS, or HH:MM:SS once past an hour.
    .PARAMETER ms
        Offset in milliseconds from the start of the recording.
    .OUTPUTS
        Formatted timestamp string.
    #>
    if (-not $ms) { return "00:00" }

    $ts = [TimeSpan]::FromMilliseconds($ms)

    if ($ts.Hours -gt 0) {
        return "{0:00}:{1:00}:{2:00}" -f $ts.Hours, $ts.Minutes, $ts.Seconds
    }
    else {
        return "{0:00}:{1:00}" -f $ts.Minutes, $ts.Seconds
    }
}

# ==========================================================
# TRANSLATION
# ==========================================================

function Translate-Batch($texts, $toLang) {
    <#
    .SYNOPSIS
        Translates an array of strings into the target language using the
        Microsoft Translator REST API, preserving input order.
    .PARAMETER texts
        Array of source strings to translate.
    .PARAMETER toLang
        Target language code (e.g. "es").
    .OUTPUTS
        Array of translated strings, same length/order as $texts.
        Returns the original $texts unchanged on any API error.
    #>
    if ($texts.Count -eq 0) { return $texts }

    Write-Host "Translating $($texts.Count) -> $toLang"

    $uri = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=$toLang"

    $headers = @{
        "Ocp-Apim-Subscription-Key"    = $TranslatorKey
        "Ocp-Apim-Subscription-Region" = $TranslatorRegion
    }

    # Build the request payload as an array of { Text = ... } objects.
    $payloadObjects = @()
    foreach ($t in $texts) {
        $payloadObjects += @{ Text = $t }
    }

    $payload = $payloadObjects | ConvertTo-Json -Depth 5

    # ConvertTo-Json collapses a single-element array to a bare object —
    # force it back into array form, since the API requires an array body.
    if ($payload.Trim().StartsWith("{")) {
        $payload = "[$payload]"
    }

    try {
        # Invoke-RestMethod handles JSON parsing and UTF-8 decoding for us.
        $resp = Invoke-RestMethod `
            -Uri $uri `
            -Method POST `
            -Headers $headers `
            -ContentType "application/json; charset=utf-8" `
            -Body $payload

        if ($resp -isnot [array]) { $resp = @($resp) }

        if ($resp.Count -ne $texts.Count) {
            Write-Host "TRANSLATION ERROR: expected $($texts.Count) results, got $($resp.Count) -- falling back to original text"
            return ,$texts
        }

        $results = @()
        foreach ($item in $resp) {
            $results += $item.translations[0].text
        }

        return ,$results
    }
    catch {
        Write-Host "TRANSLATION ERROR"
        return ,$texts
    }
}

# ==========================================================
# MCP SESSION SETUP
# ==========================================================

$Headers = @{
    Authorization   = "Bearer $HeyPocketToken"
    "Content-Type"  = "application/json"
    Accept          = "application/json, text/event-stream"
}

$Uri     = $HeyPocketUri
$Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# --- initialize: handshake with the MCP server ---
try {
    $initRaw = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @'
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
'@ -WebSession $Session

    Parse-SSE $initRaw.Content | Out-Null
    $Headers["mcp-session-id"] = $initRaw.Headers["mcp-session-id"]
}
catch {
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | ERROR: MCP initialize failed -- $($_.Exception.Message)" |
        Tee-Object -FilePath $LogFile -Append
    throw "MCP initialize failed: $($_.Exception.Message)"
}

# --- initialized: confirm the session is ready for tool calls ---
try {
    Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @'
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
'@ -WebSession $Session | Out-Null
}
catch {
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | ERROR: MCP initialized notification failed -- $($_.Exception.Message)" |
        Tee-Object -FilePath $LogFile -Append
    throw "MCP initialized notification failed: $($_.Exception.Message)"
}

# ==========================================================
# SEARCH — find candidate recording IDs
# ==========================================================

try {
    $searchRaw = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_pocket_conversations","arguments":{}}}
'@ -WebSession $Session
}
catch {
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | ERROR: search_pocket_conversations call failed -- $($_.Exception.Message)" |
        Tee-Object -FilePath $LogFile -Append
    throw "Search call failed: $($_.Exception.Message)"
}

$records = Extract-McpJson (Parse-SSE $searchRaw.Content)
# $records | ConvertTo-Json -Depth 6 | Out-File search_debug.json
# Write-Host "DEBUG: wrote debug_records.json"


$ids = @{}
foreach ($r in $records) {
    foreach ($rec in $r.recordings) {
        if ($rec.recordingId) { $ids[$rec.recordingId] = $true }
    }
}

# Filter out anything already exported in a previous run.
$newIds = @{}
foreach ($id in $ids.Keys) {
    if (-not $processedIds.ContainsKey($id)) { $newIds[$id] = $true }
}

if ($newIds.Count -eq 0) {
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | Search succeeded -- no new recordings to export" |
        Tee-Object -FilePath $LogFile -Append
    return
}

# ==========================================================
# FETCH — retrieve full transcript details for new recordings
# ==========================================================

$idArray = $newIds.Keys | ConvertTo-Json

# ConvertTo-Json collapses a single-element array to a bare string rather
# than a one-element JSON array (the same PowerShell quirk already worked
# around in Translate-Batch). With exactly one new recording this would
# malform the request body sent to get_pocket_conversation, so force the
# array form here too.
if ($idArray.Trim().StartsWith('"')) {
    $idArray = "[$idArray]"
}

try {
    $detailsRaw = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -UseBasicParsing -Body @"
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_pocket_conversations","arguments":{"query":"a"}}}
"@ -WebSession $Session
}
catch {
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | ERROR: get_pocket_conversation call failed -- $($_.Exception.Message)" |
        Tee-Object -FilePath $LogFile -Append
    throw "Fetch call failed: $($_.Exception.Message)"
}

$full = Extract-McpJson (Parse-SSE $detailsRaw.Content)

# ==========================================================
# PROCESS — restore working flow (section-based)
# ==========================================================

$processedNow = @()

foreach ($rec in @($records.recordings)) {

    # --- Resolve recordingId ---
    $recId = $rec.recordingId
    if (-not $recId) {
        Log "Skipping record: no recordingId"
        continue
    }

    # --- Resolve text (section mode) ---
    if (-not ($rec.PSObject.Properties.Name -contains 'content')) {
        Log "Skipping ${recId}: no content"
        continue
    }

    $text = "$($rec.content)".Trim()
    if (-not $text) {
        Log "Skipping ${recId}: empty content"
        continue
    }

    $startMs = 0
    if ($rec.PSObject.Properties.Name -contains 'sectionStartMs') {
        $startMs = $rec.sectionStartMs
    }

    $texts = @($text)
    $segments = @(
        [PSCustomObject]@{
            text  = $text
            start = $startMs
        }
    )

    # --- translations ---
    $translations = @{}
    if ($TargetLangs.Count -gt 0) {
        foreach ($lang in $TargetLangs) {
            $translations[$lang] = Translate-Batch @($texts) $lang
        }
    }

	$hasTranslations = $false

	foreach ($lang in $TargetLangs) {
		$t = $translations[$lang]
		if ($t -and $t[0] -and $t[0] -ne $text) {
			$hasTranslations = $true
			break
		}
	}

    # --- ORIGINAL ---
    $body = "`n`n### Original`n  `n"
    $ts = Format-Time $startMs
    if ($hasTranslations) {
    $body += "<div><b>[$ts] $text</b></div>"
	} else {
    $body += "<div>[$ts] $text</div>"
	}

    # --- TRANSLATIONS ---
    foreach ($lang in $TargetLangs) {

        $transArray = @($translations[$lang])
        if (-not $transArray) { continue }

        $tran = "$($transArray[0])"
        if ($tran -and $tran -ne $text) {
            $langDisplay = Get-LanguageDisplay $lang
 #           $body += "`n`n### $langDisplay Translation`n  `n"
            $body += "<div><b>---- $langDisplay Translation ----</b></div>"
			$body += "<div>[$ts] $tran</div>"
        }
    }

    # --- TITLE ---
    $title = "$($rec.recordingTitle)"
    $title = ($title -replace '[\\/:*?"<>|]', '_').Trim()

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "recording_$recId"
    }

    # --- WRITE FILE ---
    $file = Join-Path $OutputDir "$title.enex"
    $created = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

 $export = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export3.dtd">
<en-export>
  <note>
    <title>$title</title>
    <created>$created</created>
    <content><![CDATA[
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">
<en-note>
$body
</en-note>
    ]]></content>
  </note>
</en-export>
"@

    $Utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($file, $export, $Utf8Bom)

    Log "Exported: $title"
    $label = $rec.recordingTitle

	if ($rec.PSObject.Properties.Name -contains 'sectionTitle' -and $rec.sectionTitle) {
		$label = $rec.sectionTitle
	}

	$processedNow += "$recId | $label"

}

#--- END BLOCK PROCESS ---# ==========================================================
# CHECKPOINT — record what was exported this run
# ==========================================================

if ($processedNow.Count -gt 0) {
    # Only append IDs not already present, in case of overlapping/interrupted
    # runs -- keeps processed_ids.txt from growing unbounded with duplicates.
    $newCheckpointLines = $processedNow | Where-Object { -not $processedIds.ContainsKey($_) } | Select-Object -Unique
    if ($newCheckpointLines.Count -gt 0) {
        $newCheckpointLines | Add-Content $CheckpointFile
    }
}

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
"$ts | Completed: $($processedNow.Count) new exports" | Tee-Object -FilePath $LogFile -Append