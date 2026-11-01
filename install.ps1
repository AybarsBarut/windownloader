& {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $installRoot = if ($env:VIDEODL_HOME) { $env:VIDEODL_HOME } else { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'VideoDL' }
    $binDir = Join-Path -Path $installRoot -ChildPath 'bin'
    $repoRawBase = if ($env:VIDEODL_REPO_URL) { $env:VIDEODL_REPO_URL.TrimEnd('/') } else { 'https://raw.githubusercontent.com/AybarsBarut/windownloader/main' }

    function Write-InstallMessage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Installer outputs colored status messages to the console host.')]
        param(
            [Parameter(Mandatory = $false)]
            [AllowEmptyString()]
            [string]$Message = '',

            [Parameter(Mandatory = $false)]
            [ConsoleColor]$Color = [ConsoleColor]::Gray
        )
        $decoded = [regex]::Replace($Message, '\\u([0-9a-fA-F]{4})', { param($m) [char][int]::Parse($m.Groups[1].Value, [System.Globalization.NumberStyles]::HexNumber) }); Write-Host $decoded -ForegroundColor $Color
    }

    function ConvertTo-CleanPathEntry {
        param([string]$Entry)
        if ([string]::IsNullOrWhiteSpace($Entry)) {
            return ''
        }
        return $Entry.Trim().Trim('"').TrimEnd('\', '/')
    }

    function Test-PathContainsEntry {
        param(
            [AllowEmptyString()][string]$PathValue,
            [string]$TargetEntry
        )
        if ([string]::IsNullOrWhiteSpace($PathValue)) {
            return $false
        }
        $cleanTarget = ConvertTo-CleanPathEntry -Entry $TargetEntry
        foreach ($part in ($PathValue -split ';')) {
            $cleanPart = ConvertTo-CleanPathEntry -Entry $part
            if ([string]::Equals($cleanPart, $cleanTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    function Add-EntryToPathString {
        param(
            [AllowEmptyString()][string]$PathValue,
            [string]$TargetEntry
        )
        $cleanTarget = $TargetEntry.Trim().Trim('"').TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($PathValue)) {
            return $cleanTarget
        }
        if (Test-PathContainsEntry -PathValue $PathValue -TargetEntry $cleanTarget) {
            return $PathValue
        }
        $trimmed = $PathValue.TrimEnd(';')
        return "$trimmed;$cleanTarget"
    }

    Write-InstallMessage -Message '=== VideoDL Kurulumu Ba\u015flat\u0131l\u0131yor ===' -Color Cyan

    if (-not (Test-Path -LiteralPath $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    # 1. yt-dlp kontrol\u00fc ve kurulumu
    $forceDeps = ($env:VIDEODL_FORCE_DEPS -eq '1')
    $existingYtDlp = $null
    if (-not $forceDeps) {
        $existingYtDlp = Get-Command -Name 'yt-dlp' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -ne $existingYtDlp -and -not [string]::IsNullOrWhiteSpace($existingYtDlp.Source)) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ytVer = & $existingYtDlp.Source --version 2>&1
            $ytCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($ytCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($ytVer | Out-String))) {
            $verStr = ($ytVer | Select-Object -First 1).ToString().Trim()
            $isOld = $false
            if ($verStr -match '^(?<y>\d{4})\.(?<m>\d{2})\.(?<d>\d{2})') {
                try {
                    $verDate = New-Object -TypeName DateTime -ArgumentList @([int]$Matches['y'], [int]$Matches['m'], [int]$Matches['d'])
                    if (([DateTime]::UtcNow - $verDate).TotalDays -gt 60) {
                        $isOld = $true
                    }
                } catch {
                    $isOld = $false
                }
            }
            if ($isOld) {
                Write-InstallMessage -Message "Sistemdeki yt-dlp s\u00fcr\u00fcm\u00fc ($verStr) eski; g\u00fcncel resmi s\u00fcr\u00fcm indiriliyor..." -Color Yellow
                $existingYtDlp = $null
            } else {
                Write-InstallMessage -Message "Sistemde g\u00fcncel yt-dlp bulundu: $($existingYtDlp.Source) (S\u00fcr\u00fcm: $verStr)" -Color Green
            }
        } else {
            $existingYtDlp = $null
        }
    }

    if ($null -eq $existingYtDlp) {
        $ytDlpTarget = Join-Path -Path $binDir -ChildPath 'yt-dlp.exe'
        $ytDlpUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
        Write-InstallMessage -Message 'yt-dlp resmi GitHub s\u00fcr\u00fcm\u00fcnden indiriliyor...' -Color Cyan
        Invoke-WebRequest -Uri $ytDlpUrl -OutFile $ytDlpTarget -UseBasicParsing
        if (-not (Test-Path -LiteralPath $ytDlpTarget)) {
            throw 'yt-dlp.exe indirilemedi.'
        }
        $ytItem = Get-Item -LiteralPath $ytDlpTarget
        if ($ytItem.Length -lt 1MB) {
            throw "\u0130ndirilen yt-dlp.exe boyutu beklenenden k\u00fc\u00e7\u00fck ($($ytItem.Length) bayt)."
        }
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ytVerOut = & $ytDlpTarget --version 2>&1
            $ytVerCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($ytVerCode -ne 0 -or [string]::IsNullOrWhiteSpace(($ytVerOut | Out-String))) {
            throw '\u0130ndirilen yt-dlp.exe s\u00fcr\u00fcm do\u011frulamas\u0131ndan ge\u00e7emedi.'
        }
        Write-InstallMessage -Message "yt-dlp ba\u015far\u0131yla kuruldu (S\u00fcr\u00fcm: $(($ytVerOut | Select-Object -First 1).ToString().Trim()))." -Color Green
    }

    # 2. ffmpeg kontrol\u00fc ve kurulumu
    $existingFfmpeg = $null
    if (-not $forceDeps) {
        $existingFfmpeg = Get-Command -Name 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -ne $existingFfmpeg -and -not [string]::IsNullOrWhiteSpace($existingFfmpeg.Source)) {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ffVer = & $existingFfmpeg.Source -version 2>&1
            $ffCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($ffCode -eq 0 -and ($ffVer | Out-String) -match 'ffmpeg version') {
            Write-InstallMessage -Message "Sistemde mevcut ffmpeg bulundu: $($existingFfmpeg.Source)" -Color Green
        } else {
            $existingFfmpeg = $null
        }
    }

    if ($null -eq $existingFfmpeg) {
        $ffmpegZipUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
        $tempZip = Join-Path -Path $env:TEMP -ChildPath "videodl_ffmpeg_$([guid]::NewGuid().ToString('N')).zip"
        $tempExtract = Join-Path -Path $env:TEMP -ChildPath "videodl_ffmpeg_dir_$([guid]::NewGuid().ToString('N'))"
        try {
            Write-InstallMessage -Message 'ffmpeg resmi GitHub s\u00fcr\u00fcm\u00fcnden (BtbN/FFmpeg-Builds) indiriliyor...' -Color Cyan
            Invoke-WebRequest -Uri $ffmpegZipUrl -OutFile $tempZip -UseBasicParsing
            if (-not (Test-Path -LiteralPath $tempZip)) {
                throw 'ffmpeg zip ar\u015fivi indirilemedi.'
            }
            $zipItem = Get-Item -LiteralPath $tempZip
            if ($zipItem.Length -lt 10MB) {
                throw "\u0130ndirilen ffmpeg zip boyutu beklenenden k\u00fc\u00e7\u00fck ($($zipItem.Length) bayt)."
            }
            Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force
            $extractedFfmpeg = Get-ChildItem -Path $tempExtract -Filter 'ffmpeg.exe' -Recurse -File | Select-Object -First 1
            if ($null -eq $extractedFfmpeg) {
                throw 'A\u00e7\u0131lan zip ar\u015fivinde ffmpeg.exe bulunamad\u0131.'
            }
            $ffmpegTarget = Join-Path -Path $binDir -ChildPath 'ffmpeg.exe'
            Copy-Item -LiteralPath $extractedFfmpeg.FullName -Destination $ffmpegTarget -Force

            $extractedFfprobe = Get-ChildItem -Path $tempExtract -Filter 'ffprobe.exe' -Recurse -File | Select-Object -First 1
            if ($null -ne $extractedFfprobe) {
                Copy-Item -LiteralPath $extractedFfprobe.FullName -Destination (Join-Path -Path $binDir -ChildPath 'ffprobe.exe') -Force
            }

            $prevEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $ffVerOut = & $ffmpegTarget -version 2>&1
                $ffVerCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if ($ffVerCode -ne 0 -or ($ffVerOut | Out-String) -notmatch 'ffmpeg version') {
                throw '\u0130ndirilen ffmpeg.exe s\u00fcr\u00fcm do\u011frulamas\u0131ndan ge\u00e7emedi.'
            }
            Write-InstallMessage -Message 'ffmpeg ba\u015far\u0131yla kuruldu ve do\u011fruland\u0131.' -Color Green
        } finally {
            if (Test-Path -LiteralPath $tempZip) {
                Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempExtract) {
                Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 3. Ana beti\u011fi (download.ps1) indir veya yerel kaynaktan kopyala
    $downloadPs1Target = Join-Path -Path $installRoot -ChildPath 'download.ps1'
    $downloadPs1Url = "$repoRawBase/download.ps1"
    $downloadedFromRemote = $false

    if (-not $env:VIDEODL_LOCAL_SOURCE) {
        $tempPs1 = Join-Path -Path $env:TEMP -ChildPath "videodl_script_$([guid]::NewGuid().ToString('N')).ps1"
        try {
            Write-InstallMessage -Message "Ana betik indiriliyor: $downloadPs1Url" -Color Cyan
            Invoke-WebRequest -Uri $downloadPs1Url -OutFile $tempPs1 -UseBasicParsing
            if ((Test-Path -LiteralPath $tempPs1) -and (Get-Item -LiteralPath $tempPs1).Length -gt 512) {
                $rawContent = Get-Content -LiteralPath $tempPs1 -Raw -Encoding UTF8
                $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
                [System.IO.File]::WriteAllText($downloadPs1Target, $rawContent, $utf8Bom)
                $downloadedFromRemote = $true
                Write-InstallMessage -Message "download.ps1 ba\u015far\u0131yla indirildi: $downloadPs1Target" -Color Green
            }
        } catch {
            Write-InstallMessage -Message 'Bilgi: Uzak GitHub adresine ula\u015f\u0131lamad\u0131, yerel dizin kontrol ediliyor...' -Color Yellow
        } finally {
            if (Test-Path -LiteralPath $tempPs1) {
                Remove-Item -LiteralPath $tempPs1 -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $downloadedFromRemote) {
        $localCandidate = if ($env:VIDEODL_LOCAL_SOURCE) {
            $env:VIDEODL_LOCAL_SOURCE
        } else {
            Join-Path -Path (Get-Location).Path -ChildPath 'download.ps1'
        }
        if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
            $rawContent = Get-Content -LiteralPath $localCandidate -Raw -Encoding UTF8
            $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
            [System.IO.File]::WriteAllText($downloadPs1Target, $rawContent, $utf8Bom)
            Write-InstallMessage -Message "download.ps1 yerel kaynaktan kuruldu: $downloadPs1Target" -Color Green
        } else {
            throw "download.ps1 ne uzak depodan ($downloadPs1Url) ne de yerel dizinden ($localCandidate) temin edilebildi."
        }
    }

    # 4. download.cmd shim olu\u015ftur
    $shimPath = Join-Path -Path $binDir -ChildPath 'download.cmd'
    $shimContent = "@echo off`r`n(goto) 2>nul & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\download.ps1`" %*`r`n"
    $asciiEncoding = New-Object -TypeName System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText($shimPath, $shimContent, $asciiEncoding)
    Write-InstallMessage -Message "Komut shim'i olu\u015fturuldu: $shimPath" -Color Green

    # 5. Kullan\u0131c\u0131 PATH de\u011fi\u015fkenini ve mevcut oturum PATH'ini idempotent olarak g\u00fcncelle
    $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Test-PathContainsEntry -PathValue $currentUserPath -TargetEntry $binDir)) {
        $newUserPath = Add-EntryToPathString -PathValue $currentUserPath -TargetEntry $binDir
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-InstallMessage -Message "Kullan\u0131c\u0131 PATH de\u011fi\u015fkenine eklendi: $binDir" -Color Green
    } else {
        Write-InstallMessage -Message "Kullan\u0131c\u0131 PATH de\u011fi\u015fkeninde zaten mevcut: $binDir" -Color Gray
    }

    if (-not (Test-PathContainsEntry -PathValue $env:Path -TargetEntry $binDir)) {
        $env:Path = Add-EntryToPathString -PathValue $env:Path -TargetEntry $binDir
        Write-InstallMessage -Message 'Mevcut PowerShell oturumu i\u00e7in $env:Path g\u00fcncellendi.' -Color Green
    }

    Write-InstallMessage -Message ''
    Write-InstallMessage -Message 'Kurulum tamamland\u0131! Art\u0131k "download" komutunu hemen kullanabilirsiniz.' -Color Green
    Write-InstallMessage -Message '\u00d6rnek: download https://... veya download -Help' -Color Cyan
}
