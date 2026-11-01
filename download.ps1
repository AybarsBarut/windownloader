[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI tool uses Write-Host for user interface prompts and status messages.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal CLI helper functions manage local tool state directly.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Helper function names reflect plural domain concepts such as parameters and resolutions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helper functions return dynamic custom objects and primitive types.')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Url,

    [Parameter()]
    [string]$Quality,

    [Parameter()]
    [string]$Format,

    [Parameter()]
    [switch]$AudioOnly,

    [Parameter()]
    [string]$Output,

    [Parameter()]
    [switch]$Playlist,

    [Parameter()]
    [string[]]$Subs,

    [Parameter()]
    [string]$Cookies,

    [Parameter()]
    [switch]$Update,

    [Parameter()]
    [switch]$Uninstall,

    [Parameter()]
    [switch]$Help,

    [Parameter()]
    [switch]$NoRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:InstallRoot = if ($env:VIDEODL_HOME) { $env:VIDEODL_HOME } else { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'VideoDL' }
$script:BinDir = Join-Path -Path $script:InstallRoot -ChildPath 'bin'
$script:DefaultOutputDir = Join-Path -Path $env:USERPROFILE -ChildPath 'Videos\VideoDL'
$script:RepoRawBaseUrl = if ($env:VIDEODL_REPO_URL) { $env:VIDEODL_REPO_URL.TrimEnd('/') } else { 'https://raw.githubusercontent.com/AybarsBarut/windownloader/main' }
$script:AllowedQualities = @('best', '2160', '1440', '1080', '720', '480', '360')
$script:VideoFormats = @('mp4', 'mkv', 'webm')
$script:AudioFormats = @('mp3', 'm4a', 'opus', 'wav')
$script:AllowedFormats = $script:VideoFormats + $script:AudioFormats

function ConvertTo-NormalizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PathItem
    )
    if ([string]::IsNullOrWhiteSpace($PathItem)) {
        return ''
    }
    return $PathItem.Trim().Trim('"').TrimEnd('\', '/')
}

function Test-PathStringEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PathString,

        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )
    if ([string]::IsNullOrWhiteSpace($PathString)) {
        return $false
    }
    $normalizedTarget = ConvertTo-NormalizedPath -PathItem $TargetDir
    $entries = $PathString -split ';'
    foreach ($entry in $entries) {
        $normalizedEntry = ConvertTo-NormalizedPath -PathItem $entry
        if ([string]::Equals($normalizedEntry, $normalizedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-PathStringEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PathString,

        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )
    $cleanTarget = $TargetDir.Trim().Trim('"').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($PathString)) {
        return $cleanTarget
    }
    if (Test-PathStringEntry -PathString $PathString -TargetDir $cleanTarget) {
        return $PathString
    }
    $trimmedPath = $PathString.TrimEnd(';')
    return "$trimmedPath;$cleanTarget"
}

function Remove-PathStringEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PathString,

        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )
    if ([string]::IsNullOrWhiteSpace($PathString)) {
        return ''
    }
    $normalizedTarget = ConvertTo-NormalizedPath -PathItem $TargetDir
    $kept = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($entry in ($PathString -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        $normalizedEntry = ConvertTo-NormalizedPath -PathItem $entry
        if (-not [string]::Equals($normalizedEntry, $normalizedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            $kept.Add($entry.Trim())
        }
    }
    return ($kept -join ';')
}

function Test-VideoUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InputUrl
    )
    if ([string]::IsNullOrWhiteSpace($InputUrl)) {
        return $false
    }
    $trimmed = $InputUrl.Trim()
    if ($trimmed.StartsWith('-')) {
        return $false
    }
    if ($trimmed -match '\s') {
        return $false
    }
    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($trimmed, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        return $false
    }
    if ($parsedUri.Scheme -notin @('http', 'https')) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($parsedUri.Host)) {
        return $false
    }
    if ($parsedUri.Host -notmatch '\.' -and $parsedUri.Host -ne 'localhost') {
        return $false
    }
    return $true
}

function Resolve-CliParameters {
    [CmdletBinding()]
    param(
        [string]$InputUrl,
        [string]$InputQuality,
        [string]$InputFormat,
        [switch]$InputAudioOnly,
        [string]$InputOutput,
        [switch]$InputPlaylist,
        [string[]]$InputSubs,
        [string]$InputCookies,
        [switch]$InputUpdate,
        [switch]$InputUninstall,
        [switch]$InputHelp,
        [string[]]$InputRemainingArgs
    )

    $isUpdate = [bool]$InputUpdate
    $isUninstall = [bool]$InputUninstall
    $isHelp = [bool]$InputHelp
    $effectiveUrl = $InputUrl

    $extraTokens = New-Object -TypeName System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($effectiveUrl) -and $effectiveUrl.StartsWith('-')) {
        $extraTokens.Add($effectiveUrl)
        $effectiveUrl = ''
    }
    if ($null -ne $InputRemainingArgs) {
        foreach ($arg in $InputRemainingArgs) {
            if (-not [string]::IsNullOrWhiteSpace($arg)) {
                $extraTokens.Add($arg)
            }
        }
    }

    foreach ($token in $extraTokens) {
        switch -Regex ($token.ToLowerInvariant()) {
            '^(--update|-update)$' { $isUpdate = $true; continue }
            '^(--uninstall|-uninstall)$' { $isUninstall = $true; continue }
            '^(--help|-help|-h|/\?)$' { $isHelp = $true; continue }
            default {
                return [PSCustomObject]@{
                    IsValid       = $false
                    ExitCode      = 2
                    ErrorMessage  = "Hata: Tanınmayan veya hatalı parametre: '$token'. Yardım için 'download -Help' komutunu kullanın."
                    Action        = 'Error'
                    IsInteractive = $false
                    Url           = $effectiveUrl
                    Quality       = $null
                    Format        = $null
                    IsAudioOnly   = $false
                    Output        = $null
                    Playlist      = $false
                    Subs          = $null
                    Cookies       = $null
                }
            }
        }
    }

    if ($isHelp) {
        return [PSCustomObject]@{
            IsValid       = $true
            ExitCode      = 0
            ErrorMessage  = $null
            Action        = 'Help'
            IsInteractive = $false
            Url           = $null
            Quality       = $null
            Format        = $null
            IsAudioOnly   = $false
            Output        = $null
            Playlist      = $false
            Subs          = $null
            Cookies       = $null
        }
    }

    if ($isUpdate -and $isUninstall) {
        return [PSCustomObject]@{
            IsValid       = $false
            ExitCode      = 2
            ErrorMessage  = 'Hata: -Update ve -Uninstall parametreleri aynı anda kullanılamaz.'
            Action        = 'Error'
            IsInteractive = $false
            Url           = $null
            Quality       = $null
            Format        = $null
            IsAudioOnly   = $false
            Output        = $null
            Playlist      = $false
            Subs          = $null
            Cookies       = $null
        }
    }

    if ($isUpdate) {
        return [PSCustomObject]@{
            IsValid       = $true
            ExitCode      = 0
            ErrorMessage  = $null
            Action        = 'Update'
            IsInteractive = $false
            Url           = $null
            Quality       = $null
            Format        = $null
            IsAudioOnly   = $false
            Output        = $null
            Playlist      = $false
            Subs          = $null
            Cookies       = $null
        }
    }

    if ($isUninstall) {
        return [PSCustomObject]@{
            IsValid       = $true
            ExitCode      = 0
            ErrorMessage  = $null
            Action        = 'Uninstall'
            IsInteractive = $false
            Url           = $null
            Quality       = $null
            Format        = $null
            IsAudioOnly   = $false
            Output        = $null
            Playlist      = $false
            Subs          = $null
            Cookies       = $null
        }
    }

    $normalizedSubs = ''
    if ($null -ne $InputSubs -and $InputSubs.Count -gt 0) {
        $subParts = @(
            $InputSubs |
                ForEach-Object -Process { $_ -split ',' } |
                ForEach-Object -Process { $_.Trim() } |
                Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $normalizedSubs = $subParts -join ','
    }

    $hasAutomationFlag = (
        (-not [string]::IsNullOrWhiteSpace($InputQuality)) -or
        (-not [string]::IsNullOrWhiteSpace($InputFormat)) -or
        [bool]$InputAudioOnly -or
        (-not [string]::IsNullOrWhiteSpace($InputOutput)) -or
        [bool]$InputPlaylist -or
        (-not [string]::IsNullOrWhiteSpace($normalizedSubs))
    )

    $normalizedQuality = $null
    if (-not [string]::IsNullOrWhiteSpace($InputQuality)) {
        $cleanQ = $InputQuality.Trim().ToLowerInvariant()
        if ($cleanQ.EndsWith('p') -and $cleanQ -ne 'best') {
            $cleanQ = $cleanQ.Substring(0, $cleanQ.Length - 1)
        }
        if ($cleanQ -notin $script:AllowedQualities) {
            return [PSCustomObject]@{
                IsValid       = $false
                ExitCode      = 2
                ErrorMessage  = "Hata: Geçersiz çözünürlük değeri '$InputQuality'. Geçerli değerler: $($script:AllowedQualities -join ', ')."
                Action        = 'Error'
                IsInteractive = $false
                Url           = $effectiveUrl
                Quality       = $null
                Format        = $null
                IsAudioOnly   = $false
                Output        = $null
                Playlist      = $false
                Subs          = $null
                Cookies       = $null
            }
        }
        $normalizedQuality = $cleanQ
    }

    $normalizedFormat = $null
    if (-not [string]::IsNullOrWhiteSpace($InputFormat)) {
        $cleanFmt = $InputFormat.Trim().TrimStart('.').ToLowerInvariant()
        if ($cleanFmt -notin $script:AllowedFormats) {
            return [PSCustomObject]@{
                IsValid       = $false
                ExitCode      = 2
                ErrorMessage  = "Hata: Geçersiz format '$InputFormat'. Geçerli formatlar: $($script:AllowedFormats -join ', ')."
                Action        = 'Error'
                IsInteractive = $false
                Url           = $effectiveUrl
                Quality       = $normalizedQuality
                Format        = $null
                IsAudioOnly   = $false
                Output        = $null
                Playlist      = $false
                Subs          = $null
                Cookies       = $null
            }
        }
        $normalizedFormat = $cleanFmt
    }

    $isAudioOnly = [bool]$InputAudioOnly
    if ($null -ne $normalizedFormat -and $normalizedFormat -in $script:AudioFormats) {
        $isAudioOnly = $true
    }
    if ($isAudioOnly -and $null -ne $normalizedFormat -and $normalizedFormat -in $script:VideoFormats) {
        return [PSCustomObject]@{
            IsValid       = $false
            ExitCode      = 2
            ErrorMessage  = "Hata: -AudioOnly seçildiğinde video formatı ('$normalizedFormat') kullanılamaz. Ses formatları: $($script:AudioFormats -join ', ')."
            Action        = 'Error'
            IsInteractive = $false
            Url           = $effectiveUrl
            Quality       = $normalizedQuality
            Format        = $normalizedFormat
            IsAudioOnly   = $true
            Output        = $null
            Playlist      = $false
            Subs          = $null
            Cookies       = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($effectiveUrl)) {
        if (-not (Test-VideoUrl -InputUrl $effectiveUrl)) {
            return [PSCustomObject]@{
                IsValid       = $false
                ExitCode      = 2
                ErrorMessage  = "Hata: Geçersiz URL adresi: '$effectiveUrl'. Lütfen http:// veya https:// ile başlayan geçerli bir bağlantı girin."
                Action        = 'Error'
                IsInteractive = (-not $hasAutomationFlag)
                Url           = $effectiveUrl
                Quality       = $normalizedQuality
                Format        = $normalizedFormat
                IsAudioOnly   = $isAudioOnly
                Output        = $InputOutput
                Playlist      = [bool]$InputPlaylist
                Subs          = $normalizedSubs
                Cookies       = $InputCookies
            }
        }
    } elseif ($hasAutomationFlag) {
        return [PSCustomObject]@{
            IsValid       = $false
            ExitCode      = 2
            ErrorMessage  = 'Hata: Parametreli kullanımda bir video URL adresi belirtilmelidir.'
            Action        = 'Error'
            IsInteractive = $false
            Url           = $null
            Quality       = $normalizedQuality
            Format        = $normalizedFormat
            IsAudioOnly   = $isAudioOnly
            Output        = $InputOutput
            Playlist      = [bool]$InputPlaylist
            Subs          = $normalizedSubs
            Cookies       = $InputCookies
        }
    }

    $effectiveOutput = if ([string]::IsNullOrWhiteSpace($InputOutput)) { $script:DefaultOutputDir } else { $InputOutput.Trim() }
    if (-not $hasAutomationFlag) {
        return [PSCustomObject]@{
            IsValid       = $true
            ExitCode      = 0
            ErrorMessage  = $null
            Action        = 'Download'
            IsInteractive = $true
            Url           = $effectiveUrl
            Quality       = $null
            Format        = $null
            IsAudioOnly   = $false
            Output        = $effectiveOutput
            Playlist      = $false
            Subs          = $normalizedSubs
            Cookies       = $InputCookies
        }
    }

    if ($isAudioOnly) {
        if ([string]::IsNullOrWhiteSpace($normalizedFormat)) {
            $normalizedFormat = 'mp3'
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($normalizedQuality)) {
            $normalizedQuality = 'best'
        }
        if ([string]::IsNullOrWhiteSpace($normalizedFormat)) {
            $normalizedFormat = 'mp4'
        }
    }

    return [PSCustomObject]@{
        IsValid       = $true
        ExitCode      = 0
        ErrorMessage  = $null
        Action        = 'Download'
        IsInteractive = $false
        Url           = $effectiveUrl
        Quality       = $normalizedQuality
        Format        = $normalizedFormat
        IsAudioOnly   = $isAudioOnly
        Output        = $effectiveOutput
        Playlist      = [bool]$InputPlaylist
        Subs          = $normalizedSubs
        Cookies       = $InputCookies
    }
}

function Format-FileSizeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [double]$Bytes = 0
    )
    if ($Bytes -le 0) {
        return 'Boyut bilinmiyor'
    }
    $mb = $Bytes / 1MB
    if ($mb -ge 1024) {
        $gb = $mb / 1024
        return ('~{0:N2} GB' -f $gb)
    }
    return ('~{0:N1} MB' -f $mb)
}

function Format-DurationText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $VideoInfo
    )
    if ($null -eq $VideoInfo) {
        return 'Bilinmiyor'
    }
    if ($VideoInfo.PSObject.Properties.Match('duration_string').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$VideoInfo.duration_string)) {
        return [string]$VideoInfo.duration_string
    }
    if ($VideoInfo.PSObject.Properties.Match('duration').Count -gt 0 -and $null -ne $VideoInfo.duration) {
        $seconds = [int][Math]::Round([double]$VideoInfo.duration)
        $ts = [TimeSpan]::FromSeconds($seconds)
        if ($ts.TotalHours -ge 1) {
            return ('{0:D2}:{1:D2}:{2:D2}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
        }
        return ('{0:D2}:{1:D2}' -f $ts.Minutes, $ts.Seconds)
    }
    return 'Canlı / Bilinmiyor'
}

function Get-FormatEstimatedBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $FormatObj,

        [Parameter(Mandatory = $false)]
        [double]$DurationSeconds = 0
    )
    if ($FormatObj.PSObject.Properties.Match('filesize').Count -gt 0 -and $null -ne $FormatObj.filesize -and [double]$FormatObj.filesize -gt 0) {
        return [double]$FormatObj.filesize
    }
    if ($FormatObj.PSObject.Properties.Match('filesize_approx').Count -gt 0 -and $null -ne $FormatObj.filesize_approx -and [double]$FormatObj.filesize_approx -gt 0) {
        return [double]$FormatObj.filesize_approx
    }
    if ($DurationSeconds -gt 0 -and $FormatObj.PSObject.Properties.Match('tbr').Count -gt 0 -and $null -ne $FormatObj.tbr -and [double]$FormatObj.tbr -gt 0) {
        return ([double]$FormatObj.tbr * 1000.0 / 8.0) * $DurationSeconds
    }
    return 0
}

function Get-StandardResolutionTier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$FormatGroup,

        [Parameter(Mandatory = $true)]
        [int]$RawHeight
    )
    foreach ($fmt in $FormatGroup) {
        if ($fmt.PSObject.Properties.Match('format_note').Count -gt 0 -and $null -ne $fmt.format_note) {
            $note = [string]$fmt.format_note
            if ($note -match '^(?<tier>4320|2160|1440|1080|720|480|360|240|144)p\b') {
                return [int]$Matches['tier']
            }
        }
    }
    foreach ($fmt in $FormatGroup) {
        if ($fmt.PSObject.Properties.Match('width').Count -gt 0 -and $null -ne $fmt.width -and [int]$fmt.width -gt $RawHeight) {
            $w = [int]$fmt.width
            if ($w -ge 3800) { return 2160 }
            if ($w -ge 2500) { return 1440 }
            if ($w -ge 1900) { return 1080 }
            if ($w -ge 1200) { return 720 }
            if ($w -ge 800)  { return 480 }
            if ($w -ge 600)  { return 360 }
            if ($w -ge 400)  { return 240 }
            if ($w -ge 200)  { return 144 }
        }
    }
    return $RawHeight
}

