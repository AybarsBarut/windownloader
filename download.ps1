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

    return [PSCustomObject]@{
        FormatExpression  = $fmtExpr
        MergeOutputFormat = $cleanFmt
        ExtractAudio      = $false
        AudioFormat       = $null
        Arguments         = @('-f', $fmtExpr, '--merge-output-format', $cleanFmt)
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
        [string]$PrintFilePath
    )

    $argList = New-Object -TypeName System.Collections.Generic.List[string]
    $selector = Get-YtDlpFormatSelector -SelectedQuality $SelectedQuality -SelectedFormat $SelectedFormat -IsAudioOnly:$IsAudioOnly
    foreach ($item in $selector.Arguments) {
        $argList.Add($item)
    }

    $argList.Add('--windows-filenames')
    $argList.Add('--continue')
    $argList.Add('--no-update')

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

    $outputTemplate = Join-Path -Path $OutputDirectory -ChildPath '%(title).150B [%(id)s].%(ext)s'
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
    $remoteScriptUrl = "$($script:RepoRawBaseUrl)/download.ps1"
    $tempScript = Join-Path -Path $env:TEMP -ChildPath "videodl_update_$([guid]::NewGuid().ToString('N')).ps1"
    try {
        Invoke-WebRequest -Uri $remoteScriptUrl -OutFile $tempScript -UseBasicParsing
        if ((Get-Item -LiteralPath $tempScript).Length -gt 512) {
            Copy-Item -LiteralPath $tempScript -Destination $targetScript -Force
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

function Get-VideoMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YtDlpPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetUrl,

        [Parameter(Mandatory = $false)]
        [string]$BrowserCookies
    )

    $metaArgs = New-Object -TypeName System.Collections.Generic.List[string]
    $metaArgs.Add('-J')
    $metaArgs.Add('--no-playlist')
    $metaArgs.Add('--no-warnings')
    $metaArgs.Add('--no-update')
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

    if ($exitCode -ne 0 -or $null -eq $jsonLines) {
        if (-not [string]::IsNullOrWhiteSpace($rawErr)) {
            Write-Verbose "yt-dlp ham hata çıktısı:`n$rawErr"
        }
        $friendlyMsg = Convert-YtDlpErrorToTurkish -RawError $rawErr
        Write-Host $friendlyMsg -ForegroundColor Red
        return $null
    }

    $jsonText = ($jsonLines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        Write-Host 'Hata: Video bilgileri alınamadı (boş yanıt).' -ForegroundColor Red
        return $null
    }

    try {
        return ($jsonText | ConvertFrom-Json)
    } catch {
        Write-Verbose "JSON ayrıştırma hatası: $($_.Exception.Message)"
        Write-Host 'Hata: Video meta verisi okunamadı.' -ForegroundColor Red
        return $null
    }
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
            return 2
        }
        $targetUrl = $targetUrl.Trim()
    }

    $deps = Assert-Dependencies -IsInteractive:$isInteractive
    if ($null -eq $deps) {
        return 1
    }

    $selectedQuality = $ResolvedParams.Quality
    $selectedFormat = $ResolvedParams.Format
    $isAudioOnly = [bool]$ResolvedParams.IsAudioOnly
    $outputDir = $ResolvedParams.Output

    if ($isInteractive) {
        Write-Host 'Video bilgileri alınıyor...' -ForegroundColor Cyan
        $videoInfo = Get-VideoMetadata -YtDlpPath $deps.YtDlpPath -TargetUrl $targetUrl -BrowserCookies $ResolvedParams.Cookies
        if ($null -eq $videoInfo) {
            return 1
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
                return 2
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
                    return 2
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
                    return 2
                }
                $selectedFormat = $cleanFmt
                if ($selectedFormat -in $script:AudioFormats) {
                    $isAudioOnly = $true
                }
            }
        }
    } else {
        if ((-not $isAudioOnly) -and (-not $ResolvedParams.Playlist) -and ($selectedQuality -ne 'best')) {
            $videoInfo = Get-VideoMetadata -YtDlpPath $deps.YtDlpPath -TargetUrl $targetUrl -BrowserCookies $ResolvedParams.Cookies
            if ($null -eq $videoInfo) {
                return 1
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
        -PrintFilePath $printFile

    Write-Host 'İndirme başlatılıyor...' -ForegroundColor Cyan
    $downloadCompleted = $false
    $dlExitCode = 1
    $prevEap = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        & $deps.YtDlpPath @ytArgs 2>$errFile | Out-Host
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

    if ($dlExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($rawErr)) {
            Write-Verbose "yt-dlp ham hata çıktısı:`n$rawErr"
        }
        $friendlyMsg = Convert-YtDlpErrorToTurkish -RawError $rawErr
        Write-Host $friendlyMsg -ForegroundColor Red
        if (Test-Path -LiteralPath $printFile) {
            Remove-Item -LiteralPath $printFile -Force -ErrorAction SilentlyContinue
        }
        return 1
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

    Write-Host "İndirme tamamlandı: $finalPath" -ForegroundColor Green

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

    return 0
}

function Invoke-Main {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ResolvedConfig
    )

    if (-not $ResolvedConfig.IsValid) {
        Write-Host $ResolvedConfig.ErrorMessage -ForegroundColor Red
        return $ResolvedConfig.ExitCode
    }

    switch ($ResolvedConfig.Action) {
        'Help' {
            Show-HelpMessage
            return 0
        }
        'Update' {
            return (Invoke-VideoDlUpdate)
        }
        'Uninstall' {
            return (Invoke-VideoDlUninstall)
        }
        'Download' {
            return (Invoke-VideoDownload -ResolvedParams $ResolvedConfig)
        }
        default {
            Write-Host 'Hata: Bilinmeyen işlem türü.' -ForegroundColor Red
            return 1
        }
    }
}

if (-not $NoRun -and $MyInvocation.InvocationName -ne '.' -and $env:VIDEODL_LOAD_ONLY -ne '1') {
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
    $exitCode = Invoke-Main -ResolvedConfig $cliConfig
    exit $exitCode
}
