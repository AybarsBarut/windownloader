[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are shared across It blocks.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$script:RepoRoot = Split-Path -Path $script:TestDir -Parent
$script:DownloadScript = Join-Path -Path $script:RepoRoot -ChildPath 'download.ps1'

. $script:DownloadScript -NoRun

Describe 'VideoDL Unit Tests (download.ps1)' {
    BeforeAll {
        $testDirLocal = Split-Path -Path $PSCommandPath -Parent
        $repoRootLocal = Split-Path -Path $testDirLocal -Parent
        $downloadScriptLocal = Join-Path -Path $repoRootLocal -ChildPath 'download.ps1'
        . $downloadScriptLocal -NoRun

        $pesterMod = Get-Module -Name Pester | Select-Object -First 1
        if ($null -ne $pesterMod -and $pesterMod.Version.Major -lt 5) {
            function Should {
                param(
                    [Parameter(ValueFromPipeline = $true)]$Actual,
                    [switch]$Not,
                    [switch]$Be,
                    [switch]$BeExactly,
                    [switch]$BeGreaterThan,
                    [switch]$BeLessThan,
                    [switch]$BeTrue,
                    [switch]$BeFalse,
                    [switch]$BeNullOrEmpty,
                    [switch]$Match,
                    [switch]$Throw,
                    [Parameter(Position = 0)]$Expected
                )
                process {
                    if ($BeTrue) {
                        if ($Not) { $Actual | Pester\Should Not Be $true } else { $Actual | Pester\Should Be $true }
                        return
                    }
                    if ($BeFalse) {
                        if ($Not) { $Actual | Pester\Should Not Be $false } else { $Actual | Pester\Should Be $false }
                        return
                    }
                    $op = if ($Be) { 'Be' } elseif ($BeExactly) { 'BeExactly' } elseif ($BeGreaterThan) { 'BeGreaterThan' } elseif ($BeLessThan) { 'BeLessThan' } elseif ($BeNullOrEmpty) { 'BeNullOrEmpty' } elseif ($Match) { 'Match' } elseif ($Throw) { 'Throw' }
                    if ($Not) {
                        if ($PSBoundParameters.ContainsKey('Expected')) { $Actual | Pester\Should Not $op $Expected } else { $Actual | Pester\Should Not $op }
                    } else {
                        if ($PSBoundParameters.ContainsKey('Expected')) { $Actual | Pester\Should $op $Expected } else { $Actual | Pester\Should $op }
                    }
                }
            }
        }
    }

    Context 'URL Dogrulama (Test-VideoUrl)' {
        It 'Gecerli https ve http URL adreslerini kabul eder' {
            (Test-VideoUrl -InputUrl 'https://www.youtube.com/watch?v=dQw4w9WgXcQ') | Should -BeTrue
            (Test-VideoUrl -InputUrl 'http://example.com/video.mp4') | Should -BeTrue
            (Test-VideoUrl -InputUrl 'https://vimeo.com/123456789') | Should -BeTrue
        }

        It 'Bos, gecersiz sema veya bayrak iceren girdileri reddeder' {
            (Test-VideoUrl -InputUrl '') | Should -BeFalse
            (Test-VideoUrl -InputUrl '   ') | Should -BeFalse
            (Test-VideoUrl -InputUrl 'ftp://example.com/file.mp4') | Should -BeFalse
            (Test-VideoUrl -InputUrl 'not-a-url') | Should -BeFalse
            (Test-VideoUrl -InputUrl '--update') | Should -BeFalse
            (Test-VideoUrl -InputUrl 'https://example.com/boşluk var') | Should -BeFalse
        }
    }

    Context 'Parametre Ayristirma (Resolve-CliParameters)' {
        It 'Parametresiz cagrildiginda etkilesimli modu secer' {
            $res = Resolve-CliParameters -InputUrl ''
            $res.IsValid | Should -BeTrue
            $res.IsInteractive | Should -BeTrue
            $res.Action | Should -Be 'Download'
        }

        It 'Yalnizca URL verildiginde etkilesimli modu secer' {
            $res = Resolve-CliParameters -InputUrl 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
            $res.IsValid | Should -BeTrue
            $res.IsInteractive | Should -BeTrue
            $res.Url | Should -Be 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
        }

        It 'Parametre verildiginde etkilesimsiz (otomasyon) modunu secer' {
            $res = Resolve-CliParameters -InputUrl 'https://example.com/v' -InputQuality '1080' -InputFormat 'mp4' -InputOutput 'D:\Videolar'
            $res.IsValid | Should -BeTrue
            $res.IsInteractive | Should -BeFalse
            $res.Quality | Should -Be '1080'
            $res.Format | Should -Be 'mp4'
            $res.Output | Should -Be 'D:\Videolar'
            $res.IsAudioOnly | Should -BeFalse
        }

        It '-AudioOnly ve ses formatini dogru ayristirir' {
            $res = Resolve-CliParameters -InputUrl 'https://example.com/v' -InputAudioOnly -InputFormat 'mp3'
            $res.IsValid | Should -BeTrue
            $res.IsInteractive | Should -BeFalse
            $res.IsAudioOnly | Should -BeTrue
            $res.Format | Should -Be 'mp3'
        }

        It '-Subs parametresini virgulle ayrilmis dizeye normallestirir' {
            $res = Resolve-CliParameters -InputUrl 'https://example.com/v' -InputSubs @('tr', 'en')
            $res.IsValid | Should -BeTrue
            $res.IsInteractive | Should -BeFalse
            $res.Subs | Should -Be 'tr,en'
            $res.Quality | Should -Be 'best'
            $res.Format | Should -Be 'mp4'
        }

        It '--update ve --uninstall bayraklarini dogru eyleme yonlendirir' {
            $upd = Resolve-CliParameters -InputUrl '--update'
            $upd.IsValid | Should -BeTrue
            $upd.Action | Should -Be 'Update'

            $uninst = Resolve-CliParameters -InputUrl '--uninstall'
            $uninst.IsValid | Should -BeTrue
            $uninst.Action | Should -Be 'Uninstall'
        }

        It 'Gecersiz cozunurluk veya formatta ExitCode 2 dondurur' {
            $badQ = Resolve-CliParameters -InputUrl 'https://example.com/v' -InputQuality '999'
            $badQ.IsValid | Should -BeFalse
            $badQ.ExitCode | Should -Be 2

            $badF = Resolve-CliParameters -InputUrl 'https://example.com/v' -InputFormat 'avi'
            $badF.IsValid | Should -BeFalse
            $badF.ExitCode | Should -Be 2
        }
    }

    Context 'Cozunurluk Listesi Olusturma ve Yakin Cozunurluge Dusme (JSON Fixture)' {
        BeforeAll {
            $fixtureJson = @'
{
  "id": "sample123",
  "title": "Ornek Test Videosu",
  "duration": 120,
  "duration_string": "02:00",
  "formats": [
    { "format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "filesize": 1920000 },
    { "format_id": "18",  "ext": "mp4", "height": 360,  "fps": 30, "vcodec": "avc1", "acodec": "mp4a", "filesize": 8500000 },
    { "format_id": "135", "ext": "mp4", "height": 480,  "fps": 30, "vcodec": "avc1", "acodec": "none", "filesize": 15000000 },
    { "format_id": "136", "ext": "mp4", "height": 720,  "fps": 30, "vcodec": "avc1", "acodec": "none", "filesize": 28000000 },
    { "format_id": "298", "ext": "mp4", "height": 720,  "fps": 60, "vcodec": "avc1", "acodec": "none", "filesize": 35000000 },
    { "format_id": "299", "ext": "mp4", "height": 1080, "fps": 60, "vcodec": "avc1", "acodec": "none", "filesize": 68000000 }
  ]
}
'@
            $script:SampleVideoInfo = $fixtureJson | ConvertFrom-Json
        }

        It 'Benzersiz cozunurlukleri azalan sirada ve enonda yalnizca ses secenegiyle listeler' {
            $resList = @(Get-AvailableResolutions -VideoInfo $script:SampleVideoInfo)
            $resList.Count | Should -Be 5
            $resList[0].Label | Should -Be '1080p'
            $resList[0].Fps | Should -Be 60
            $resList[1].Label | Should -Be '720p'
            $resList[1].Fps | Should -Be 60
            $resList[2].Label | Should -Be '480p'
            $resList[3].Label | Should -Be '360p'
            $resList[4].IsAudioOnly | Should -BeTrue
        }

        It 'Istenen cozunurluk mevcut degilse en yakin dusuk cozunurluge duser' {
            $resList = @(Get-AvailableResolutions -VideoInfo $script:SampleVideoInfo)
            $fallback = Select-EffectiveQuality -RequestedQuality '1440' -AvailableResolutions $resList
            $fallback.FallbackUsed | Should -BeTrue
            $fallback.EffectiveQuality | Should -Be '1080'
            $fallback.Message | Should -Match '1080p'

            $exact = Select-EffectiveQuality -RequestedQuality '720' -AvailableResolutions $resList
            $exact.FallbackUsed | Should -BeFalse
            $exact.EffectiveQuality | Should -Be '720'
        }
    }

    Context 'Format Secici ve Arguman Listesi Uretimi (Get-YtDlpFormatSelector / Get-YtDlpArgumentList)' {
        It '1080p mp4 icin dogru format secici dizesi uretir' {
            $sel = Get-YtDlpFormatSelector -SelectedQuality '1080' -SelectedFormat 'mp4'
            $sel.FormatExpression | Should -Be 'bv*[height<=1080]+ba/b[height<=1080]'
            $sel.MergeOutputFormat | Should -Be 'mp4'
            $sel.ExtractAudio | Should -BeFalse
        }

        It 'best mkv icin dogru format secici dizesi uretir' {
            $sel = Get-YtDlpFormatSelector -SelectedQuality 'best' -SelectedFormat 'mkv'
            $sel.FormatExpression | Should -Be 'bv*+ba/b'
            $sel.MergeOutputFormat | Should -Be 'mkv'
        }

        It 'AudioOnly mp3 icin -x --audio-format mp3 argumanlarini uretir' {
            $sel = Get-YtDlpFormatSelector -SelectedQuality 'best' -SelectedFormat 'mp3' -IsAudioOnly
            $sel.FormatExpression | Should -Be 'bestaudio/best'
            $sel.ExtractAudio | Should -BeTrue
            $sel.AudioFormat | Should -Be 'mp3'
            ($sel.Arguments -join ' ') | Should -Be '-f bestaudio/best -x --audio-format mp3'
        }

        It 'Tam yt-dlp arguman dizisinde --windows-filenames, -o sablonu ve URL ayiricisi (--) bulunur' {
            $argsList = Get-YtDlpArgumentList -TargetUrl 'https://example.com/watch?v=1' -SelectedQuality '720' -SelectedFormat 'mp4' -OutputDirectory 'C:\Videos' -SubtitleLangs 'tr,en' -BrowserCookies 'firefox'
            ($argsList -contains '--windows-filenames') | Should -BeTrue
            ($argsList -contains '--no-playlist') | Should -BeTrue
            ($argsList -contains '--sub-langs') | Should -BeTrue
            ($argsList -contains 'tr,en') | Should -BeTrue
            ($argsList -contains '--cookies-from-browser') | Should -BeTrue
            ($argsList -contains 'firefox') | Should -BeTrue
            ($argsList -contains 'C:\Videos\%(title).150B [%(id)s].%(ext)s') | Should -BeTrue
            $argsList[-2] | Should -Be '--'
            $argsList[-1] | Should -Be 'https://example.com/watch?v=1'
        }
    }

    Context 'PATH Ekleme ve Silme Idempotency (Add-PathStringEntry / Remove-PathStringEntry)' {
        It 'Ayni dizini birden fazla kez eklemez (buyuk/kucuk harf ve sondaki slash duyarsiz)' {
            $initialPath = 'C:\Windows\System32;C:\Windows'
            $target = 'C:\Users\Test\AppData\Local\VideoDL\bin'

            $once = Add-PathStringEntry -PathString $initialPath -TargetDir $target
            $twice = Add-PathStringEntry -PathString $once -TargetDir "$target\"
            $thrice = Add-PathStringEntry -PathString $twice -TargetDir $target.ToUpperInvariant()

            $once | Should -Be "$initialPath;$target"
            $twice | Should -Be $once
            $thrice | Should -Be $once
        }

        It 'Dizini PATH icinden temiz bir sekilde kaldirir' {
            $target = 'C:\Users\Test\AppData\Local\VideoDL\bin'
            $withTarget = "C:\Windows\System32;$target;C:\Program Files\Git\cmd"
            $removed = Remove-PathStringEntry -PathString $withTarget -TargetDir "$target\"

            $removed | Should -Be 'C:\Windows\System32;C:\Program Files\Git\cmd'
            (Test-PathStringEntry -PathString $removed -TargetDir $target) | Should -BeFalse
        }
    }

    Context 'Hata Mesaji Cevirisi (Convert-YtDlpErrorToTurkish)' {
        It 'Farkli yt-dlp hatalarini tek satirlik anlasilir Turkce mesajlara donusturur' {
            (Convert-YtDlpErrorToTurkish -RawError 'ERROR: Unsupported URL: https://foo.bar') | Should -Match 'desteklenmeyen URL'
            (Convert-YtDlpErrorToTurkish -RawError 'ERROR: [Errno 11001] getaddrinfo failed') | Should -Match 'Ağ bağlantısı'
            (Convert-YtDlpErrorToTurkish -RawError 'ERROR: Sign in to confirm your age') | Should -Match 'yaş sınırı veya oturum açma'
            (Convert-YtDlpErrorToTurkish -RawError 'ERROR: Video not available in your country') | Should -Match 'coğrafi kısıtlama'
            (Convert-YtDlpErrorToTurkish -RawError 'ERROR: No space left on device') | Should -Match 'yeterli boş alan yok'
        }
    }
}