function Get-AvailableResolutions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $VideoInfo
    )

    $durationSec = 0.0
    if ($VideoInfo.PSObject.Properties.Match('duration').Count -gt 0 -and $null -ne $VideoInfo.duration) {
        $durationSec = [double]$VideoInfo.duration
    }

    $formats = @()
    if ($VideoInfo.PSObject.Properties.Match('formats').Count -gt 0 -and $null -ne $VideoInfo.formats) {
        $formats = @($VideoInfo.formats)
    }

    $bestAudioBytes = 0.0
    $audioCandidates = @(
        $formats | Where-Object -FilterScript {
            $hasAcodec = $_.PSObject.Properties.Match('acodec').Count -gt 0 -and $null -ne $_.acodec -and [string]$_.acodec -ne 'none'
            $vcodecVal = if ($_.PSObject.Properties.Match('vcodec').Count -gt 0 -and $null -ne $_.vcodec) { [string]$_.vcodec } else { 'none' }
            $hasAcodec -and ($vcodecVal -eq 'none')
        }
    )
    foreach ($aud in $audioCandidates) {
        $audSize = Get-FormatEstimatedBytes -FormatObj $aud -DurationSeconds $durationSec
        if ($audSize -gt $bestAudioBytes) {
            $bestAudioBytes = $audSize
        }
    }

    $videoFormats = @(
        $formats | Where-Object -FilterScript {
            $hasHeight = $_.PSObject.Properties.Match('height').Count -gt 0 -and $null -ne $_.height -and [int]$_.height -gt 0
            $vcodecVal = if ($_.PSObject.Properties.Match('vcodec').Count -gt 0 -and $null -ne $_.vcodec) { [string]$_.vcodec } else { '' }
            $hasHeight -and ($vcodecVal -ne 'none')
        }
    )

    $results = New-Object -TypeName System.Collections.Generic.List[object]
    $groupedByHeight = $videoFormats | Group-Object -Property { [int]$_.height } | Sort-Object -Property { [int]$_.Name } -Descending

    foreach ($group in $groupedByHeight) {
        $actualHeight = [int]$group.Name
        $tierVal = Get-StandardResolutionTier -FormatGroup @($group.Group) -RawHeight $actualHeight
        $bestForHeight = $group.Group |
            Where-Object -FilterScript {
                $proto = if ($_.PSObject.Properties.Match('protocol').Count -gt 0 -and $null -ne $_.protocol) { [string]$_.protocol } else { 'https' }
                $proto -notmatch 'm3u8'
            } |
            Sort-Object -Property @(
                @{ Expression = { if ($_.PSObject.Properties.Match('fps').Count -gt 0 -and $null -ne $_.fps) { [double]$_.fps } else { 0.0 } }; Descending = $true },
                @{ Expression = {
                    $vc = if ($_.PSObject.Properties.Match('vcodec').Count -gt 0 -and $null -ne $_.vcodec) { [string]$_.vcodec } else { '' }
                    if ($vc -match '^(avc1|h264)') { 3 } elseif ($vc -match '^vp0?9') { 2 } elseif ($vc -match '^av01') { 0 } else { 1 }
                }; Descending = $true },
                @{ Expression = { Get-FormatEstimatedBytes -FormatObj $_ -DurationSeconds $durationSec }; Descending = $true },
                @{ Expression = { if ($_.PSObject.Properties.Match('tbr').Count -gt 0 -and $null -ne $_.tbr) { [double]$_.tbr } else { 0.0 } }; Descending = $true }
            ) |
            Select-Object -First 1

        if ($null -eq $bestForHeight) {
            $bestForHeight = $group.Group | Select-Object -First 1
        }
        $fpsVal = 30
        if ($bestForHeight.PSObject.Properties.Match('fps').Count -gt 0 -and $null -ne $bestForHeight.fps -and [double]$bestForHeight.fps -gt 0) {
            $fpsVal = [int][Math]::Round([double]$bestForHeight.fps)
        }

        $videoBytes = Get-FormatEstimatedBytes -FormatObj $bestForHeight -DurationSeconds $durationSec
        $acodecVal = if ($bestForHeight.PSObject.Properties.Match('acodec').Count -gt 0 -and $null -ne $bestForHeight.acodec) { [string]$bestForHeight.acodec } else { 'none' }
        $totalBytes = $videoBytes
        if ($videoBytes -gt 0 -and $acodecVal -eq 'none' -and $bestAudioBytes -gt 0) {
            $totalBytes = $videoBytes + $bestAudioBytes
        }

        $results.Add([PSCustomObject]@{
            Height             = $tierVal
            Quality            = [string]$actualHeight
            Label              = "${tierVal}p"
            Fps                = $fpsVal
            EstimatedSizeBytes = [int64][Math]::Round($totalBytes)
            SizeText           = Format-FileSizeText -Bytes $totalBytes
            IsAudioOnly        = $false
        })
    }

    if ($results.Count -eq 0) {
        $fallbackBytes = 0.0
        foreach ($f in $formats) {
            $sz = Get-FormatEstimatedBytes -FormatObj $f -DurationSeconds $durationSec
            if ($sz -gt $fallbackBytes) {
                $fallbackBytes = $sz
            }
        }
        $results.Add([PSCustomObject]@{
            Height             = 0
            Quality            = 'best'
            Label              = 'Varsayılan video kalitesi (best)'
            Fps                = 30
            EstimatedSizeBytes = [int64][Math]::Round($fallbackBytes)
            SizeText           = Format-FileSizeText -Bytes $fallbackBytes
            IsAudioOnly        = $false
        })
    }

    $results.Add([PSCustomObject]@{
        Height             = 0
        Quality            = 'audio'
        Label              = 'Yalnızca ses (Audio Only)'
        Fps                = $null
        EstimatedSizeBytes = [int64][Math]::Round($bestAudioBytes)
        SizeText           = Format-FileSizeText -Bytes $bestAudioBytes
        IsAudioOnly        = $true
    })

    return $results.ToArray()
}

function Select-EffectiveQuality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedQuality,

        [Parameter(Mandatory = $false)]
        [object[]]$AvailableResolutions
    )

    $cleanReq = $RequestedQuality.Trim().ToLowerInvariant()
    if ($cleanReq.EndsWith('p') -and $cleanReq -ne 'best') {
        $cleanReq = $cleanReq.Substring(0, $cleanReq.Length - 1)
    }

    if ($cleanReq -eq 'best') {
        return [PSCustomObject]@{
            EffectiveQuality = 'best'
            FallbackUsed     = $false
            Message          = $null
        }
    }

    $videoRes = @()
    if ($null -ne $AvailableResolutions) {
        $videoRes = @(
            $AvailableResolutions |
                Where-Object -FilterScript { (-not $_.IsAudioOnly) -and ([int]$_.Height -gt 0) } |
                Sort-Object -Property { [int]$_.Height } -Descending
        )
    }

    if ($videoRes.Count -eq 0) {
        return [PSCustomObject]@{
            EffectiveQuality = 'best'
            FallbackUsed     = $true
            Message          = "Bilgi: Kaynakta ayrı çözünürlük bilgisi bulunamadı, mevcut en iyi video akışı (best) indiriliyor."
        }
    }

    $reqHeight = [int]$cleanReq
    $exactMatch = $videoRes | Where-Object -FilterScript { [int]$_.Height -eq $reqHeight } | Select-Object -First 1
    if ($null -ne $exactMatch) {
        $effQ = if ($exactMatch.PSObject.Properties.Match('Quality').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$exactMatch.Quality)) { [string]$exactMatch.Quality } else { [string]$exactMatch.Height }
        return [PSCustomObject]@{
            EffectiveQuality = $effQ
            FallbackUsed     = $false
            Message          = $null
        }
    }

    $lowerMatch = $videoRes | Where-Object -FilterScript { [int]$_.Height -lt $reqHeight } | Sort-Object -Property { [int]$_.Height } -Descending | Select-Object -First 1
    if ($null -ne $lowerMatch) {
        $fallbackLabelH = [string]$lowerMatch.Height
        $effQ = if ($lowerMatch.PSObject.Properties.Match('Quality').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$lowerMatch.Quality)) { [string]$lowerMatch.Quality } else { $fallbackLabelH }
        return [PSCustomObject]@{
            EffectiveQuality = $effQ
            FallbackUsed     = $true
            Message          = "Bilgi: İstenen ${reqHeight}p çözünürlük mevcut değil, en yakın düşük çözünürlüğe (${fallbackLabelH}p) düşüldü."
        }
    }

    $lowestAvailable = $videoRes | Sort-Object -Property { [int]$_.Height } | Select-Object -First 1
    $lowestLabelH = [string]$lowestAvailable.Height
    $effQ = if ($lowestAvailable.PSObject.Properties.Match('Quality').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$lowestAvailable.Quality)) { [string]$lowestAvailable.Quality } else { $lowestLabelH }
    return [PSCustomObject]@{
        EffectiveQuality = $effQ
        FallbackUsed     = $true
        Message          = "Bilgi: İstenen ${reqHeight}p çözünürlük mevcut değil, mevcut en düşük çözünürlük (${lowestLabelH}p) seçildi."
    }
}

function Get-YtDlpFormatSelector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SelectedQuality = 'best',

        [Parameter(Mandatory = $false)]
        [string]$SelectedFormat = 'mp4',

        [Parameter(Mandatory = $false)]
        [switch]$IsAudioOnly
    )

    $cleanFmt = $SelectedFormat.Trim().ToLowerInvariant()
    if ($IsAudioOnly -or ($cleanFmt -in $script:AudioFormats)) {
        return [PSCustomObject]@{
            FormatExpression  = 'bestaudio/best'
            MergeOutputFormat = $null
            ExtractAudio      = $true
            AudioFormat       = $cleanFmt
            Arguments         = @('-f', 'bestaudio/best', '-x', '--audio-format', $cleanFmt)
        }
    }

    $cleanQ = $SelectedQuality.Trim().ToLowerInvariant()
    if ($cleanQ.EndsWith('p') -and $cleanQ -ne 'best') {
        $cleanQ = $cleanQ.Substring(0, $cleanQ.Length - 1)
    }

    if ($cleanQ -eq 'best' -or [string]::IsNullOrWhiteSpace($cleanQ)) {
        $fmtExpr = 'bv*+ba/b'
    } else {
        $fmtExpr = "bv*[height<=$cleanQ]+ba/b[height<=$cleanQ]"
    }

    $sortExpr = if ($cleanFmt -eq 'webm') {
        'res,fps,vcodec:vp9,vcodec:h264,acodec:opus'
    } else {
        'res,fps,vcodec:h264,vcodec:vp9,acodec:m4a'
    }

    return [PSCustomObject]@{
        FormatExpression  = $fmtExpr
        MergeOutputFormat = $cleanFmt
        ExtractAudio      = $false
        AudioFormat       = $null
        Arguments         = @('-f', $fmtExpr, '-S', $sortExpr, '--merge-output-format', $cleanFmt)
    }
}

function Get-YtDlpArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $false)]
        [string]$SelectedQuality = 'best',

        [Parameter(Mandatory = $false)]
        [string]$SelectedFormat = 'mp4',

        [Parameter(Mandatory = $false)]
        [switch]$IsAudioOnly,

        [Parameter(Mandatory = $false)]
        [string]$OutputDirectory = $script:DefaultOutputDir,

        [Parameter(Mandatory = $false)]
        [switch]$IncludePlaylist,

        [Parameter(Mandatory = $false)]
        [string]$SubtitleLangs,

        [Parameter(Mandatory = $false)]
        [string]$BrowserCookies,

        [Parameter(Mandatory = $false)]
        [string]$FfmpegPath,

    [Parameter(Mandatory = $false)]
        [string]$PrintFilePath,

        [Parameter(Mandatory = $false)]
        [switch]$NoCheckCertificate,

        [Parameter(Mandatory = $false)]
        [string]$RefererUrl,

        [Parameter(Mandatory = $false)]
        [string]$OriginUrl,

        [Parameter(Mandatory = $false)]
        [string]$UserAgent,

        [Parameter(Mandatory = $false)]
        [switch]$HlsPreferFfmpeg,

        [Parameter(Mandatory = $false)]
        [string]$CustomOutputTemplate
    )

    $argList = New-Object -TypeName System.Collections.Generic.List[string]
    $selector = Get-YtDlpFormatSelector -SelectedQuality $SelectedQuality -SelectedFormat $SelectedFormat -IsAudioOnly:$IsAudioOnly
    foreach ($item in $selector.Arguments) {
        $argList.Add($item)
    }

    $argList.Add('--windows-filenames')
    $argList.Add('--continue')
    $argList.Add('--no-update')
    $argList.Add('--progress')
    $argList.Add('--no-quiet')

    if ($NoCheckCertificate) {
        $argList.Add('--no-check-certificate')
    }

    if ($HlsPreferFfmpeg) {
        $argList.Add('--hls-prefer-ffmpeg')
    }

    if (-not [string]::IsNullOrWhiteSpace($RefererUrl)) {
        $argList.Add('--referer')
        $argList.Add($RefererUrl.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($UserAgent)) {
        $argList.Add('--user-agent')
        $argList.Add($UserAgent.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($OriginUrl)) {
        $argList.Add('--add-header')
        $argList.Add("Origin:$($OriginUrl.Trim())")
    }

    if ($IncludePlaylist) {
        $argList.Add('--yes-playlist')
    } else {
        $argList.Add('--no-playlist')
    }

    if (-not [string]::IsNullOrWhiteSpace($SubtitleLangs)) {
        $argList.Add('--write-subs')
        $argList.Add('--write-auto-subs')
        $argList.Add('--sub-langs')
        $argList.Add($SubtitleLangs.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($BrowserCookies)) {
        $argList.Add('--cookies-from-browser')
        $argList.Add($BrowserCookies.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($FfmpegPath)) {
        $argList.Add('--ffmpeg-location')
        $argList.Add($FfmpegPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($PrintFilePath)) {
        $argList.Add('--print-to-file')
        $argList.Add('after_move:filepath')
        $argList.Add($PrintFilePath)
    }

    $outputTemplate = if (-not [string]::IsNullOrWhiteSpace($CustomOutputTemplate)) {
        $CustomOutputTemplate
    } else {
        Join-Path -Path $OutputDirectory -ChildPath '%(title).150B [%(id)s].%(ext)s'
    }
    $argList.Add('-o')
    $argList.Add($outputTemplate)
    $argList.Add('--')
    $argList.Add($TargetUrl)

    return $argList.ToArray()
}

function Convert-YtDlpErrorToTurkish {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$RawError
    )
    if ([string]::IsNullOrWhiteSpace($RawError)) {
        return 'Hata: Video işlemi sırasında beklenmeyen bir sorun oluştu. Ayrıntılar için -Verbose kullanın.'
    }

    if ($RawError -match '(?i)(No space left on device|not enough space on the disk|disk full|Errno 28)') {
        return 'Hata: Diskte yeterli boş alan yok. Lütfen alanı kontrol edip tekrar deneyin.'
    }
    if ($RawError -match '(?i)(not available in your country|geo-restricted|blocked in your country|uploader has not made this video available in your country)') {
        return 'Hata: Bu video bulunduğunuz bölgede (coğrafi kısıtlama nedeniyle) kullanılamıyor.'
    }
    if ($RawError -match '(?i)(Sign in to confirm your age|age-restricted|Private video|login required|members-only|Please sign in|cookies|HTTP Error 401|This video is private)') {
        return 'Hata: Bu içerik yaş sınırı veya oturum açma gerektiriyor (-Cookies <tarayici> parametresini deneyin).'
    }
    if ($RawError -match '(?i)(HTTP Error 403)') {
        return "Hata: Video akışı sunucu tarafından reddedildi (HTTP 403). 'download --update' ile yt-dlp sürümünü güncellemeyi veya -Cookies <tarayici> kullanmayı deneyin."
    }
    if ($RawError -match '(?i)(getaddrinfo failed|Name or service not known|Network is unreachable|Connection reset|timed out|URLError|Failed to establish a new connection|TransportError)') {
        return 'Hata: Ağ bağlantısı kurulamadı. İnternet bağlantınızı veya hedef adresi kontrol edin.'
    }
    if ($RawError -match '(?i)(Unsupported URL|is not a valid URL|Unable to extract|Video unavailable|HTTP Error 404|Incomplete YouTube ID)') {
        return 'Hata: Geçersiz, bulunamayan veya desteklenmeyen URL adresi.'
    }
    if ($RawError -match '(?i)(ffmpeg|ffprobe).*not found') {
        return 'Hata: Birleştirme/dönüştürme için gerekli olan ffmpeg bulunamadı.'
    }

    return 'Hata: Video indirilemedi. Ham hata detaylarını görmek için -Verbose parametresini ekleyin.'
}

function Test-YtDlpVersionOutdated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpExePath
    )
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $verOut = & $YtDlpExePath --version 2>&1
        $verCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($verCode -ne 0 -or $null -eq $verOut) {
        return $true
    }
    $verStr = ($verOut | Select-Object -First 1).ToString().Trim()
    if ($verStr -match '^(?<y>\d{4})\.(?<m>\d{2})\.(?<d>\d{2})') {
        try {
            $verDate = New-Object -TypeName DateTime -ArgumentList @([int]$Matches['y'], [int]$Matches['m'], [int]$Matches['d'])
            if (([DateTime]::UtcNow - $verDate).TotalDays -gt 60) {
                return $true
            }
        } catch {
            return $false
        }
    }
    return $false
}

function Resolve-ToolExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName
    )
    $localCandidate = Join-Path -Path $script:BinDir -ChildPath "$ToolName.exe"
    if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
        return $localCandidate
    }
    $cmd = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }
    return $null
}

function Install-FfmpegBinary {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:BinDir)) {
        New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
    }
    $zipUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    $tempZip = Join-Path -Path $env:TEMP -ChildPath "videodl_ffmpeg_$([guid]::NewGuid().ToString('N')).zip"
    $tempExtract = Join-Path -Path $env:TEMP -ChildPath "videodl_ffmpeg_extract_$([guid]::NewGuid().ToString('N'))"
    try {
        Write-Host 'ffmpeg GitHub üzerinden indiriliyor (BtbN/FFmpeg-Builds)...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        $zipInfo = Get-Item -LiteralPath $tempZip
        if ($zipInfo.Length -lt 10MB) {
            throw 'İndirilen ffmpeg arşiv dosyası beklenenden küçük veya bozuk.'
        }
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force
        $ffmpegExe = Get-ChildItem -Path $tempExtract -Filter 'ffmpeg.exe' -Recurse -File | Select-Object -First 1
        if ($null -eq $ffmpegExe) {
            throw 'Arşiv içinde ffmpeg.exe bulunamadı.'
        }
        Copy-Item -LiteralPath $ffmpegExe.FullName -Destination (Join-Path -Path $script:BinDir -ChildPath 'ffmpeg.exe') -Force
        $ffprobeExe = Get-ChildItem -Path $tempExtract -Filter 'ffprobe.exe' -Recurse -File | Select-Object -First 1
        if ($null -ne $ffprobeExe) {
            Copy-Item -LiteralPath $ffprobeExe.FullName -Destination (Join-Path -Path $script:BinDir -ChildPath 'ffprobe.exe') -Force
        }
        $installedFfmpeg = Join-Path -Path $script:BinDir -ChildPath 'ffmpeg.exe'
        $verOut = & $installedFfmpeg -version 2>&1
        if ($LASTEXITCODE -ne 0 -or ($verOut -join "`n") -notmatch 'ffmpeg version') {
            throw 'ffmpeg doğrulaması başarısız oldu.'
        }
        Write-Host 'ffmpeg başarıyla kuruldu.' -ForegroundColor Green
        return $installedFfmpeg
    } finally {
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempExtract) {
            Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-Dependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$IsInteractive
    )
    $ytDlpExe = Resolve-ToolExecutable -ToolName 'yt-dlp'
    $needsYtDlpDownload = [string]::IsNullOrWhiteSpace($ytDlpExe)
    if (-not $needsYtDlpDownload -and (Test-YtDlpVersionOutdated -YtDlpExePath $ytDlpExe)) {
        Write-Host 'Sistemdeki yt-dlp sürümü eski; YouTube uyumluluğu için en güncel sürüm indiriliyor...' -ForegroundColor Yellow
        $needsYtDlpDownload = $true
    }
    if ($needsYtDlpDownload) {
        if (-not (Test-Path -LiteralPath $script:BinDir)) {
            New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
        }
        $targetYtDlp = Join-Path -Path $script:BinDir -ChildPath 'yt-dlp.exe'
        Write-Host 'yt-dlp resmi GitHub sürümü indiriliyor...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $targetYtDlp -UseBasicParsing
        if ((Get-Item -LiteralPath $targetYtDlp).Length -lt 1MB) {
            throw 'İndirilen yt-dlp.exe bozuk veya eksik.'
        }
        $ytDlpExe = $targetYtDlp
    }

    $ffmpegExe = Resolve-ToolExecutable -ToolName 'ffmpeg'
    if ([string]::IsNullOrWhiteSpace($ffmpegExe)) {
        if ($IsInteractive) {
            $ans = Read-Host -Prompt 'ffmpeg bulunamadı. Otomatik olarak indirilsin mi? (E/h)'
            if ([string]::IsNullOrWhiteSpace($ans) -or $ans.Trim() -match '^(e|evet|y|yes)$') {
                $ffmpegExe = Install-FfmpegBinary
            } else {
                Write-Host 'Hata: Birleştirme ve dönüştürme işlemleri için ffmpeg gereklidir.' -ForegroundColor Red
                return $null
            }
        } else {
            Write-Host 'Bilgi: Sistemde ffmpeg bulunamadı. Otomatik kurulum için: download --update veya install.ps1 çalıştırabilirsiniz. Şimdi otomatik indiriliyor...' -ForegroundColor Yellow
            $ffmpegExe = Install-FfmpegBinary
        }
    }

    return [PSCustomObject]@{
        YtDlpPath  = $ytDlpExe
        FfmpegPath = $ffmpegExe
    }
}

function Show-HelpMessage {
    [CmdletBinding()]
    param()
    $helpLines = @(
        'VideoDL - Yerel PowerShell Video ve Ses İndirici (download)',
        '',
        'KULLANIM:',
        '  download                                           # Etkileşimli mod (URL, çözünürlük ve format sorar)',
        '  download <url>                                     # Etkileşimli mod (doğrudan çözünürlük ve format sorar)',
        '  download <url> -Quality 1080 -Format mp4           # Parametreli (otomatik) mod',
        '  download <url> -AudioOnly -Format mp3              # Yalnızca ses indirme',
        '  download <url> -Quality best -Output "D:\Videolar" # En yüksek kaliteyi özel klasöre indir',
        '  download <url> -Playlist                           # Oynatma listesinin tamamını indir',
        '  download <url> -Subs tr,en                         # Altyazıları indir (tr, en)',
        '  download <url> -Cookies firefox                    # Tarayıcı çerezlerini kullan',
        '  download --update                                  # yt-dlp ve VideoDL betiğini güncelle',
        '  download --uninstall                               # VideoDL aracını ve PATH kaydını kaldır',
        '',
        'PARAMETRELER:',
        '  -Quality    : best | 2160 | 1440 | 1080 | 720 | 480 | 360',
        '  -Format     : mp4 | mkv | webm | mp3 | m4a | opus | wav',
        '  -AudioOnly  : Yalnızca ses akışını indirir ve dönüştürür',
        '  -Output     : Çıktı klasörü (Varsayılan: %USERPROFILE%\Videos\VideoDL)',
        '  -Playlist   : Tek video yerine oynatma listesini indirir',
        '  -Subs       : İndirilecek altyazı dilleri (ör. tr,en)',
        '  -Cookies    : Çerez alınacak tarayıcı adı (chrome, firefox, edge, brave)',
        '  -Update     : Aracı ve bağımlılıkları günceller (--update)',
        '  -Uninstall  : Aracı sistemden tamamen kaldırır (--uninstall)',
        '  -Help       : Bu yardım ekranını gösterir (--help)',
        '  -Verbose    : Hata durumunda yt-dlp ham hata çıktısını gösterir'
    )
    foreach ($line in $helpLines) {
        Write-Host $line
    }
}

function Invoke-VideoDlUpdate {
    [CmdletBinding()]
    param()
    Write-Host 'VideoDL ve bağımlılıklar güncelleniyor...' -ForegroundColor Cyan
    $ytDlpExe = Resolve-ToolExecutable -ToolName 'yt-dlp'
    if (-not [string]::IsNullOrWhiteSpace($ytDlpExe)) {
        Write-Host "yt-dlp güncelleniyor ($ytDlpExe)..." -ForegroundColor Cyan
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $updateOut = & $ytDlpExe -U 2>&1
            $updateText = ($updateOut | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($updateText)) {
                Write-Verbose $updateText
            }
            if ($updateText -match '(?i)(installed yt-dlp with pip|using the wheel from PyPi|package manager)') {
                Write-Host 'Bilgi: Sistemdeki yt-dlp paket yöneticisi ile kurulmuş; VideoDL için en güncel bağımsız yt-dlp.exe indiriliyor...' -ForegroundColor Cyan
                if (-not (Test-Path -LiteralPath $script:BinDir)) {
                    New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
                }
                $targetYtDlp = Join-Path -Path $script:BinDir -ChildPath 'yt-dlp.exe'
                Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $targetYtDlp -UseBasicParsing
                Write-Host 'Güncel yt-dlp.exe başarıyla indirildi.' -ForegroundColor Green
            } else {
                Write-Host 'yt-dlp güncelleme kontrolü tamamlandı.' -ForegroundColor Green
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }
    } else {
        if (-not (Test-Path -LiteralPath $script:BinDir)) {
            New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
        }
        $targetYtDlp = Join-Path -Path $script:BinDir -ChildPath 'yt-dlp.exe'
        Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $targetYtDlp -UseBasicParsing
        Write-Host 'yt-dlp en güncel sürüme indirildi.' -ForegroundColor Green
    }

    if (-not (Test-Path -LiteralPath $script:InstallRoot)) {
        New-Item -ItemType Directory -Path $script:InstallRoot -Force | Out-Null
    }
    $targetScript = Join-Path -Path $script:InstallRoot -ChildPath 'download.ps1'
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $remoteScriptUrl = "$($script:RepoRawBaseUrl)/download.ps1?t=$cacheBust"
    $tempScript = Join-Path -Path $env:TEMP -ChildPath "videodl_update_$([guid]::NewGuid().ToString('N')).ps1"
    try {
        Invoke-WebRequest -Uri $remoteScriptUrl -OutFile $tempScript -UseBasicParsing
        if ((Get-Item -LiteralPath $tempScript).Length -gt 512) {
            $rawContent = (Get-Content -LiteralPath $tempScript -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
            $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
            [System.IO.File]::WriteAllText($targetScript, $rawContent, $utf8Bom)
            Write-Host 'download.ps1 başarıyla güncellendi.' -ForegroundColor Green
        }
    } catch {
        Write-Verbose "Uzaktan betik güncelleme hatası: $($_.Exception.Message)"
        if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath) -and ($PSCommandPath -ne $targetScript)) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $targetScript -Force
            Write-Host 'download.ps1 yerel kaynaktan güncellendi.' -ForegroundColor Green
        } else {
            Write-Host 'Bilgi: Uzak depo adresine erişilemedi, mevcut download.ps1 korundu.' -ForegroundColor Yellow
        }
    } finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
    return 0
}

function Invoke-VideoDlUninstall {
    [CmdletBinding()]
    param()
    Write-Host 'VideoDL kaldırılıyor...' -ForegroundColor Cyan

    $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathStringEntry -PathString $currentUserPath -TargetDir $script:BinDir) {
        $cleanedUserPath = Remove-PathStringEntry -PathString $currentUserPath -TargetDir $script:BinDir
        [Environment]::SetEnvironmentVariable('Path', $cleanedUserPath, 'User')
        Write-Host "Kullanıcı PATH değişkeninden '$($script:BinDir)' kaldırıldı." -ForegroundColor Green
    }

    if (Test-PathStringEntry -PathString $env:Path -TargetDir $script:BinDir) {
        $env:Path = Remove-PathStringEntry -PathString $env:Path -TargetDir $script:BinDir
    }

    if (Test-Path -LiteralPath $script:InstallRoot) {
        try {
            Remove-Item -LiteralPath $script:InstallRoot -Recurse -Force -ErrorAction Stop
        } catch {
            $cleanupCmd = "ping 127.0.0.1 -n 2 > nul & rmdir /s /q `"$($script:InstallRoot)`""
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cleanupCmd) -WindowStyle Hidden
        }
        Write-Host "Kurulum klasörü silindi: $($script:InstallRoot)" -ForegroundColor Green
    } else {
        Write-Host 'Kurulum klasörü zaten mevcut değil.' -ForegroundColor Yellow
    }

    Write-Host 'VideoDL sistemden tamamen kaldırıldı.' -ForegroundColor Green
    return 0
}

$script:DefaultUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$script:AltUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0'
$script:LastYtDlpRawError = ''

function Get-UrlOrigin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InputUrl
    )
    if ([string]::IsNullOrWhiteSpace($InputUrl)) {
        return ''
    }
    $parsed = $null
    if ([System.Uri]::TryCreate($InputUrl.Trim(), [System.UriKind]::Absolute, [ref]$parsed)) {
        if ($parsed.IsDefaultPort) {
            return "$($parsed.Scheme)://$($parsed.Host)"
        }
        return "$($parsed.Scheme)://$($parsed.Host):$($parsed.Port)"
    }
    return ''
}

function ConvertTo-SafeFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$RawTitle
    )
    if ([string]::IsNullOrWhiteSpace($RawTitle)) {
        return "video_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    }
    $decoded = [System.Net.WebUtility]::HtmlDecode($RawTitle).Trim()
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object -TypeName System.Text.StringBuilder
    foreach ($ch in $decoded.ToCharArray()) {
        if ($invalidChars -contains $ch -or [int]$ch -lt 32) {
            [void]$sb.Append('_')
        } else {
            [void]$sb.Append($ch)
        }
    }
    $cleaned = ($sb.ToString() -replace '\s+', ' ' -replace '_{2,}', '_').Trim(' ', '.', '_')
    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        return "video_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    }
    if ($cleaned.Length -gt 110) {
        $cleaned = $cleaned.Substring(0, 110).Trim(' ', '.', '_')
    }
    return $cleaned
}

function ConvertFrom-EscapedMediaUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$RawCandidate,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$BaseUrl
    )
    if ([string]::IsNullOrWhiteSpace($RawCandidate)) {
        return ''
    }
    $u = $RawCandidate.Trim().Trim('"', "'", '`', ' ', "`t", "`r", "`n")
    $u = $u -replace '\\+/', '/'
    $u = $u -replace '\\u0026', '&'
    $u = $u -replace '\\u002[fF]', '/'
    $u = $u -replace '\\u003[aA]', ':'
    $u = $u -replace '\\u003[dD]', '='
    $u = $u -replace '\\u003[fF]', '?'
    $u = $u -replace '\\x2[fF]', '/'
    $u = $u -replace '\\x3[aA]', ':'
    $u = $u -replace '\\x26', '&'
    $u = $u -replace '&amp;', '&'
    $u = $u.Trim()

    if ([string]::IsNullOrWhiteSpace($u) -or $u -match '^(javascript:|data:|mailto:|about:|blob:|#)') {
        return ''
    }

    if ($u.StartsWith('//')) {
        $scheme = 'https:'
        $baseUri = $null
        if (-not [string]::IsNullOrWhiteSpace($BaseUrl) -and [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$baseUri)) {
            $scheme = "$($baseUri.Scheme):"
        }
        $u = "$scheme$u"
    } elseif (-not ($u -match '^https?://')) {
        $baseUri = $null
        if (-not [string]::IsNullOrWhiteSpace($BaseUrl) -and [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$baseUri)) {
            $resolved = $null
            if ([System.Uri]::TryCreate($baseUri, $u, [ref]$resolved)) {
                $u = $resolved.AbsoluteUri
            } else {
                return ''
            }
        } else {
            return ''
        }
    }

    $finalUri = $null
    if ([System.Uri]::TryCreate($u, [System.UriKind]::Absolute, [ref]$finalUri) -and $finalUri.Scheme -in @('http', 'https')) {
        return $finalUri.AbsoluteUri
    }
    return ''
}

function ConvertFrom-BaseNToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [int]$Radix
    )
    if ($Radix -lt 2 -or $Radix -gt 62 -or [string]::IsNullOrEmpty($Token)) {
        return -1
    }
    $result = 0
    foreach ($ch in $Token.ToCharArray()) {
        $code = [int]$ch
        $digit = -1
        if ($code -ge 48 -and $code -le 57) {
            $digit = $code - 48
        } elseif ($code -ge 97 -and $code -le 122) {
            $digit = ($code - 97) + 10
        } elseif ($code -ge 65 -and $code -le 90) {
            $digit = ($code - 65) + 36
        }
        if ($digit -lt 0 -or $digit -ge $Radix) {
            return -1
        }
        $result = ($result * $Radix) + $digit
    }
    return $result
}

function Expand-PackedJavaScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Content
    )
    if ([string]::IsNullOrWhiteSpace($Content) -or $Content -notmatch 'eval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k') {
        return ''
    }

    $unpackedBlocks = New-Object -TypeName System.Collections.Generic.List[string]
    $pattern = "(?s)eval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k\s*,\s*e\s*,\s*[dr]\s*\)\s*\{.*?\}\s*\(\s*(?<q1>['`"])(?<p>(?:\\.|(?!\k<q1>).)*)\k<q1>\s*,\s*(?<a>\d+)\s*,\s*(?<c>\d+)\s*,\s*(?<q2>['`"])(?<k>(?:\\.|(?!\k<q2>).)*)\k<q2>\s*\.split\(\s*['`"]\|['`"]\s*\)"
    $matchesList = [regex]::Matches($Content, $pattern)

    foreach ($m in $matchesList) {
        $payload = $m.Groups['p'].Value
        $radix = 0
        if (-not [int]::TryParse($m.Groups['a'].Value, [ref]$radix) -or $radix -lt 2 -or $radix -gt 62) {
            continue
        }
        $symTable = $m.Groups['k'].Value -split '\|'
        $expanded = [regex]::Replace($payload, '\b[0-9a-zA-Z]+\b', {
            param($wordMatch)
            $token = $wordMatch.Value
            $idx = ConvertFrom-BaseNToken -Token $token -Radix $radix
            if ($idx -ge 0 -and $idx -lt $symTable.Count -and -not [string]::IsNullOrEmpty($symTable[$idx])) {
                return $symTable[$idx]
            }
            return $token
        })
        $expanded = $expanded -replace "\\'", "'" -replace '\\"', '"'
        $unpackedBlocks.Add($expanded)
    }

    return ($unpackedBlocks -join "`n")
}

function Expand-Base64StringsInText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Content
    )
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ''
    }

    $decodedBlocks = New-Object -TypeName System.Collections.Generic.List[string]
    $b64Patterns = @(
        'atob\(\s*["''](?<b64>[A-Za-z0-9+/=_-]{16,})["'']\s*\)',
        'Base64\.decode\(\s*["''](?<b64>[A-Za-z0-9+/=_-]{16,})["'']\s*\)',
        '["''](?<b64>aHR0c[A-Za-z0-9+/=_-]{12,})["'']'
    )

    foreach ($pat in $b64Patterns) {
        $mList = [regex]::Matches($Content, $pat)
        foreach ($m in $mList) {
            $rawB64 = $m.Groups['b64'].Value.Trim().Replace('-', '+').Replace('_', '/')
            $mod = $rawB64.Length % 4
            if ($mod -eq 2) { $rawB64 += '==' }
            elseif ($mod -eq 3) { $rawB64 += '=' }
            elseif ($mod -eq 1) { continue }

            try {
                $bytes = [System.Convert]::FromBase64String($rawB64)
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($text -match '(https?://|\.m3u8|\.mp4|\.mpd|manifest|playlist|master|/embed/|/player/)') {
                    $decodedBlocks.Add($text)
                }
            } catch {
                continue
            }
        }
    }

    return ($decodedBlocks -join "`n")
}

function Expand-JsVariableCipherStreams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$PageUrl
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ''
    }

    $varMat = [regex]::Match($Content, '(?i)(?:sources\s*:\s*\[\s*\{[^\}]*?\bfile|\bfile)\s*:\s*(?<v>[a-zA-Z_$][a-zA-Z0-9_$]*)\b')
    if (-not $varMat.Success) {
        return ''
    }
    $varName = $varMat.Groups['v'].Value
    if ($varName -in @('true', 'false', 'null', 'undefined', 'window', 'document', 'this')) {
        return ''
    }

    $scriptBlocks = [regex]::Matches($Content, '(?is)<script[^>]*>(?<body>.*?)</script>')
    $targetJs = ''
    foreach ($sb in $scriptBlocks) {
        $body = $sb.Groups['body'].Value
        if ($body -match "\b(?:var|let|const)\s+$([regex]::Escape($varName))\s*=") {
            $targetJs = $body
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($targetJs)) {
        return ''
    }

    $hostName = ''
    $parsedUri = $null
    if ([System.Uri]::TryCreate($PageUrl, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        $hostName = $parsedUri.Host
    }
    $originUrl = Get-UrlOrigin -InputUrl $PageUrl

    $cscriptExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cscript.exe'
    if (Test-Path -LiteralPath $cscriptExe -PathType Leaf) {
        $polyHeader = @"
var location = { hostname: "$hostName", href: "$PageUrl", origin: "$originUrl" };
var window = { location: location };
var document = { location: location, cookie: "" };
function btoa(s) { return String(s); }
function atob(input) {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    var str = String(input).replace(/=+$/, "");
    var output = "";
    for (var bc = 0, bs = 0, buffer, idx = 0; buffer = str.charAt(idx++); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
        buffer = chars.indexOf(buffer);
    }
    return output;
}
"@
        $tempJs = Join-Path -Path $env:TEMP -ChildPath "videodl_cipher_$([guid]::NewGuid().ToString('N')).js"
        $prevEap = $ErrorActionPreference
        try {
            $fullJs = $polyHeader + "`r`n" + $targetJs + "`r`nif (typeof $varName !== 'undefined') { WScript.Echo('`"' + $varName + '`"'); }"
            [System.IO.File]::WriteAllText($tempJs, $fullJs, [System.Text.Encoding]::ASCII)
            $ErrorActionPreference = 'Continue'
            $csOut = & $cscriptExe //NoLogo //E:JScript //T:5 $tempJs 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $csOut) {
                $joined = ($csOut -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($joined)) {
                    return $joined
                }
            }
        } catch {
            Write-Verbose "cscript JS cipher çözümleme hatası: $($_.Exception.Message)"
        } finally {
            $ErrorActionPreference = $prevEap
            if (Test-Path -LiteralPath $tempJs) {
                Remove-Item -LiteralPath $tempJs -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return ''
}

function Test-StreamHasAuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$StreamUrl
    )
    if ([string]::IsNullOrWhiteSpace($StreamUrl)) {
        return $false
    }
    return [bool]($StreamUrl -match '(?i)([?&](token|expires|exp|sig|signature|hash|md5|tms|hdnea|wmsAuthSign|Policy|Key-Pair-Id|auth|st|e|s)=)')
}

function Test-IsLikelyMediaStreamUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$CandidateUrl
    )
    if ([string]::IsNullOrWhiteSpace($CandidateUrl)) {
        return $false
    }
    if ($CandidateUrl -match '(?i)/(?:embed|e|iframe|player)/[^/?#]+\.mp4(\?|$)') {
        return $false
    }
    if ($CandidateUrl -match '(?i)\.(js|css|png|jpg|jpeg|gif|svg|webp|ico|woff2?|ttf|eot|json|xml|html?|php|asp|aspx)(\?|$)') {
        if ($CandidateUrl -notmatch '(?i)(m3u8|mp4|mpd|manifest|master|playlist)') {
            return $false
        }
    }
    if ($CandidateUrl -match '(?i)(google-analytics|googletagmanager|doubleclick|facebook\.com/tr|yandex|histats|cloudflareinsights|adsystem|adservice|fontawesome|jquery|bootstrap)') {
        return $false
    }
    return [bool]($CandidateUrl -match '(?i)(\.m3u8(\b|\?|$)|\.mp4(\b|\?|$)|\.mpd(\b|\?|$)|/(manifest|playlist|master|hls|stream)[^"''\s]*(\.m3u8|\.mp4|\.txt|\?))')
}

function Extract-StreamsAndIframesFromContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$PageUrl,

        [Parameter(Mandatory = $false)]
        [string]$SourceLabel = 'Katman 2 (Sayfa Kaynağı)'
    )

    $streams = New-Object -TypeName System.Collections.Generic.List[object]
    $iframes = New-Object -TypeName System.Collections.Generic.List[string]
    $subtitles = New-Object -TypeName System.Collections.Generic.List[string]
    $seenStreams = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $seenIframes = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return [PSCustomObject]@{
            PageTitle   = ''
            Streams     = @()
            IframeUrls  = @()
            Subtitles   = @()
            HasDrmHint  = $false
            DrmDetails  = ''
        }
    }

    $pageTitle = ''
    if ($Content -match '(?is)<meta\s+[^>]*property=["'']og:title["''][^>]*content=["''](?<t>[^"'']+)["'']') {
        $pageTitle = $Matches['t'].Trim()
    } elseif ($Content -match '(?is)<title[^>]*>(?<t>.*?)</title>') {
        $pageTitle = ($Matches['t'] -replace '\s+', ' ').Trim()
    }

    $hasDrmHint = $false
    $drmDetails = ''
    if ($Content -match '(?i)(urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed|com\.widevine\.alpha|com\.apple\.fps|com\.microsoft\.playready|#EXT-X-KEY:METHOD=SAMPLE-AES|<ContentProtection[^>]+cenc:pssh)') {
        $hasDrmHint = $true
        $drmDetails = $Matches[0]
    }

    # Sahte honeypot URL içeren ld+json bloklarını birincil taramadan ayır
    $contentWithoutLdJson = [regex]::Replace($Content, '(?is)<script[^>]*type\s*=\s*["'']application/ld\+json["''][^>]*>.*?</script>', '')

    $cipherDecoded = Expand-JsVariableCipherStreams -Content $contentWithoutLdJson -PageUrl $PageUrl
    $unpackedJs = Expand-PackedJavaScript -Content $contentWithoutLdJson
    $decodedB64 = Expand-Base64StringsInText -Content ($contentWithoutLdJson + "`n" + $unpackedJs)

    $iframeRegexList = @(
        '(?is)<iframe\s+[^>]*?(?:data-litespeed-src|data-lazy-src|data-src|src)\s*=\s*["''](?<u>[^"''\s<>]+)["'']',
        '(?i)(?:data-frame|data-embed|data-player|embed_url|iframe_url|player_url)\s*[:=]\s*["''](?<u>(?:https?:)?//[^"''\s<>]+|/[^"''\s<>]+)["'']'
    )

    $combinedForIframes = $Content + "`n" + $unpackedJs + "`n" + $decodedB64
    foreach ($irx in $iframeRegexList) {
        $imCol = [regex]::Matches($combinedForIframes, $irx)
        foreach ($im in $imCol) {
            $rawIf = $im.Groups['u'].Value
            $cleanIf = ConvertFrom-EscapedMediaUrl -RawCandidate $rawIf -BaseUrl $PageUrl
            if ([string]::IsNullOrWhiteSpace($cleanIf)) {
                continue
            }
            if ($cleanIf -match '(?i)(googletagmanager|google\.com/recaptcha|facebook\.com/plugins|disqus\.com|doubleclick|youtube\.com/subscribe_embed|about:blank)') {
                continue
            }
            if ($seenIframes.Add($cleanIf)) {
                $iframes.Add($cleanIf)
            }
        }
    }

    $segmentsToScan = @(
        [PSCustomObject]@{ Text = $cipherDecoded;        Method = 'Katman 2d (JS Cipher Değişken Çözücü)' },
        [PSCustomObject]@{ Text = $unpackedJs;           Method = 'Katman 2d (Packed JS Çözücü)' },
        [PSCustomObject]@{ Text = $decodedB64;           Method = 'Katman 2e (Base64 Decode)' },
        [PSCustomObject]@{ Text = $contentWithoutLdJson; Method = "$SourceLabel - Regex" }
    )

    $originUrl = Get-UrlOrigin -InputUrl $PageUrl

    $streamRegexList = @(
        '["''](?<u>https?:(?:\\+/|/){2}[^"''\s<>]+?\.m3u8[^"''\s<>]*)["'']',
        '["''](?<u>https?:(?:\\+/|/){2}[^"''\s<>]+?\.mp4[^"''\s<>]*)["'']',
        '["''](?<u>https?:(?:\\+/|/){2}[^"''\s<>]+?\.mpd[^"''\s<>]*)["'']',
        '["''](?<u>https?:(?:\\+/|/){2}[^"''\s<>]+?\.(?:vtt|srt)[^"''\s<>]*)["'']',
        '["''](?<u>https?:(?:\\+/|/){2}[^"''\s<>]+?(?:manifest|playlist|master)\.(?:m3u8|txt|json)[^"''\s<>]*)["'']',
        '(?i)["'']?(?:file|source|src|url|video_url|stream_url|hls_url|hlsUrl|videoUrl|streamUrl|manifestUrl|masterUrl|contentUrl|subtitle|sub)["'']?\s*[:=]\s*["''](?<u>[^"''\s<>]+)["'']',
        '(?i)hls\.loadSource\(\s*["''](?<u>[^"''\s<>]+)["'']\s*\)',
        '(?i)<source\s+[^>]*src=["''](?<u>[^"''\s<>]+)["'']',
        '(?i)<track\s+[^>]*src=["''](?<u>[^"''\s<>]+)["'']',
        '(?i)<video\s+[^>]*src=["''](?<u>[^"''\s<>]+)["'']'
    )

    foreach ($seg in $segmentsToScan) {
        if ([string]::IsNullOrWhiteSpace($seg.Text)) {
            continue
        }
        foreach ($rx in $streamRegexList) {
            $mCol = [regex]::Matches($seg.Text, $rx)
            foreach ($m in $mCol) {
                $rawU = $m.Groups['u'].Value
                $cleanU = ConvertFrom-EscapedMediaUrl -RawCandidate $rawU -BaseUrl $PageUrl
                if ([string]::IsNullOrWhiteSpace($cleanU)) {
                    continue
                }
                if ($seenIframes.Contains($cleanU)) {
                    continue
                }
                if ($cleanU -match '(?i)\.(vtt|srt)(\?|$)') {
                    if (-not $subtitles.Contains($cleanU)) {
                        $subtitles.Add($cleanU)
                    }
                    continue
                }
                if (-not (Test-IsLikelyMediaStreamUrl -CandidateUrl $cleanU)) {
                    continue
                }
                if ($seenStreams.Add($cleanU)) {
                    $sType = if ($cleanU -match '(?i)\.m3u8|(manifest|playlist|master)\.(txt|m3u8)') {
                        'm3u8'
                    } elseif ($cleanU -match '(?i)\.mpd(\b|\?|$)') {
                        'mpd'
                    } else {
                        'mp4'
                    }
                    $streams.Add([PSCustomObject]@{
                        StreamUrl      = $cleanU
                        StreamType     = $sType
                        Referer        = $PageUrl
                        Origin         = $originUrl
                        HasToken       = (Test-StreamHasAuthToken -StreamUrl $cleanU)
                        DiscoveryLayer = $seg.Method
                        IsAes128       = $false
                        IsDrm          = $false
                    })
                }
            }
        }
    }

    return [PSCustomObject]@{
        PageTitle   = $pageTitle
        Streams     = $streams.ToArray()
        IframeUrls  = $iframes.ToArray()
        Subtitles   = $subtitles.ToArray()
        HasDrmHint  = $hasDrmHint
        DrmDetails  = $drmDetails
    }
}

function Invoke-WebPageFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $false)]
        [string]$RefererUrl = '',

        [Parameter(Mandatory = $false)]
        [string]$UserAgent = $script:DefaultUserAgent,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 18
    )

    $originUrl = if (-not [string]::IsNullOrWhiteSpace($RefererUrl)) { Get-UrlOrigin -InputUrl $RefererUrl } else { Get-UrlOrigin -InputUrl $TargetUrl }
    $curlExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\curl.exe'
    if (Test-Path -LiteralPath $curlExe -PathType Leaf) {
        $curlArgs = New-Object -TypeName System.Collections.Generic.List[string]
        $curlArgs.Add('-s')
        $curlArgs.Add('-L')
        $curlArgs.Add('-k')
        $curlArgs.Add('--compressed')
        $curlArgs.Add('--max-time')
        $curlArgs.Add([string]$TimeoutSeconds)
        $curlArgs.Add('-A')
        $curlArgs.Add($UserAgent)
        $curlArgs.Add('-H')
        $curlArgs.Add('Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
        $curlArgs.Add('-H')
        $curlArgs.Add('Accept-Language: tr-TR,tr;q=0.9,en-US;q=0.8,en;q=0.7')
        if (-not [string]::IsNullOrWhiteSpace($RefererUrl)) {
            $curlArgs.Add('-e')
            $curlArgs.Add($RefererUrl)
        }
        if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
            $curlArgs.Add('-H')
            $curlArgs.Add("Origin: $originUrl")
        }
        $curlArgs.Add($TargetUrl)

        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $curlArgsArr = $curlArgs.ToArray()
            $rawLines = & $curlExe @curlArgsArr 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $rawLines) {
                $joined = ($rawLines -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($joined) -and $joined -notmatch '(?i)(<title>Just a moment\.\.\.</title>|cf-browser-verification)') {
                    return $joined
                }
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    # Cloudflare TLS parmak izi engeli varsa Python curl_cffi ile Chrome TLS impersonation dene
    $pyCmd = Get-Command -Name 'python' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pyCmd -and -not [string]::IsNullOrWhiteSpace($pyCmd.Source)) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $pyInline = "import sys; from curl_cffi import requests; r=requests.get(sys.argv[1], headers={'Referer': sys.argv[2]} if sys.argv[2] else {}, impersonate='chrome', verify=False, timeout=15); sys.stdout.buffer.write(r.content)"
            $cfLines = & $pyCmd.Source -c $pyInline $TargetUrl $RefererUrl 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $cfLines) {
                $cfJoined = ($cfLines -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($cfJoined)) {
                    return $cfJoined
                }
            }
        } catch {
            Write-Verbose "curl_cffi yedek isteği başarısız: $($_.Exception.Message)"
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    try {
        $headers = @{
            'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            'Accept-Language' = 'tr-TR,tr;q=0.9,en-US;q=0.8,en;q=0.7'
        }
        if (-not [string]::IsNullOrWhiteSpace($RefererUrl)) {
            $headers['Referer'] = $RefererUrl
        }
        if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
            $headers['Origin'] = $originUrl
        }
        $resp = Invoke-WebRequest -Uri $TargetUrl -UserAgent $UserAgent -Headers $headers -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        if ($null -ne $resp -and -not [string]::IsNullOrWhiteSpace($resp.Content)) {
            return [string]$resp.Content
        }
    } catch {
        Write-Verbose "Invoke-WebPageFetch hatası ($TargetUrl): $($_.Exception.Message)"
    }
    return ''
}

function Resolve-HeadlessBrowserPath {
    [CmdletBinding()]
    param()
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($path in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }
    $cmd = Get-Command -Name @('msedge', 'chrome') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }
    return $null
}

function Invoke-FirePlayerApiCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$PageUrl,

        [Parameter(Mandatory = $false)]
        [string]$ParentReferer = ''
    )

    $results = New-Object -TypeName System.Collections.Generic.List[object]
    $hashVal = ''
    if ($PageUrl -match '(?i)/player/index\.php\?data=(?<h>[a-f0-9]{16,64})') {
        $hashVal = $Matches['h']
    } elseif (-not [string]::IsNullOrWhiteSpace($Content) -and $Content -match '(?i)FirePlayer\(\s*["''](?<h>[a-f0-9]{16,64})["'']') {
        $hashVal = $Matches['h']
    }

    if ([string]::IsNullOrWhiteSpace($hashVal)) {
        return @()
    }

    $origin = Get-UrlOrigin -InputUrl $PageUrl
    if ([string]::IsNullOrWhiteSpace($origin)) {
        return @()
    }

    $apiUrl = "$origin/player/index.php?data=$hashVal&do=getVideo"
    $refToSend = if (-not [string]::IsNullOrWhiteSpace($ParentReferer)) { $ParentReferer } else { $PageUrl }
    $curlExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\curl.exe'
    $jsonResp = ''

    if (Test-Path -LiteralPath $curlExe -PathType Leaf) {
        $cArgs = @(
            '-s', '-L', '-k', '--max-time', '15',
            '-X', 'POST',
            '-A', $script:DefaultUserAgent,
            '-e', $PageUrl,
            '-H', "Origin: $origin",
            '-H', 'X-Requested-With: XMLHttpRequest',
            '-H', 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8',
            '--data-raw', "hash=$hashVal&r=$([System.Uri]::EscapeDataString($refToSend))",
            $apiUrl
        )
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $lines = & $curlExe @cArgs 2>$null
            if ($null -ne $lines) {
                $jsonResp = ($lines -join "`n").Trim()
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($jsonResp)) {
        foreach ($field in @('securedLink', 'videoSource')) {
            if ($jsonResp -match "`"$field`"\s*:\s*`"(?<u>[^`"]+)`"") {
                $cleanU = ConvertFrom-EscapedMediaUrl -RawCandidate $Matches['u'] -BaseUrl $PageUrl
                if (-not [string]::IsNullOrWhiteSpace($cleanU)) {
                    $results.Add([PSCustomObject]@{
                        StreamUrl      = $cleanU
                        StreamType     = 'm3u8'
                        Referer        = $PageUrl
                        Origin         = $origin
                        HasToken       = (Test-StreamHasAuthToken -StreamUrl $cleanU)
                        DiscoveryLayer = 'Katman 2d (FirePlayer XHR API)'
                        IsAes128       = $false
                        IsDrm          = $false
                    })
                }
            }
        }
    }

    return $results.ToArray()
}

function Invoke-DynamicAjaxPlayerCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$PageUrl
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return [PSCustomObject]@{ Streams = @(); IframeUrls = @() }
    }

    $postId = ''
    if ($Content -match '(?i)data-post-id\s*=\s*["''](?<id>\d+)["'']') {
        $postId = $Matches['id']
    } elseif ($Content -match '(?i)"post_id"\s*:\s*"?(?<id>\d+)"?') {
        $postId = $Matches['id']
    }
    if ([string]::IsNullOrWhiteSpace($postId)) {
        return [PSCustomObject]@{ Streams = @(); IframeUrls = @() }
    }

    $actionName = 'get_episode_player'
    if ($Content -match '(?i)action=(?<a>get_episode_player|get_player|load_player|doo_player_ajax)') {
        $actionName = $Matches['a']
    } elseif ($Content -notmatch '(?i)(episode-player-container|get_episode_player|doo_player_ajax)') {
        return [PSCustomObject]@{ Streams = @(); IframeUrls = @() }
    }

    $origin = Get-UrlOrigin -InputUrl $PageUrl
    $ajaxEndpoint = "$origin/wp-admin/admin-ajax.php"
    if ($Content -match '(?i)"ajax_url"\s*:\s*"(?<u>[^"]+)"') {
        $resolvedAjax = ConvertFrom-EscapedMediaUrl -RawCandidate $Matches['u'] -BaseUrl $PageUrl
        if (-not [string]::IsNullOrWhiteSpace($resolvedAjax)) {
            $ajaxEndpoint = $resolvedAjax
        }
    }

    $queryUrl = "${ajaxEndpoint}?action=${actionName}&post_id=${postId}"
    $ajaxResp = Invoke-WebPageFetch -TargetUrl $queryUrl -RefererUrl $PageUrl -UserAgent $script:DefaultUserAgent
    if ([string]::IsNullOrWhiteSpace($ajaxResp)) {
        return [PSCustomObject]@{ Streams = @(); IframeUrls = @() }
    }

    $unescaped = $ajaxResp -replace '\\"', '"' -replace '\\+/', '/'
    return (Extract-StreamsAndIframesFromContent -Content $unescaped -PageUrl $PageUrl -SourceLabel 'Katman 2c/2d (AJAX Player API)')
}

function Invoke-HeadlessDomCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $false)]
        [int]$WaitBudgetMs = 6000
    )

    # 1. Python Playwright varsa network trafiğini (m3u8/mp4/manifest) ve DOM'u yakala
    $pyCmd = Get-Command -Name 'python' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pyCmd -and -not [string]::IsNullOrWhiteSpace($pyCmd.Source)) {
        $pyScript = @"
import sys
try:
    from playwright.sync_api import sync_playwright
except Exception:
    sys.exit(2)

url = sys.argv[1]
wait_ms = int(sys.argv[2])
captured = []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    context = browser.new_context(ignore_https_errors=True)
    page = context.new_page()
    def on_req(req):
        u = req.url
        if any(k in u.lower() for k in ['.m3u8', '.mp4', '.mpd', 'manifest', 'playlist', 'master']):
            captured.append(u)
    page.on('request', on_req)
    try:
        page.goto(url, wait_until='domcontentloaded', timeout=15000)
        page.wait_for_timeout(wait_ms)
    except Exception:
        pass
    html = page.content()
    browser.close()

for c in captured:
    print(f'<!-- MEDIAFETCH_NET_STREAM: "{c}" -->')
print(html)
"@
        $tempPy = Join-Path -Path $env:TEMP -ChildPath "videodl_pw_$([guid]::NewGuid().ToString('N')).py"
        $prevEap = $ErrorActionPreference
        try {
            [System.IO.File]::WriteAllText($tempPy, $pyScript, [System.Text.Encoding]::UTF8)
            $ErrorActionPreference = 'Continue'
            $pwLines = & $pyCmd.Source $tempPy $TargetUrl $WaitBudgetMs 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $pwLines) {
                $pwOut = ($pwLines -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($pwOut)) {
                    return $pwOut
                }
            }
        } catch {
            Write-Verbose "Playwright yakalama hatası: $($_.Exception.Message)"
        } finally {
            $ErrorActionPreference = $prevEap
            if (Test-Path -LiteralPath $tempPy) {
                Remove-Item -LiteralPath $tempPy -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 2. Yerel Edge / Chrome Headless (--dump-dom + --log-net-log)
    $browserExe = Resolve-HeadlessBrowserPath
    if ([string]::IsNullOrWhiteSpace($browserExe)) {
        return ''
    }

    $netLogFile = Join-Path -Path $env:TEMP -ChildPath "videodl_netlog_$([guid]::NewGuid().ToString('N')).json"
    $browserArgs = @(
        '--headless=new',
        '--disable-gpu',
        '--no-sandbox',
        '--ignore-certificate-errors',
        '--autoplay-policy=no-user-gesture-required',
        "--user-agent=$script:DefaultUserAgent",
        "--log-net-log=$netLogFile",
        "--virtual-time-budget=$WaitBudgetMs",
        '--dump-dom',
        $TargetUrl
    )

    $prevEap = $ErrorActionPreference
    $combinedOut = ''
    try {
        $ErrorActionPreference = 'Continue'
        $domLines = & $browserExe @browserArgs 2>$null
        if ($null -ne $domLines) {
            $combinedOut = ($domLines -join "`n").Trim()
        }
        if (Test-Path -LiteralPath $netLogFile) {
            $netRaw = Get-Content -LiteralPath $netLogFile -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($netRaw)) {
                $combinedOut = $combinedOut + "`n" + $netRaw
            }
        }
    } catch {
        Write-Verbose "Headless tarayıcı DOM yakalama hatası: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $prevEap
        if (Test-Path -LiteralPath $netLogFile) {
            Remove-Item -LiteralPath $netLogFile -Force -ErrorAction SilentlyContinue
        }
    }
    return $combinedOut
}

function Invoke-Layer2PageAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $false)]
        [int]$MaxIframeDepth = 3,

        [Parameter(Mandatory = $false)]
        [switch]$UseHeadlessBrowser
    )

    $allStreams = New-Object -TypeName System.Collections.Generic.List[object]
    $allSubtitles = New-Object -TypeName System.Collections.Generic.List[string]
    $allIframes = New-Object -TypeName System.Collections.Generic.List[string]
    $seenStreamUrls = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $visitedPages = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $bestTitle = ''
    $drmDetected = $false
    $drmNote = ''

    $queue = New-Object -TypeName System.Collections.Generic.Queue[object]
    $queue.Enqueue([PSCustomObject]@{
        Url     = $TargetUrl
        Referer = (Get-UrlOrigin -InputUrl $TargetUrl)
        Depth   = 0
    })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $visitedPages.Add($current.Url)) {
            continue
        }

        $label = if ($current.Depth -eq 0) { 'Katman 2b/2d (Ana Sayfa Kaynağı)' } else { "Katman 2c (Iframe Derinlik $($current.Depth))" }
        Write-Host "  -> [$label] İnceleniyor: $($current.Url)" -ForegroundColor DarkCyan

        $html = Invoke-WebPageFetch -TargetUrl $current.Url -RefererUrl $current.Referer -UserAgent $script:DefaultUserAgent
        if ([string]::IsNullOrWhiteSpace($html)) {
            $html = Invoke-WebPageFetch -TargetUrl $current.Url -RefererUrl $current.Referer -UserAgent $script:AltUserAgent
        }

        if (-not [string]::IsNullOrWhiteSpace($html)) {
            $extracted = Extract-StreamsAndIframesFromContent -Content $html -PageUrl $current.Url -SourceLabel $label
            if ([string]::IsNullOrWhiteSpace($bestTitle) -and -not [string]::IsNullOrWhiteSpace($extracted.PageTitle)) {
                $bestTitle = $extracted.PageTitle
            }
            if ($extracted.HasDrmHint) {
                $drmDetected = $true
                $drmNote = $extracted.DrmDetails
            }
            foreach ($s in $extracted.Streams) {
                if ($seenStreamUrls.Add($s.StreamUrl)) {
                    $allStreams.Add($s)
                }
            }
            $fpStreams = @(Invoke-FirePlayerApiCheck -Content $html -PageUrl $current.Url -ParentReferer $current.Referer)
            foreach ($fps in $fpStreams) {
                if ($seenStreamUrls.Add($fps.StreamUrl)) {
                    $allStreams.Add($fps)
                }
            }
            $ajaxExtracted = Invoke-DynamicAjaxPlayerCheck -Content $html -PageUrl $current.Url
            foreach ($as in $ajaxExtracted.Streams) {
                if ($seenStreamUrls.Add($as.StreamUrl)) {
                    $allStreams.Add($as)
                }
            }
            foreach ($aif in $ajaxExtracted.IframeUrls) {
                if (-not $allIframes.Contains($aif)) {
                    $allIframes.Add($aif)
                }
                if ($current.Depth -lt $MaxIframeDepth -and -not $visitedPages.Contains($aif)) {
                    $queue.Enqueue([PSCustomObject]@{
                        Url     = $aif
                        Referer = $current.Url
                        Depth   = $current.Depth + 1
                    })
                }
            }
            foreach ($sub in $extracted.Subtitles) {
                if (-not $allSubtitles.Contains($sub)) {
                    $allSubtitles.Add($sub)
                }
            }
            foreach ($ifUrl in $extracted.IframeUrls) {
                if (-not $allIframes.Contains($ifUrl)) {
                    $allIframes.Add($ifUrl)
                }
                if ($current.Depth -lt $MaxIframeDepth -and -not $visitedPages.Contains($ifUrl)) {
                    $queue.Enqueue([PSCustomObject]@{
                        Url     = $ifUrl
                        Referer = $current.Url
                        Depth   = $current.Depth + 1
                    })
                }
            }
        }
    }

    if (($UseHeadlessBrowser -or $allStreams.Count -eq 0) -and $null -ne (Resolve-HeadlessBrowserPath)) {
        Write-Host '  -> [Katman 2a] Headless tarayıcı ile dinamik DOM ve oynatıcı kaynakları taranıyor...' -ForegroundColor Cyan
        $domHtml = Invoke-HeadlessDomCapture -TargetUrl $TargetUrl -WaitBudgetMs 6500
        if (-not [string]::IsNullOrWhiteSpace($domHtml)) {
            $domExtracted = Extract-StreamsAndIframesFromContent -Content $domHtml -PageUrl $TargetUrl -SourceLabel 'Katman 2a (Headless Browser DOM)'
            if ([string]::IsNullOrWhiteSpace($bestTitle) -and -not [string]::IsNullOrWhiteSpace($domExtracted.PageTitle)) {
                $bestTitle = $domExtracted.PageTitle
            }
            if ($domExtracted.HasDrmHint) {
                $drmDetected = $true
                $drmNote = $domExtracted.DrmDetails
            }
            foreach ($s in $domExtracted.Streams) {
                if ($seenStreamUrls.Add($s.StreamUrl)) {
                    $allStreams.Add($s)
                }
            }
            foreach ($sub in $domExtracted.Subtitles) {
                if (-not $allSubtitles.Contains($sub)) {
                    $allSubtitles.Add($sub)
                }
            }
            foreach ($ifUrl in $domExtracted.IframeUrls) {
                if (-not $allIframes.Contains($ifUrl)) {
                    $allIframes.Add($ifUrl)
                }
                if (-not $visitedPages.Contains($ifUrl)) {
                    Write-Host "  -> [Katman 2a/2c] Headless DOM içinde bulunan iframe inceleniyor: $ifUrl" -ForegroundColor DarkCyan
                    $ifHtml = Invoke-WebPageFetch -TargetUrl $ifUrl -RefererUrl $TargetUrl -UserAgent $script:DefaultUserAgent
                    if ([string]::IsNullOrWhiteSpace($ifHtml)) {
                        $ifHtml = Invoke-HeadlessDomCapture -TargetUrl $ifUrl -WaitBudgetMs 5500
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ifHtml)) {
                        $ifExt = Extract-StreamsAndIframesFromContent -Content $ifHtml -PageUrl $ifUrl -SourceLabel 'Katman 2a/2c (Headless Iframe)'
                        foreach ($s in $ifExt.Streams) {
                            if ($seenStreamUrls.Add($s.StreamUrl)) {
                                $allStreams.Add($s)
                            }
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        PageTitle   = $bestTitle
        Streams     = $allStreams.ToArray()
        IframeUrls  = $allIframes.ToArray()
        Subtitles   = $allSubtitles.ToArray()
        HasDrmHint  = $drmDetected
        DrmDetails  = $drmNote
    }
}

function Inspect-HlsManifestContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ManifestText,

        [Parameter(Mandatory = $true)]
        [string]$ManifestUrl
    )

    if ([string]::IsNullOrWhiteSpace($ManifestText) -or $ManifestText -notmatch '#EXTM3U') {
        return [PSCustomObject]@{
            IsValidHls = $false
            IsMaster   = $false
            IsAes128   = $false
            AesKeyUri  = ''
            IsDrm      = $false
            DrmMethod  = ''
            Variants   = @()
        }
    }

    $isAes128 = $false
    $aesKeyUri = ''
    if ($ManifestText -match '#EXT-X-KEY:[^\r\n]*METHOD=AES-128(?:[^\r\n]*URI=["''](?<k>[^"'']+)["''])?') {
        $isAes128 = $true
        if ($Matches['k']) {
            $aesKeyUri = ConvertFrom-EscapedMediaUrl -RawCandidate $Matches['k'] -BaseUrl $ManifestUrl
        }
    }

    $isDrm = $false
    $drmMethod = ''
    if ($ManifestText -match '(?i)#EXT-X-KEY:[^\r\n]*METHOD=(?<m>SAMPLE-AES|SAMPLE-AES-CTR|SAMPLE-AES-CENC)') {
        $isDrm = $true
        $drmMethod = $Matches['m']
    } elseif ($ManifestText -match '(?i)(urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed|com\.widevine\.alpha|com\.apple\.fps)') {
        $isDrm = $true
        $drmMethod = $Matches[1]
    }

    $variants = New-Object -TypeName System.Collections.Generic.List[object]
    $lines = $ManifestText -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -match '^#EXT-X-STREAM-INF:(?<attrs>.+)$') {
            $attrs = $Matches['attrs']
            $height = 0
            $bandwidth = 0
            if ($attrs -match 'RESOLUTION=\d+x(?<h>\d+)') {
                $height = [int]$Matches['h']
            }
            if ($attrs -match 'BANDWIDTH=(?<b>\d+)') {
                $bandwidth = [int64]$Matches['b']
            }
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $nextLine = $lines[$j].Trim()
                if ([string]::IsNullOrWhiteSpace($nextLine)) { continue }
                if ($nextLine.StartsWith('#')) { continue }
                $resolvedVarUrl = ConvertFrom-EscapedMediaUrl -RawCandidate $nextLine -BaseUrl $ManifestUrl
                if (-not [string]::IsNullOrWhiteSpace($resolvedVarUrl)) {
                    $variants.Add([PSCustomObject]@{
                        Height    = $height
                        Bandwidth = $bandwidth
                        Url       = $resolvedVarUrl
                    })
                }
                $i = $j
                break
            }
        }
    }

    $sortedVariants = @(
        $variants | Sort-Object -Property @(
            @{ Expression = { [int]$_.Height }; Descending = $true },
            @{ Expression = { [int64]$_.Bandwidth }; Descending = $true }
        )
    )

    return [PSCustomObject]@{
        IsValidHls = $true
        IsMaster   = ($sortedVariants.Count -gt 0)
        IsAes128   = $isAes128
        AesKeyUri  = $aesKeyUri
        IsDrm      = $isDrm
        DrmMethod  = $drmMethod
        Variants   = $sortedVariants
    }
}

function Invoke-Layer3StreamInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$StreamCandidates
    )

    $inspected = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($cand in $StreamCandidates) {
        $hasToken = Test-StreamHasAuthToken -StreamUrl $cand.StreamUrl
        if ($hasToken) {
            Write-Host "  -> [Katman 3a] Token/imza parametresi tespit edildi; indirirken korunacak: $($cand.StreamUrl)" -ForegroundColor Cyan
        }

        $isAes128 = $false
        $isDrm = $false
        $drmMethod = ''
        $variants = @()

        if ($cand.StreamType -eq 'm3u8') {
            $manifestContent = Invoke-WebPageFetch -TargetUrl $cand.StreamUrl -RefererUrl $cand.Referer -UserAgent $script:DefaultUserAgent -TimeoutSeconds 12
            if (-not [string]::IsNullOrWhiteSpace($manifestContent)) {
                $hlsInfo = Inspect-HlsManifestContent -ManifestText $manifestContent -ManifestUrl $cand.StreamUrl
                $isAes128 = $hlsInfo.IsAes128
                $isDrm = $hlsInfo.IsDrm
                $drmMethod = $hlsInfo.DrmMethod
                $variants = $hlsInfo.Variants

                if ($isAes128) {
                    Write-Host '  -> [Katman 3b] AES-128 şifreli HLS akışı tespit edildi — ffmpeg/yt-dlp ile otomatik çözülecek.' -ForegroundColor Yellow
                }
                if ($isDrm) {
                    Write-Host "  -> [Katman 3c] Uyarı: Bu akışta DRM koruması ($drmMethod) tespit edildi." -ForegroundColor Red
                }
            }
        }

        $inspected.Add([PSCustomObject]@{
            StreamUrl      = $cand.StreamUrl
            StreamType     = $cand.StreamType
            Referer        = $cand.Referer
            Origin         = $cand.Origin
            HasToken       = $hasToken
            DiscoveryLayer = $cand.DiscoveryLayer
            IsAes128       = $isAes128
            IsDrm          = $isDrm
            DrmMethod      = $drmMethod
            Variants       = $variants
        })
    }

    return $inspected.ToArray()
}

function Test-MediaFileWithFfprobe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$FilePath
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return [PSCustomObject]@{
            IsValid         = $false
            FilePath        = $FilePath
            SizeBytes       = 0
            SizeText        = '0 MB'
            DurationSeconds = 0
            DurationText    = '00:00'
            Resolution      = 'Bilinmiyor'
            VideoCodec      = ''
            AudioCodec      = ''
            QualitySummary  = 'Doğrulanamadı'
        }
    }

    $item = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -lt 10240) {
        return [PSCustomObject]@{
            IsValid         = $false
            FilePath        = $FilePath
            SizeBytes       = if ($null -ne $item) { $item.Length } else { 0 }
            SizeText        = 'Çok küçük / bozuk'
            DurationSeconds = 0
            DurationText    = '00:00'
            Resolution      = 'Bilinmiyor'
            VideoCodec      = ''
            AudioCodec      = ''
            QualitySummary  = 'Dosya boyutu yetersiz (<10 KB)'
        }
    }

    $sizeBytes = [double]$item.Length
    $sizeText = Format-FileSizeText -Bytes $sizeBytes
    $ffprobeExe = Resolve-ToolExecutable -ToolName 'ffprobe'

    if ([string]::IsNullOrWhiteSpace($ffprobeExe)) {
        return [PSCustomObject]@{
            IsValid         = $true
            FilePath        = $item.FullName
            SizeBytes       = $item.Length
            SizeText        = $sizeText
            DurationSeconds = 0
            DurationText    = 'Bilinmiyor'
            Resolution      = 'Bilinmiyor'
            VideoCodec      = 'bilinmiyor'
            AudioCodec      = 'bilinmiyor'
            QualitySummary  = "Boyut doğrulandı ($sizeText)"
        }
    }

    $probeArgs = @(
        '-v', 'error',
        '-show_entries', 'format=duration,size:stream=codec_type,codec_name,width,height',
        '-of', 'json',
        $item.FullName
    )

    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $probeOut = & $ffprobeExe @probeArgs 2>$null
        $probeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    if ($probeExit -ne 0 -or $null -eq $probeOut) {
        return [PSCustomObject]@{
            IsValid         = $false
            FilePath        = $item.FullName
            SizeBytes       = $item.Length
            SizeText        = $sizeText
            DurationSeconds = 0
            DurationText    = '00:00'
            Resolution      = 'Bilinmiyor'
            VideoCodec      = ''
            AudioCodec      = ''
            QualitySummary  = 'ffprobe doğrulaması başarısız'
        }
    }

    try {
        $probeJson = ($probeOut -join "`n") | ConvertFrom-Json
        $streams = if ($probeJson.PSObject.Properties.Match('streams').Count -gt 0 -and $null -ne $probeJson.streams) { @($probeJson.streams) } else { @() }
        if ($streams.Count -eq 0) {
            return [PSCustomObject]@{
                IsValid         = $false
                FilePath        = $item.FullName
                SizeBytes       = $item.Length
                SizeText        = $sizeText
                DurationSeconds = 0
                DurationText    = '00:00'
                Resolution      = 'Bilinmiyor'
                VideoCodec      = ''
                AudioCodec      = ''
                QualitySummary  = 'Geçerli medya akışı bulunamadı'
            }
        }

        $vStream = $streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
        $aStream = $streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

        $vCodec = if ($null -ne $vStream -and $vStream.PSObject.Properties.Match('codec_name').Count -gt 0) { [string]$vStream.codec_name } else { '' }
        $aCodec = if ($null -ne $aStream -and $aStream.PSObject.Properties.Match('codec_name').Count -gt 0) { [string]$aStream.codec_name } else { '' }
        $resText = if ($null -ne $vStream -and $vStream.PSObject.Properties.Match('width').Count -gt 0 -and $vStream.PSObject.Properties.Match('height').Count -gt 0 -and $vStream.width -and $vStream.height) {
            "$($vStream.width)x$($vStream.height)"
        } elseif ([string]::IsNullOrWhiteSpace($vCodec) -and -not [string]::IsNullOrWhiteSpace($aCodec)) {
            'Yalnızca Ses'
        } else {
            'Bilinmiyor'
        }

        $durSec = 0.0
        if ($probeJson.PSObject.Properties.Match('format').Count -gt 0 -and $null -ne $probeJson.format -and $probeJson.format.PSObject.Properties.Match('duration').Count -gt 0 -and $null -ne $probeJson.format.duration) {
            [void][double]::TryParse([string]$probeJson.format.duration, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$durSec)
        }
        $durObj = [PSCustomObject]@{ duration = $durSec }
        $durText = if ($durSec -gt 0) { Format-DurationText -VideoInfo $durObj } else { 'Bilinmiyor' }

        $codecParts = @($vCodec, $aCodec) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $codecStr = if ($codecParts.Count -gt 0) { $codecParts -join ' / ' } else { 'bilinmiyor' }

        return [PSCustomObject]@{
            IsValid         = $true
            FilePath        = $item.FullName
            SizeBytes       = $item.Length
            SizeText        = $sizeText
            DurationSeconds = $durSec
            DurationText    = $durText
            Resolution      = $resText
            VideoCodec      = $vCodec
            AudioCodec      = $aCodec
            QualitySummary  = "$resText ($codecStr, Süre: $durText)"
        }
    } catch {
        return [PSCustomObject]@{
            IsValid         = ($item.Length -gt 65536)
            FilePath        = $item.FullName
            SizeBytes       = $item.Length
            SizeText        = $sizeText
            DurationSeconds = 0
            DurationText    = 'Bilinmiyor'
            Resolution      = 'Bilinmiyor'
            VideoCodec      = ''
            AudioCodec      = ''
            QualitySummary  = "Boyut: $sizeText"
        }
    }
}

function Format-MediaFetchReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$FilePathAndSize = 'Yok',

        [Parameter(Mandatory = $false)]
        [string]$QualityAndCodec = 'Bilinmiyor',

        [Parameter(Mandatory = $false)]
        [string]$StreamUrl = 'Yok',

        [Parameter(Mandatory = $false)]
        [string]$WorkingLayer = '-',

        [Parameter(Mandatory = $false)]
        [string]$Notes = 'Yok'
    )

    $lines = @(
        "  ✅ Durum: $Status",
        "  📁 Dosya: $FilePathAndSize",
        "  🎬 Kalite: $QualityAndCodec",
        "  🔗 Kullanılan akış: $StreamUrl",
        "  🧩 Çalışan katman: $WorkingLayer",
        "  ⚠️ Notlar: $Notes"
    )
    return ($lines -join "`n")
}

function Write-MediaFetchReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$FilePathAndSize = 'Yok',

        [Parameter(Mandatory = $false)]
        [string]$QualityAndCodec = 'Bilinmiyor',

        [Parameter(Mandatory = $false)]
        [string]$StreamUrl = 'Yok',

        [Parameter(Mandatory = $false)]
        [string]$WorkingLayer = '-',

        [Parameter(Mandatory = $false)]
        [string]$Notes = 'Yok'
    )

    Write-Host ''
    Write-Host '=== MediaFetch Sonuç Raporu ===' -ForegroundColor Cyan
    $reportText = Format-MediaFetchReport `
        -Status $Status `
        -FilePathAndSize $FilePathAndSize `
        -QualityAndCodec $QualityAndCodec `
        -StreamUrl $StreamUrl `
        -WorkingLayer $WorkingLayer `
        -Notes $Notes
    foreach ($line in ($reportText -split "`n")) {
        $color = if ($Status -eq 'Başarılı') { [ConsoleColor]::Green } elseif ($Status -eq 'Kısmi') { [ConsoleColor]::Yellow } else { [ConsoleColor]::Red }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
}

function Invoke-FfmpegStreamDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$StreamUrl,

        [Parameter(Mandatory = $true)]
        [string]$OutputFilePath,

        [Parameter(Mandatory = $false)]
        [string]$RefererUrl = '',

        [Parameter(Mandatory = $false)]
        [string]$OriginUrl = '',

        [Parameter(Mandatory = $false)]
        [string]$UserAgent = $script:DefaultUserAgent,

        [Parameter(Mandatory = $false)]
        [switch]$IsAudioOnly,

        [Parameter(Mandatory = $false)]
        [string]$AudioFormat = 'mp3',

        [Parameter(Mandatory = $false)]
        [switch]$IncludeAllStreams
    )

    $headerLines = New-Object -TypeName System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RefererUrl)) {
        $headerLines.Add("Referer: $($RefererUrl.Trim())")
    }
    if (-not [string]::IsNullOrWhiteSpace($OriginUrl)) {
        $headerLines.Add("Origin: $($OriginUrl.Trim())")
    }
    $headerLines.Add("User-Agent: $UserAgent")
    $headerBlock = ($headerLines -join "`r`n") + "`r`n"

    $ffArgs = New-Object -TypeName System.Collections.Generic.List[string]
    $ffArgs.Add('-y')
    $ffArgs.Add('-nostdin')
    $ffArgs.Add('-loglevel')
    $ffArgs.Add('error')
    $ffArgs.Add('-stats')
    $ffArgs.Add('-tls_verify')
    $ffArgs.Add('0')
    $ffArgs.Add('-reconnect')
    $ffArgs.Add('1')
    $ffArgs.Add('-reconnect_streamed')
    $ffArgs.Add('1')
    $ffArgs.Add('-reconnect_delay_max')
    $ffArgs.Add('5')
    $ffArgs.Add('-user_agent')
    $ffArgs.Add($UserAgent)
    $ffArgs.Add('-headers')
    $ffArgs.Add($headerBlock)

    $isHlsLike = ($StreamUrl -match '(?i)(\.m3u8|(manifest|playlist|master|sublist)[^/]*\.(txt|m3u8))')
    if ($isHlsLike) {
        $ffArgs.Add('-f')
        $ffArgs.Add('hls')
        $ffArgs.Add('-http_persistent')
        $ffArgs.Add('0')
    }
    $ffArgs.Add('-allowed_extensions')
    $ffArgs.Add('ALL')

    $prevEapProbe = $ErrorActionPreference
    $hlsHelpText = ''
    try {
        $ErrorActionPreference = 'Continue'
        $hlsHelpLines = & $FfmpegPath -v quiet -h demuxer=hls 2>$null
        if ($null -ne $hlsHelpLines) {
            $hlsHelpText = ($hlsHelpLines -join "`n")
        }
    } finally {
        $ErrorActionPreference = $prevEapProbe
    }

    if ($hlsHelpText -match 'allowed_segment_extensions') {
        $ffArgs.Add('-allowed_segment_extensions')
        $ffArgs.Add('ALL')
    }
    if ($hlsHelpText -match 'extension_picky') {
        $ffArgs.Add('-extension_picky')
        $ffArgs.Add('0')
    }

    $ffArgs.Add('-protocol_whitelist')
    $ffArgs.Add('file,http,https,tcp,tls,crypto,data')
    $ffArgs.Add('-i')
    $ffArgs.Add($StreamUrl)

    if ($IsAudioOnly) {
        $ffArgs.Add('-vn')
        switch ($AudioFormat) {
            'mp3'  { $ffArgs.Add('-c:a'); $ffArgs.Add('libmp3lame'); $ffArgs.Add('-q:a'); $ffArgs.Add('2') }
            'm4a'  { $ffArgs.Add('-c:a'); $ffArgs.Add('aac'); $ffArgs.Add('-b:a'); $ffArgs.Add('192k') }
            'opus' { $ffArgs.Add('-c:a'); $ffArgs.Add('libopus'); $ffArgs.Add('-b:a'); $ffArgs.Add('160k') }
            'wav'  { $ffArgs.Add('-c:a'); $ffArgs.Add('pcm_s16le') }
            default { $ffArgs.Add('-c:a'); $ffArgs.Add('copy') }
        }
    } else {
        if ($IncludeAllStreams) {
            $ffArgs.Add('-map')
            $ffArgs.Add('0:v:0?')
            $ffArgs.Add('-map')
            $ffArgs.Add('0:a?')
            $ffArgs.Add('-map')
            $ffArgs.Add('0:s?')
        } else {
            $ffArgs.Add('-map')
            $ffArgs.Add('0:v:0?')
            $ffArgs.Add('-map')
            $ffArgs.Add('0:a:0?')
        }
        $ffArgs.Add('-c')
        $ffArgs.Add('copy')
        if ($OutputFilePath -match '(?i)\.mp4$') {
            $ffArgs.Add('-bsf:a')
            $ffArgs.Add('aac_adtstoasc')
        }
    }

    $ffArgs.Add($OutputFilePath)

    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $ffArgsArr = $ffArgs.ToArray()
        & $FfmpegPath @ffArgsArr | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Invoke-Layer4DownloadAndVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$InspectedStreams,

        [Parameter(Mandatory = $true)]
        $Deps,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $false)]
        [string]$PageTitle = '',

        [Parameter(Mandatory = $false)]
        [string]$SelectedQuality = 'best',

        [Parameter(Mandatory = $false)]
        [string]$SelectedFormat = 'mp4',

        [Parameter(Mandatory = $false)]
        [switch]$IsAudioOnly,

        [Parameter(Mandatory = $false)]
        [string]$SubtitleLangs = '',

        [Parameter(Mandatory = $false)]
        [string]$BrowserCookies = ''
    )

    $safeTitle = ConvertTo-SafeFileName -RawTitle $PageTitle
    $ext = if ($IsAudioOnly) {
        if ([string]::IsNullOrWhiteSpace($SelectedFormat)) { 'mp3' } else { $SelectedFormat }
    } else {
        if ([string]::IsNullOrWhiteSpace($SelectedFormat)) { 'mp4' } else { $SelectedFormat }
    }
    $ffmpegDir = Split-Path -Path $Deps.FfmpegPath -Parent
    $nm3u8Exe = Resolve-ToolExecutable -ToolName 'N_m3u8DL-RE'
    $streamlinkExe = Resolve-ToolExecutable -ToolName 'streamlink'

    foreach ($cand in $InspectedStreams) {
        if ($cand.IsDrm) {
            continue
        }

        $urlsToTry = New-Object -TypeName System.Collections.Generic.List[string]
        $urlsToTry.Add($cand.StreamUrl)

        if ($null -ne $cand.Variants -and $cand.Variants.Count -gt 0) {
            $reqH = 0
            if (-not [string]::IsNullOrWhiteSpace($SelectedQuality) -and $SelectedQuality -ne 'best') {
                [void][int]::TryParse(($SelectedQuality -replace 'p$', ''), [ref]$reqH)
            }
            $orderedVars = if ($reqH -gt 0) {
                @(
                    $cand.Variants | Sort-Object -Property @(
                        @{ Expression = { if ($_.Height -le $reqH -and $_.Height -gt 0) { 1 } else { 0 } }; Descending = $true },
                        @{ Expression = { [Math]::Abs($_.Height - $reqH) }; Ascending = $true }
                    )
                )
            } else {
                @($cand.Variants)
            }
            foreach ($v in $orderedVars) {
                if (-not $urlsToTry.Contains($v.Url)) {
                    $urlsToTry.Add($v.Url)
                }
            }
        }

        foreach ($tryUrl in $urlsToTry) {
            $outFile = Join-Path -Path $OutputDir -ChildPath "$safeTitle.$ext"
            if (Test-Path -LiteralPath $outFile) {
                $outFile = Join-Path -Path $OutputDir -ChildPath "${safeTitle}_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).$ext"
            }

            $isDisguisedTxtHls = ($tryUrl -match '(?i)\.(txt)(\?|$)')

            # 4a/4b/4c: Doğrudan ffmpeg (çoklu ses/altyazı map ile, başarısızsa standart copy ile)
            Write-Host "  -> [Katman 4a/4c] Doğrudan ffmpeg (-c copy -bsf:a aac_adtstoasc) ile indiriliyor: $tryUrl" -ForegroundColor Cyan
            $ffOk = Invoke-FfmpegStreamDownload `
                -FfmpegPath $Deps.FfmpegPath `
                -StreamUrl $tryUrl `
                -OutputFilePath $outFile `
                -RefererUrl $cand.Referer `
                -OriginUrl $cand.Origin `
                -UserAgent $script:DefaultUserAgent `
                -IsAudioOnly:$IsAudioOnly `
                -AudioFormat $ext `
                -IncludeAllStreams

            if (-not $ffOk -or -not (Test-MediaFileWithFfprobe -FilePath $outFile).IsValid) {
                if (Test-Path -LiteralPath $outFile) {
                    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
                }
                Write-Host '  -> [Katman 4a] Çoklu akış eşlemesi uyumsuz, temel video+ses akışı ve alternatif User-Agent ile tekrar deneniyor...' -ForegroundColor Yellow
                $ffOk = Invoke-FfmpegStreamDownload `
                    -FfmpegPath $Deps.FfmpegPath `
                    -StreamUrl $tryUrl `
                    -OutputFilePath $outFile `
                    -RefererUrl $cand.Referer `
                    -OriginUrl $cand.Origin `
                    -UserAgent $script:AltUserAgent `
                    -IsAudioOnly:$IsAudioOnly `
                    -AudioFormat $ext
            }

            if ($ffOk -and (Test-Path -LiteralPath $outFile)) {
                $probe = Test-MediaFileWithFfprobe -FilePath $outFile
                if ($probe.IsValid) {
                    return [PSCustomObject]@{
                        Success      = $true
                        FilePath     = $probe.FilePath
                        SizeText     = $probe.SizeText
                        QualityText  = $probe.QualitySummary
                        StreamUrl    = $tryUrl
                        WorkingLayer = "Katman 4a ($($cand.DiscoveryLayer) + doğrudan ffmpeg)"
                        Notes        = if ($cand.IsAes128) { 'AES-128 HLS doğrudan ffmpeg ile çözüldü ve doğrulandı.' } elseif ($cand.HasToken) { 'Token ve Referer başlıkları korunarak doğrudan ffmpeg ile indirildi.' } else { 'Doğrudan ffmpeg ile indirildi ve ffprobe ile doğrulandı.' }
                    }
                }
                Write-Host '  -> [Katman 4e] Dosya ffprobe kontrolünden geçemedi, alternatif araç (Katman 4d) deneniyor...' -ForegroundColor Yellow
                Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            }

            if (-not $isDisguisedTxtHls) {
                # 4d-1: yt-dlp --hls-prefer-ffmpeg + Referer + User-Agent
                Write-Host "  -> [Katman 4d] yt-dlp (--hls-prefer-ffmpeg + Referer) ile indiriliyor: $tryUrl" -ForegroundColor Cyan
                $printFile = Join-Path -Path $env:TEMP -ChildPath "videodl_l4_path_$([guid]::NewGuid().ToString('N')).txt"
                $customTemplate = Join-Path -Path $OutputDir -ChildPath "$safeTitle [%(id)s].%(ext)s"
                $ytArgs = Get-YtDlpArgumentList `
                    -TargetUrl $tryUrl `
                    -SelectedQuality $SelectedQuality `
                    -SelectedFormat $ext `
                    -IsAudioOnly:$IsAudioOnly `
                    -OutputDirectory $OutputDir `
                    -SubtitleLangs $SubtitleLangs `
                    -BrowserCookies $BrowserCookies `
                    -FfmpegPath $ffmpegDir `
                    -PrintFilePath $printFile `
                    -NoCheckCertificate `
                    -HlsPreferFfmpeg `
                    -RefererUrl $cand.Referer `
                    -OriginUrl $cand.Origin `
                    -UserAgent $script:DefaultUserAgent `
                    -CustomOutputTemplate $customTemplate

                $prevEap = $ErrorActionPreference
                $ytExit = 1
                try {
                    $ErrorActionPreference = 'Continue'
                    & $Deps.YtDlpPath @ytArgs 2>$null | Out-Host
                    $ytExit = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $prevEap
                }

                $ytProducedFile = $null
                if (Test-Path -LiteralPath $printFile) {
                    $pLines = @(Get-Content -LiteralPath $printFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($pLines.Count -gt 0) {
                        $ytProducedFile = $pLines[-1].Trim()
                    }
                    Remove-Item -LiteralPath $printFile -Force -ErrorAction SilentlyContinue
                }
                if ($ytExit -eq 0 -and -not [string]::IsNullOrWhiteSpace($ytProducedFile) -and (Test-Path -LiteralPath $ytProducedFile)) {
                    $probe = Test-MediaFileWithFfprobe -FilePath $ytProducedFile
                    if ($probe.IsValid) {
                        return [PSCustomObject]@{
                            Success      = $true
                            FilePath     = $probe.FilePath
                            SizeText     = $probe.SizeText
                            QualityText  = $probe.QualitySummary
                            StreamUrl    = $tryUrl
                            WorkingLayer = "Katman 4d ($($cand.DiscoveryLayer) + yt-dlp --hls-prefer-ffmpeg)"
                            Notes        = if ($cand.IsAes128) { 'AES-128 HLS otomatik çözüldü; ffprobe ile doğrulandı.' } elseif ($cand.HasToken) { 'Token ve Referer korunarak indirildi; ffprobe ile doğrulandı.' } else { 'ffprobe ile doğrulandı.' }
                        }
                    }
                    Write-Host '  -> [Katman 4e] İndirilen dosya doğrulamadan geçemedi, sıradaki araç/varyant deneniyor...' -ForegroundColor Yellow
                    Remove-Item -LiteralPath $ytProducedFile -Force -ErrorAction SilentlyContinue
                }
            }

            # 4d-2: N_m3u8DL-RE (varsa)
            if (-not [string]::IsNullOrWhiteSpace($nm3u8Exe) -and $cand.StreamType -eq 'm3u8') {
                Write-Host '  -> [Katman 4d] N_m3u8DL-RE ile deneniyor...' -ForegroundColor Cyan
                $nmArgs = @(
                    $tryUrl,
                    '--save-dir', $OutputDir,
                    '--save-name', $safeTitle,
                    '--header', "Referer: $($cand.Referer)",
                    '--header', "User-Agent: $script:DefaultUserAgent",
                    '--auto-select',
                    '--no-log'
                )
                $prevEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $nm3u8Exe @nmArgs 2>$null | Out-Host
                } finally {
                    $ErrorActionPreference = $prevEap
                }
                $nmFile = Get-ChildItem -LiteralPath $OutputDir -Filter "$safeTitle*" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($null -ne $nmFile) {
                    $probe = Test-MediaFileWithFfprobe -FilePath $nmFile.FullName
                    if ($probe.IsValid) {
                        return [PSCustomObject]@{
                            Success      = $true
                            FilePath     = $probe.FilePath
                            SizeText     = $probe.SizeText
                            QualityText  = $probe.QualitySummary
                            StreamUrl    = $tryUrl
                            WorkingLayer = 'Katman 4d (N_m3u8DL-RE)'
                            Notes        = 'N_m3u8DL-RE ile indirildi ve ffprobe ile doğrulandı.'
                        }
                    }
                }
            }

            # 4d-3: streamlink (varsa)
            if (-not [string]::IsNullOrWhiteSpace($streamlinkExe) -and $cand.StreamType -eq 'm3u8') {
                Write-Host '  -> [Katman 4d] streamlink ile deneniyor...' -ForegroundColor Cyan
                $slArgs = @(
                    '--http-no-ssl-verify',
                    '--http-header', "Referer=$($cand.Referer)",
                    '--http-header', "User-Agent=$script:DefaultUserAgent",
                    '-o', $outFile,
                    $tryUrl,
                    'best'
                )
                $prevEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $streamlinkExe @slArgs 2>$null | Out-Host
                } finally {
                    $ErrorActionPreference = $prevEap
                }
                if (Test-Path -LiteralPath $outFile) {
                    $probe = Test-MediaFileWithFfprobe -FilePath $outFile
                    if ($probe.IsValid) {
                        return [PSCustomObject]@{
                            Success      = $true
                            FilePath     = $probe.FilePath
                            SizeText     = $probe.SizeText
                            QualityText  = $probe.QualitySummary
                            StreamUrl    = $tryUrl
                            WorkingLayer = 'Katman 4d (streamlink)'
                            Notes        = 'streamlink ile indirildi ve ffprobe ile doğrulandı.'
                        }
                    }
                    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    return [PSCustomObject]@{
        Success      = $false
        FilePath     = ''
        SizeText     = '0 MB'
        QualityText  = 'Yok'
        StreamUrl    = if ($InspectedStreams.Count -gt 0) { $InspectedStreams[0].StreamUrl } else { '' }
        WorkingLayer = '-'
        Notes        = 'Aday akışlar indirilemedi.'
    }
}

function Get-VideoMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $false)]
        [string]$BrowserCookies,

        [Parameter(Mandatory = $false)]
        [switch]$NoCheckCertificate,

        [Parameter(Mandatory = $false)]
        [string]$RefererUrl,

        [Parameter(Mandatory = $false)]
        [string]$OriginUrl,

        [Parameter(Mandatory = $false)]
        [string]$UserAgent,

        [Parameter(Mandatory = $false)]
        [switch]$SuppressErrorOutput
    )

    $metaArgs = New-Object -TypeName System.Collections.Generic.List[string]
    $metaArgs.Add('-J')
    $metaArgs.Add('--no-playlist')
    $metaArgs.Add('--no-warnings')
    $metaArgs.Add('--no-update')
    if ($NoCheckCertificate) {
        $metaArgs.Add('--no-check-certificate')
    }
    if (-not [string]::IsNullOrWhiteSpace($RefererUrl)) {
        $metaArgs.Add('--referer')
        $metaArgs.Add($RefererUrl.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($UserAgent)) {
        $metaArgs.Add('--user-agent')
        $metaArgs.Add($UserAgent.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($OriginUrl)) {
        $metaArgs.Add('--add-header')
        $metaArgs.Add("Origin:$($OriginUrl.Trim())")
    }
    if (-not [string]::IsNullOrWhiteSpace($BrowserCookies)) {
        $metaArgs.Add('--cookies-from-browser')
        $metaArgs.Add($BrowserCookies.Trim())
    }
    $metaArgs.Add('--')
    $metaArgs.Add($TargetUrl)

    $errFile = Join-Path -Path $env:TEMP -ChildPath "videodl_meta_err_$([guid]::NewGuid().ToString('N')).log"
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $metaArgsArray = $metaArgs.ToArray()
        $jsonLines = & $YtDlpPath @metaArgsArray 2>$errFile
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    $rawErr = ''
    if (Test-Path -LiteralPath $errFile) {
        $rawErr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $script:LastYtDlpRawError = $rawErr

    if ($exitCode -ne 0 -or $null -eq $jsonLines) {
        if (-not [string]::IsNullOrWhiteSpace($rawErr)) {
            Write-Verbose "yt-dlp ham hata çıktısı:`n$rawErr"
        }
        if (-not $SuppressErrorOutput) {
            $friendlyMsg = Convert-YtDlpErrorToTurkish -RawError $rawErr
            Write-Host $friendlyMsg -ForegroundColor Red
        }
        return $null
    }

    $jsonText = ($jsonLines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        if (-not $SuppressErrorOutput) {
            Write-Host 'Hata: Video bilgileri alınamadı (boş yanıt).' -ForegroundColor Red
        }
        return $null
    }

    try {
        return ($jsonText | ConvertFrom-Json)
    } catch {
        Write-Verbose "JSON ayrıştırma hatası: $($_.Exception.Message)"
        if (-not $SuppressErrorOutput) {
            Write-Host 'Hata: Video meta verisi okunamadı.' -ForegroundColor Red
        }
        return $null
    }
}

function Invoke-LayeredFallbackPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $true)]
        $Deps,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $false)]
        [string]$SelectedQuality = 'best',

        [Parameter(Mandatory = $false)]
        [string]$SelectedFormat = 'mp4',

        [Parameter(Mandatory = $false)]
        [switch]$IsAudioOnly,

        [Parameter(Mandatory = $false)]
        [string]$SubtitleLangs = '',

        [Parameter(Mandatory = $false)]
        [string]$BrowserCookies = '',

        [Parameter(Mandatory = $false)]
        [switch]$IsInteractive
    )

    Write-Host ''
    Write-Host '[Katman 1] Standart yt-dlp çıkarımı başarısız oldu — Katman 2 (Sayfa Kaynağı, Iframe, Packed JS ve Base64 Analizi) başlatılıyor...' -ForegroundColor Yellow

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # KATMAN 2: Sayfa kaynağı + iç içe iframe + packed JS + Base64 + Headless Browser
    $l2Result = Invoke-Layer2PageAnalysis -TargetUrl $TargetUrl -MaxIframeDepth 3
    $pageTitle = if (-not [string]::IsNullOrWhiteSpace($l2Result.PageTitle)) { $l2Result.PageTitle } else { 'video' }

    # Eğer doğrudan akış bulunamadıysa ama iframe'ler bulunduysa önce iframe adreslerini yt-dlp (Katman 2c -> 1b) ile dene
    if ($l2Result.Streams.Count -eq 0 -and $l2Result.IframeUrls.Count -gt 0) {
        Write-Host "[Katman 2c] Sayfada $($l2Result.IframeUrls.Count) adet gömülü iframe oynatıcı bulundu, analiz ediliyor..." -ForegroundColor Cyan
        $ffmpegDir = Split-Path -Path $Deps.FfmpegPath -Parent
        foreach ($ifUrl in $l2Result.IframeUrls) {
            Write-Host "  -> [Katman 2c] Gömülü oynatıcı yt-dlp + Referer ile deneniyor: $ifUrl" -ForegroundColor Cyan
            $printFile = Join-Path -Path $env:TEMP -ChildPath "videodl_if_path_$([guid]::NewGuid().ToString('N')).txt"
            $ext = if ($IsAudioOnly) { if ($SelectedFormat) { $SelectedFormat } else { 'mp3' } } else { if ($SelectedFormat) { $SelectedFormat } else { 'mp4' } }
            $ytIfArgs = Get-YtDlpArgumentList `
                -TargetUrl $ifUrl `
                -SelectedQuality $(if ($SelectedQuality) { $SelectedQuality } else { 'best' }) `
                -SelectedFormat $ext `
                -IsAudioOnly:$IsAudioOnly `
                -OutputDirectory $OutputDir `
                -SubtitleLangs $SubtitleLangs `
                -BrowserCookies $BrowserCookies `
                -FfmpegPath $ffmpegDir `
                -PrintFilePath $printFile `
                -NoCheckCertificate `
                -HlsPreferFfmpeg `
                -RefererUrl $TargetUrl `
                -OriginUrl (Get-UrlOrigin -InputUrl $TargetUrl) `
                -UserAgent $script:DefaultUserAgent

            $prevEap = $ErrorActionPreference
            $ifExit = 1
            try {
                $ErrorActionPreference = 'Continue'
                & $Deps.YtDlpPath @ytIfArgs 2>$null
                $ifExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }

            if ($ifExit -eq 0 -and (Test-Path -LiteralPath $printFile)) {
                $pLines = @(Get-Content -LiteralPath $printFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                Remove-Item -LiteralPath $printFile -Force -ErrorAction SilentlyContinue
                if ($pLines.Count -gt 0 -and (Test-Path -LiteralPath $pLines[-1].Trim())) {
                    $probe = Test-MediaFileWithFfprobe -FilePath $pLines[-1].Trim()
                    if ($probe.IsValid) {
                        Write-MediaFetchReport `
                            -Status 'Başarılı' `
                            -FilePathAndSize "$($probe.FilePath) ($($probe.SizeText))" `
                            -QualityAndCodec $probe.QualitySummary `
                            -StreamUrl $ifUrl `
                            -WorkingLayer 'Katman 2c (Iframe Çıkarımı + yt-dlp)' `
                            -Notes 'Gömülü iframe oynatıcı Referer başlığıyla çözüldü ve ffprobe ile doğrulandı.'
                        return $true
                    }
                }
            }
            if (Test-Path -LiteralPath $printFile) {
                Remove-Item -LiteralPath $printFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # KATMAN 5a Erken Destek: Eğer hala akış yoksa Headless Browser derin tarama çalıştır
    if ($l2Result.Streams.Count -eq 0) {
        Write-Host '[Katman 2 -> Katman 5a] Statik kaynakta doğrudan akış bulunamadı; Headless tarayıcı derin DOM analizi çalıştırılıyor...' -ForegroundColor Yellow
        $l2Result = Invoke-Layer2PageAnalysis -TargetUrl $TargetUrl -MaxIframeDepth 3 -UseHeadlessBrowser
        if (-not [string]::IsNullOrWhiteSpace($l2Result.PageTitle)) {
            $pageTitle = $l2Result.PageTitle
        }
    }

    if ($l2Result.Streams.Count -eq 0) {
        if ($l2Result.HasDrmHint) {
            $altInfo = if ($l2Result.IframeUrls.Count -gt 0) { "Alternatif iframe'ler: $($l2Result.IframeUrls -join ', ')" } else { 'Alternatif sunucu bulunamadı.' }
            Write-Host '⚠️ Bu içerik DRM (Widevine/FairPlay) korumalı, yasal olarak indirilemez.' -ForegroundColor Red
            Write-MediaFetchReport `
                -Status 'Kısmi (DRM Korumalı)' `
                -FilePathAndSize 'İndirilmedi (DRM Koruması)' `
                -QualityAndCodec 'DRM Şifreli Akış' `
                -StreamUrl $TargetUrl `
                -WorkingLayer 'Katman 3c (DRM Tespiti)' `
                -Notes "Bu içerik DRM korumalı ($($l2Result.DrmDetails)), yasal olarak indirilemez. $altInfo"
            return $false
        }

        Write-MediaFetchReport `
            -Status 'Başarısız' `
            -FilePathAndSize 'Yok' `
            -QualityAndCodec 'Yok' `
            -StreamUrl $TargetUrl `
            -WorkingLayer 'Katman 1-5 denendi' `
            -Notes $(if ($l2Result.IframeUrls.Count -gt 0) { "Oturum/çerez gerekiyor olabilir (-Cookies <tarayici> deneyin). Bulunan iframe'ler: $($l2Result.IframeUrls -join ', ')" } else { 'Sayfa oturum açma veya etkileşimli doğrulama gerektiriyor olabilir (-Cookies firefox/chrome/edge deneyin).' })
        return $false
    }

    Write-Host "[Katman 2] Toplam $($l2Result.Streams.Count) adet medya akış adayı yakalandı. Katman 3 (Token, AES-128 ve DRM Analizi) başlatılıyor..." -ForegroundColor Cyan

    # KATMAN 3: Token, AES-128 ve DRM kontrolü
    $inspectedStreams = @(Invoke-Layer3StreamInspection -StreamCandidates $l2Result.Streams)
    $nonDrmStreams = @($inspectedStreams | Where-Object { -not $_.IsDrm })

    if ($nonDrmStreams.Count -eq 0) {
        $firstDrm = $inspectedStreams[0]
        $subNote = if ($l2Result.Subtitles.Count -gt 0) { "Altyazılar: $($l2Result.Subtitles -join ', ')" } else { 'Ek altyazı bulunamadı.' }
        Write-Host '⚠️ Bu içerik DRM korumalı, yasal olarak indirilemez.' -ForegroundColor Red
        Write-MediaFetchReport `
            -Status 'Kısmi (DRM Korumalı)' `
            -FilePathAndSize 'İndirilmedi (DRM Koruması)' `
            -QualityAndCodec "DRM ($($firstDrm.DrmMethod))" `
            -StreamUrl $firstDrm.StreamUrl `
            -WorkingLayer 'Katman 3c (DRM Tespiti)' `
            -Notes "Bu içerik DRM korumalı, yasal olarak indirilemez. $subNote"
        return $false
    }

    # Etkileşimli modda kullanıcı henüz kalite/format seçmediyse hızlıca sor veya varsayılan en iyiyi kullan
    $effQuality = if ([string]::IsNullOrWhiteSpace($SelectedQuality)) { 'best' } else { $SelectedQuality }
    $effFormat = if ([string]::IsNullOrWhiteSpace($SelectedFormat)) {
        if ($IsAudioOnly) { 'mp3' } else { 'mp4' }
    } else {
        $SelectedFormat
    }

    # KATMAN 4: İndirme, birleştirme ve ffprobe doğrulama
    Write-Host '[Katman 4] Akış indirme, birleştirme ve ffprobe doğrulama katmanı başlatılıyor...' -ForegroundColor Cyan
    $l4Result = Invoke-Layer4DownloadAndVerify `
        -InspectedStreams $nonDrmStreams `
        -Deps $Deps `
        -OutputDir $OutputDir `
        -PageTitle $pageTitle `
        -SelectedQuality $effQuality `
        -SelectedFormat $effFormat `
        -IsAudioOnly:$IsAudioOnly `
        -SubtitleLangs $SubtitleLangs `
        -BrowserCookies $BrowserCookies

    # Harici altyazı varsa (.vtt/.srt) yanına kaydet
    if ($l4Result.Success -and $l2Result.Subtitles.Count -gt 0) {
        $baseOutNoExt = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($l4Result.FilePath), [System.IO.Path]::GetFileNameWithoutExtension($l4Result.FilePath))
        for ($si = 0; $si -lt $l2Result.Subtitles.Count; $si++) {
            $subUrl = $l2Result.Subtitles[$si]
            $subExt = if ($subUrl -match '(?i)\.srt(\?|$)') { 'srt' } else { 'vtt' }
            $subFile = "${baseOutNoExt}.sub$($si + 1).$subExt"
            $subText = Invoke-WebPageFetch -TargetUrl $subUrl -RefererUrl $TargetUrl
            if (-not [string]::IsNullOrWhiteSpace($subText)) {
                [System.IO.File]::WriteAllText($subFile, $subText, [System.Text.Encoding]::UTF8)
            }
        }
    }

    if ($l4Result.Success) {
        Write-MediaFetchReport `
            -Status 'Başarılı' `
            -FilePathAndSize "$($l4Result.FilePath) ($($l4Result.SizeText))" `
            -QualityAndCodec $l4Result.QualityText `
            -StreamUrl $l4Result.StreamUrl `
            -WorkingLayer $l4Result.WorkingLayer `
            -Notes $l4Result.Notes

        if ($IsInteractive) {
            $openAns = Read-Host -Prompt 'Open folder? (y/N)'
            if (-not [string]::IsNullOrWhiteSpace($openAns) -and $openAns.Trim() -match '^(y|yes|e|evet)$') {
                if (Test-Path -LiteralPath $l4Result.FilePath -PathType Leaf) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList @("/select,`"$($l4Result.FilePath)`"")
                } else {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList @("`"$OutputDir`"")
                }
            }
        }
        return $true
    }

    Write-MediaFetchReport `
        -Status 'Kısmi (Akış Bulundu, İndirilemedi)' `
        -FilePathAndSize 'Yok' `
        -QualityAndCodec 'Bilinmiyor' `
        -StreamUrl $l4Result.StreamUrl `
        -WorkingLayer 'Katman 2-4 (Akış Yakalandı)' `
        -Notes 'Akış adresi yakalandı ancak sunucu oturum çerezi bekliyor olabilir (-Cookies <tarayici> parametresiyle tekrar deneyin).'
    return $false
}

function Invoke-VideoDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ResolvedParams
    )

    $isInteractive = [bool]$ResolvedParams.IsInteractive
    $targetUrl = $ResolvedParams.Url

    if ($isInteractive -and [string]::IsNullOrWhiteSpace($targetUrl)) {
        $targetUrl = Read-Host -Prompt 'URL'
        if (-not (Test-VideoUrl -InputUrl $targetUrl)) {
            Write-Host "Hata: Geçersiz URL adresi: '$targetUrl'. Lütfen http:// veya https:// ile başlayan geçerli bir bağlantı girin." -ForegroundColor Red
            $script:ProcessExitCode = 2
            return
        }
        $targetUrl = $targetUrl.Trim()
    }

    Write-Host 'Bilgi: İndirdiğin içeriğin kullanım haklarına sahip olduğundan emin ol.' -ForegroundColor DarkGray

    $deps = Assert-Dependencies -IsInteractive:$isInteractive
    if ($null -eq $deps) {
        $script:ProcessExitCode = 1
        return
    }

    $selectedQuality = $ResolvedParams.Quality
    $selectedFormat = $ResolvedParams.Format
    $isAudioOnly = [bool]$ResolvedParams.IsAudioOnly
    $outputDir = $ResolvedParams.Output
    $originUrl = Get-UrlOrigin -InputUrl $targetUrl
    $usedLayer1b = $false

    if ($isInteractive) {
        Write-Host '[Katman 1a] Video bilgileri alınıyor (yt-dlp)...' -ForegroundColor Cyan
        $videoInfo = Get-VideoMetadata -YtDlpPath $deps.YtDlpPath -TargetUrl $targetUrl -BrowserCookies $ResolvedParams.Cookies -SuppressErrorOutput
        if ($null -eq $videoInfo) {
            Write-Host '[Katman 1a] Başarısız — [Katman 1b] --no-check-certificate, Referer ve User-Agent başlıklarıyla tekrar deneniyor...' -ForegroundColor Yellow
            $videoInfo = Get-VideoMetadata `
                -YtDlpPath $deps.YtDlpPath `
                -TargetUrl $targetUrl `
                -BrowserCookies $ResolvedParams.Cookies `
                -NoCheckCertificate `
                -RefererUrl $targetUrl `
                -OriginUrl $originUrl `
                -UserAgent $script:DefaultUserAgent `
                -SuppressErrorOutput
            if ($null -ne $videoInfo) {
                $usedLayer1b = $true
            }
        }

        if ($null -eq $videoInfo) {
            $fallbackOk = Invoke-LayeredFallbackPipeline `
                -TargetUrl $targetUrl `
                -Deps $deps `
                -OutputDir $outputDir `
                -SelectedQuality $selectedQuality `
                -SelectedFormat $selectedFormat `
                -IsAudioOnly:$isAudioOnly `
                -SubtitleLangs $ResolvedParams.Subs `
                -BrowserCookies $ResolvedParams.Cookies `
                -IsInteractive:$isInteractive
            $script:ProcessExitCode = if ($fallbackOk) { 0 } else { 1 }
            return
        }

        $titleText = if ($videoInfo.PSObject.Properties.Match('title').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$videoInfo.title)) { [string]$videoInfo.title } else { 'Bilinmeyen Başlık' }
        $durationText = Format-DurationText -VideoInfo $videoInfo

        Write-Host ''
        Write-Host "Başlık : $titleText" -ForegroundColor White
        Write-Host "Süre   : $durationText" -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Mevcut Çözünürlükler:' -ForegroundColor Cyan

        $resolutions = @(Get-AvailableResolutions -VideoInfo $videoInfo)
        for ($i = 0; $i -lt $resolutions.Count; $i++) {
            $res = $resolutions[$i]
            $idx = $i + 1
            if ($res.IsAudioOnly) {
                Write-Host ("  [{0}] {1} ({2})" -f $idx, $res.Label, $res.SizeText)
            } else {
                Write-Host ("  [{0}] {1,-6} ({2} fps, {3})" -f $idx, $res.Label, $res.Fps, $res.SizeText)
            }
        }

        $choiceInput = Read-Host -Prompt "Seçiminiz (1-$($resolutions.Count), varsayılan: 1)"
        $choiceIdx = 1
        if (-not [string]::IsNullOrWhiteSpace($choiceInput)) {
            $parsedIdx = 0
            if (-not [int]::TryParse($choiceInput.Trim(), [ref]$parsedIdx) -or $parsedIdx -lt 1 -or $parsedIdx -gt $resolutions.Count) {
                Write-Host "Hata: Geçersiz seçim '$choiceInput'." -ForegroundColor Red
                $script:ProcessExitCode = 2
                return
            }
            $choiceIdx = $parsedIdx
        }

        $chosenRes = $resolutions[$choiceIdx - 1]
        if ($chosenRes.IsAudioOnly) {
            $isAudioOnly = $true
            $fmtPrompt = Read-Host -Prompt 'Çıktı formatı (mp3 [varsayılan], m4a, opus, wav)'
            if ([string]::IsNullOrWhiteSpace($fmtPrompt)) {
                $selectedFormat = 'mp3'
            } else {
                $cleanFmt = $fmtPrompt.Trim().ToLowerInvariant()
                if ($cleanFmt -notin $script:AudioFormats) {
                    Write-Host "Hata: Geçersiz ses formatı '$fmtPrompt'. Geçerli formatlar: $($script:AudioFormats -join ', ')." -ForegroundColor Red
                    $script:ProcessExitCode = 2
                    return
                }
                $selectedFormat = $cleanFmt
            }
        } else {
            $selectedQuality = [string]$chosenRes.Quality
            $fmtPrompt = Read-Host -Prompt 'Çıktı formatı (mp4 [varsayılan], mkv, webm, mp3, m4a, opus, wav)'
            if ([string]::IsNullOrWhiteSpace($fmtPrompt)) {
                $selectedFormat = 'mp4'
            } else {
                $cleanFmt = $fmtPrompt.Trim().ToLowerInvariant()
                if ($cleanFmt -notin $script:AllowedFormats) {
                    Write-Host "Hata: Geçersiz format '$fmtPrompt'. Geçerli formatlar: $($script:AllowedFormats -join ', ')." -ForegroundColor Red
                    $script:ProcessExitCode = 2
                    return
                }
                $selectedFormat = $cleanFmt
                if ($selectedFormat -in $script:AudioFormats) {
                    $isAudioOnly = $true
                }
            }
        }
    } else {
        if ((-not $isAudioOnly) -and (-not $ResolvedParams.Playlist) -and ($selectedQuality -ne 'best')) {
            $videoInfo = Get-VideoMetadata -YtDlpPath $deps.YtDlpPath -TargetUrl $targetUrl -BrowserCookies $ResolvedParams.Cookies -SuppressErrorOutput
            if ($null -eq $videoInfo) {
                Write-Host '[Katman 1a] Başarısız — [Katman 1b] --no-check-certificate ve Referer ile tekrar deneniyor...' -ForegroundColor Yellow
                $videoInfo = Get-VideoMetadata `
                    -YtDlpPath $deps.YtDlpPath `
                    -TargetUrl $targetUrl `
                    -BrowserCookies $ResolvedParams.Cookies `
                    -NoCheckCertificate `
                    -RefererUrl $targetUrl `
                    -OriginUrl $originUrl `
                    -UserAgent $script:DefaultUserAgent `
                    -SuppressErrorOutput
                if ($null -ne $videoInfo) {
                    $usedLayer1b = $true
                }
            }
            if ($null -eq $videoInfo) {
                $fallbackOk = Invoke-LayeredFallbackPipeline `
                    -TargetUrl $targetUrl `
                    -Deps $deps `
                    -OutputDir $outputDir `
                    -SelectedQuality $selectedQuality `
                    -SelectedFormat $selectedFormat `
                    -IsAudioOnly:$isAudioOnly `
                    -SubtitleLangs $ResolvedParams.Subs `
                    -BrowserCookies $ResolvedParams.Cookies `
                    -IsInteractive:$isInteractive
                $script:ProcessExitCode = if ($fallbackOk) { 0 } else { 1 }
                return
            }
            $resolutions = @(Get-AvailableResolutions -VideoInfo $videoInfo)
            $effectiveSelection = Select-EffectiveQuality -RequestedQuality $selectedQuality -AvailableResolutions $resolutions
            if ($effectiveSelection.FallbackUsed -and -not [string]::IsNullOrWhiteSpace($effectiveSelection.Message)) {
                Write-Host $effectiveSelection.Message -ForegroundColor Yellow
            }
            $selectedQuality = $effectiveSelection.EffectiveQuality
        }
    }

    if (-not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $printFile = Join-Path -Path $env:TEMP -ChildPath "videodl_filepath_$([guid]::NewGuid().ToString('N')).txt"
    $errFile = Join-Path -Path $env:TEMP -ChildPath "videodl_dl_err_$([guid]::NewGuid().ToString('N')).log"
    $ffmpegDir = Split-Path -Path $deps.FfmpegPath -Parent

    $ytArgs = Get-YtDlpArgumentList `
        -TargetUrl $targetUrl `
        -SelectedQuality $selectedQuality `
        -SelectedFormat $selectedFormat `
        -IsAudioOnly:$isAudioOnly `
        -OutputDirectory $outputDir `
        -IncludePlaylist:([bool]$ResolvedParams.Playlist) `
        -SubtitleLangs $ResolvedParams.Subs `
        -BrowserCookies $ResolvedParams.Cookies `
        -FfmpegPath $ffmpegDir `
        -PrintFilePath $printFile `
        -NoCheckCertificate:$usedLayer1b `
        -RefererUrl $(if ($usedLayer1b) { $targetUrl } else { '' }) `
        -OriginUrl $(if ($usedLayer1b) { $originUrl } else { '' }) `
        -UserAgent $(if ($usedLayer1b) { $script:DefaultUserAgent } else { '' })

    Write-Host 'İndirme başlatılıyor...' -ForegroundColor Cyan
    $downloadCompleted = $false
    $dlExitCode = 1
    $prevEap = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        & $deps.YtDlpPath @ytArgs 2>$errFile
        $dlExitCode = $LASTEXITCODE
        $downloadCompleted = $true
    } finally {
        $ErrorActionPreference = $prevEap
        if (-not $downloadCompleted) {
            Write-Host ''
            Write-Host 'İndirme kullanıcı tarafından iptal edildi. Yarım kalan (.part) dosyalar daha sonra devam ettirilmek üzere korundu.' -ForegroundColor Yellow
        }
    }

    $rawErr = ''
    if (Test-Path -LiteralPath $errFile) {
        $rawErr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }

    # Katman 1a indirme sırasında başarısız olduysa ve henüz 1b denenmediyse önce 1b'yi dene
    if ($dlExitCode -ne 0 -and -not $usedLayer1b) {
        Write-Host '[Katman 1a] İndirme başarısız — [Katman 1b] --no-check-certificate ve Referer başlığıyla tekrar deneniyor...' -ForegroundColor Yellow
        $usedLayer1b = $true
        $ytArgs1b = Get-YtDlpArgumentList `
            -TargetUrl $targetUrl `
            -SelectedQuality $selectedQuality `
            -SelectedFormat $selectedFormat `
            -IsAudioOnly:$isAudioOnly `
            -OutputDirectory $outputDir `
            -IncludePlaylist:([bool]$ResolvedParams.Playlist) `
            -SubtitleLangs $ResolvedParams.Subs `
            -BrowserCookies $ResolvedParams.Cookies `
            -FfmpegPath $ffmpegDir `
            -PrintFilePath $printFile `
            -NoCheckCertificate `
            -RefererUrl $targetUrl `
            -OriginUrl $originUrl `
            -UserAgent $script:DefaultUserAgent

        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $deps.YtDlpPath @ytArgs1b 2>$errFile
            $dlExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if (Test-Path -LiteralPath $errFile) {
            $rawErr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Katman 1b de başarısızsa DURMA -> Katman 2-5 Pipeline'ına geç!
    if ($dlExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($rawErr)) {
            Write-Verbose "yt-dlp ham hata çıktısı:`n$rawErr"
        }
        if (Test-Path -LiteralPath $printFile) {
            Remove-Item -LiteralPath $printFile -Force -ErrorAction SilentlyContinue
        }
        $fallbackOk = Invoke-LayeredFallbackPipeline `
            -TargetUrl $targetUrl `
            -Deps $deps `
            -OutputDir $outputDir `
            -SelectedQuality $selectedQuality `
            -SelectedFormat $selectedFormat `
            -IsAudioOnly:$isAudioOnly `
            -SubtitleLangs $ResolvedParams.Subs `
            -BrowserCookies $ResolvedParams.Cookies `
            -IsInteractive:$isInteractive
        $script:ProcessExitCode = if ($fallbackOk) { 0 } else { 1 }
        return
    }

    $finalPath = $null
    if (Test-Path -LiteralPath $printFile) {
        $printedLines = @(
            Get-Content -LiteralPath $printFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                Where-Object -FilterScript { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($printedLines.Count -gt 0) {
            $finalPath = $printedLines[-1].Trim()
        }
        Remove-Item -LiteralPath $printFile -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($finalPath) -or -not (Test-Path -LiteralPath $finalPath)) {
        $latestFile = Get-ChildItem -LiteralPath $outputDir -File -ErrorAction SilentlyContinue |
            Where-Object -FilterScript { $_.Extension -ne '.part' -and $_.Extension -ne '.ytdl' } |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $latestFile) {
            $finalPath = $latestFile.FullName
        } else {
            $finalPath = $outputDir
        }
    }

    $probeInfo = Test-MediaFileWithFfprobe -FilePath $finalPath
    $layerLabel = if ($usedLayer1b) { 'Katman 1b (yt-dlp + Referer/SSL Bypass)' } else { 'Katman 1a (yt-dlp Doğrudan Çıkarım)' }
    Write-MediaFetchReport `
        -Status 'Başarılı' `
        -FilePathAndSize "$finalPath ($($probeInfo.SizeText))" `
        -QualityAndCodec $probeInfo.QualitySummary `
        -StreamUrl $targetUrl `
        -WorkingLayer $layerLabel `
        -Notes 'İndirme tamamlandı ve ffprobe ile doğrulandı.'

    if ($isInteractive) {
        $openAns = Read-Host -Prompt 'Open folder? (y/N)'
        if (-not [string]::IsNullOrWhiteSpace($openAns) -and $openAns.Trim() -match '^(y|yes|e|evet)$') {
            if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList @("/select,`"$finalPath`"")
            } else {
                Start-Process -FilePath 'explorer.exe' -ArgumentList @("`"$outputDir`"")
            }
        }
    }

    $script:ProcessExitCode = 0
}

function Invoke-Main {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ResolvedConfig
    )

    if (-not $ResolvedConfig.IsValid) {
        Write-Host $ResolvedConfig.ErrorMessage -ForegroundColor Red
        $script:ProcessExitCode = $ResolvedConfig.ExitCode
        return
    }

    switch ($ResolvedConfig.Action) {
        'Help' {
            Show-HelpMessage
            $script:ProcessExitCode = 0
        }
        'Update' {
            $script:ProcessExitCode = Invoke-VideoDlUpdate
        }
        'Uninstall' {
            $script:ProcessExitCode = Invoke-VideoDlUninstall
        }
        'Download' {
            Invoke-VideoDownload -ResolvedParams $ResolvedConfig
        }
        default {
            Write-Host 'Hata: Bilinmeyen işlem türü.' -ForegroundColor Red
            $script:ProcessExitCode = 1
        }
    }
}

if (-not $NoRun -and $MyInvocation.InvocationName -ne '.' -and $env:VIDEODL_LOAD_ONLY -ne '1') {
    $script:ProcessExitCode = 0
    $cliConfig = Resolve-CliParameters `
        -InputUrl $Url `
        -InputQuality $Quality `
        -InputFormat $Format `
        -InputAudioOnly:$AudioOnly `
        -InputOutput $Output `
        -InputPlaylist:$Playlist `
        -InputSubs $Subs `
        -InputCookies $Cookies `
        -InputUpdate:$Update `
        -InputUninstall:$Uninstall `
        -InputHelp:$Help `
        -InputRemainingArgs $RemainingArgs
    Invoke-Main -ResolvedConfig $cliConfig
    exit $script:ProcessExitCode
}
