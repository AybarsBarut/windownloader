# windownloader (`download`)

Windows için yönetici yetkisi gerektirmeyen, `yt-dlp` ve `ffmpeg` tabanlı yerel komut satırı video ve ses indirici.

Kurulumdan sonra herhangi bir PowerShell veya CMD penceresinde `download` yazarak hem etkileşimli menüyle hem de doğrudan parametre vererek indirme yapabilirsiniz. Arka planda çalışan bir sunucu, telemetri veya hesap zorunluluğu yoktur.

---

## Kurulum

PowerShell (5.1 veya 7+) üzerinden tek satırla kurmak için:

```powershell
irm https://raw.githubusercontent.com/AybarsBarut/windownloader/main/install.ps1 | iex
```

### `iex` Güvenlik Notu

İnternetten indirilen bir betiği doğrudan `Invoke-Expression` (`iex`) ile çalıştırmadan önce kaynağını incelemeniz önerilir. Betiği çalıştırmadan önce içeriğini ekrana yazdırabilirsiniz:

```powershell
irm https://raw.githubusercontent.com/AybarsBarut/windownloader/main/install.ps1
```

`install.ps1` çalıştığında sırasıyla şunları yapar:
1. `%LOCALAPPDATA%\VideoDL\` ve `%LOCALAPPDATA%\VideoDL\bin\` klasörlerini oluşturur (yönetici izni istemez).
2. Sistemde `yt-dlp` ve `ffmpeg` tanımlıysa (`Get-Command`) mevcut kurulumları kullanır. Eksik olan varsa resmi GitHub sürümlerinden (`yt-dlp/yt-dlp` ve `BtbN/FFmpeg-Builds` win64-gpl) indirir, dosya boyutunu ve `--version` çıktısını doğrular.
3. [`download.ps1`](download.ps1) betiğini `%LOCALAPPDATA%\VideoDL\` dizinine kaydeder ve `download.cmd` kısayolunu oluşturur.
4. `%LOCALAPPDATA%\VideoDL\bin` klasörünü kullanıcı `PATH` değişkenine (zaten ekliyse tekrarlamadan) ve açık olan PowerShell oturumuna ekler.

---

## Katmanlı Çözüm Stratejisi (MediaFetch 5-Katman Motoru)

Standart video sitelerinin yanı sıra özel oynatıcı veya gömülü `iframe` kullanan dizi/film/video sayfalarında `download <url>` komutu durmadan sırasıyla 5 katmanı dener:

1. **Katman 1 — Hazır Araçlarla Hızlı Deneme**:
   - **1a**: Standart `yt-dlp` çıkarımı.
   - **1b**: Başarısız olursa `--no-check-certificate`, `Referer`, `Origin` ve `User-Agent` başlıklarıyla ikinci deneme.
2. **Katman 2 — Sayfa Kaynağı, İç İçe Iframe ve Gömülü Oynatıcı Analizi**:
   - Sayfa kaynağını ve iç içe `iframe` zincirini (3 derinliğe kadar, üst sayfa `Referer` bilgisini koruyarak) tarar.
   - Sıkıştırılmış JavaScript (`eval(function(p,a,c,k,e,d)...)`), Base64 (`atob(...)`) ve FirePlayer XHR (`do=getVideo`) yapılarını çözer.
   - `.m3u8`, `.mp4`, `.mpd`, `manifest`, `playlist`, `master` akışlarını ve `.vtt`/`.srt` altyazıları yakalar; gerekirse Headless Tarayıcı (Edge/Chrome/Playwright) ile dinamik DOM ve ağ trafiğini inceler.
3. **Katman 3 — Token, AES-128 HLS ve DRM Analizi**:
   - İmzalı/token'lı akışların (`token=`, `expires=`, `sig=`, `hash=`) parametrelerini ve `Referer` başlığını korur.
   - `#EXT-X-KEY:METHOD=AES-128` şifreli HLS akışlarını ve `#EXT-X-STREAM-INF` kalite varyantlarını tespit eder.
   - İçerikte DRM (Widevine/FairPlay/SAMPLE-AES) varsa kullanıcıyı bilgilendirir ve bulunan akış/altyazı alternatiflerini raporlar.
4. **Katman 4 — İndirme, Birleştirme ve `ffprobe` Doğrulama**:
   - Yakalanan akışı sırasıyla `yt-dlp --hls-prefer-ffmpeg`, doğrudan `ffmpeg` (`-headers ... -c copy -bsf:a aac_adtstoasc`), `N_m3u8DL-RE` ve `streamlink` ile indirir.
   - İndirilen dosyayı `ffprobe` ile doğrular (boyut, süre, codec, çözünürlük); bozuksa bir sonraki varyanta/akışa geçer.
5. **Katman 5 — Derin Headless Yakalama ve Sonuç Raporu**:
   - Her işlem sonunda durum, dosya yolu/boyutu, çözünürlük/codec, kullanılan akış URL'si ve çalışan katmanı içeren özet rapor sunar.

---

## Kullanım

### Etkileşimli Mod

Parametre vermeden `download` veya `download <url>` çalıştırıldığında araç etkileşimli modda açılır:

```powershell
PS> download
URL: https://www.youtube.com/watch?v=...
```

veya doğrudan bağlantıyla:

```powershell
PS> download https://www.youtube.com/watch?v=...
```

1. `yt-dlp -J --no-playlist` ile videonun başlığı, süresi ve mevcut akışları okunur.
2. Videoda bulunan benzersiz çözünürlükler (`2160p`, `1440p`, `1080p`, `720p`, `480p`, `360p` vb.) kare hızı (fps) ve tahmini boyutuyla listelenir. Listenin sonunda **Yalnızca ses (Audio Only)** seçeneği yer alır.
3. Çözünürlük seçildikten sonra çıktı formatı sorulur (`mp4`, `mkv`, `webm`, `mp3`, `m4a`, `opus`, `wav`).
4. İndirme ve `ffmpeg` birleştirme/dönüştürme işlemi tamamlandığında dosyanın tam yolu yazdırılır ve klasörün açılıp açılmayacağı (`Open folder? (y/N)`) sorulur.

### Parametreli Mod (Otomasyon / Betik Kullanımı)

Kalite, format, çıktı klasörü gibi parametrelerden herhangi biri verildiğinde soru sorulmadan doğrudan indirme başlatılır:

```powershell
# 1080p MP4 olarak belirli bir klasöre indir
download <url> -Quality 1080 -Format mp4 -Output "D:\Videolar"

# Yalnızca sesi MP3 olarak indir
download <url> -AudioOnly -Format mp3

# Mevcut en yüksek çözünürlükte indir
download <url> -Quality best

# Oynatma listesinin tamamını indir
download <url> -Playlist

# Türkçe ve İngilizce altyazıları videoyla birlikte indir
download <url> -Subs tr,en

# Tarayıcı çerezlerini kullan (oturum veya yaş doğrulaması isteyen videolar için)
download <url> -Cookies firefox
```

### Parametreler

| Parametre | Açıklama | Varsayılan |
| :--- | :--- | :--- |
| `-Quality` | `best`, `2160`, `1440`, `1080`, `720`, `480`, `360`. İstenen çözünürlük videoda yoksa mevcut en yakın düşük çözünürlüğe düşer ve bilgi verir. | `best` |
| `-Format` | Video için `mp4`, `mkv`, `webm`; ses için `mp3`, `m4a`, `opus`, `wav`. | Video: `mp4`, Ses: `mp3` |
| `-AudioOnly` | Yalnızca ses akışını indirir. | Kapalı |
| `-Output` | Dosyaların kaydedileceği dizin. | `$env:USERPROFILE\Videos\VideoDL` |
| `-Playlist` | Tek video yerine bağlantıdaki oynatma listesinin tamamını indirir. | Kapalı (`--no-playlist`) |
| `-Subs` | Virgülle ayrılmış altyazı dil kodları (`tr,en`). | Yok |
| `-Cookies` | `--cookies-from-browser` için tarayıcı adı (`firefox`, `chrome`, `edge`, `brave`). | Yok |
| `-Update` / `--update` | `yt-dlp` ikilisini ve `download.ps1` betiğini günceller. | - |
| `-Uninstall` / `--uninstall` | `%LOCALAPPDATA%\VideoDL` dizinini siler ve kullanıcı `PATH` kaydını temizler. | - |
| `-Help` / `--help` | Komut satırı yardım ekranını gösterir. | - |
| `-Verbose` | Hata durumunda `yt-dlp`'nin ham hata çıktısını ekrana basar. | Kapalı |

---

## Sıkça Sorulan Sorular

**`ffmpeg` neden gerekiyor?**  
1080p ve üzeri videolar çoğu platformda ayrı görüntü ve ses akışı (DASH) halinde tutulur. Bu akışları tek bir kapsayıcıda (`mp4`/`mkv`) birleştirmek veya sesi `mp3`/`opus`/`wav` formatına dönüştürmek için `ffmpeg` kullanılır. Sistemde kurulu değilse `install.ps1` kurulum sırasında otomatik indirir; daha sonra silinirse `download` çalıştığında yeniden indirmeyi önerir.

**Yaş sınırı olan veya üyelik isteyen videolar nasıl indirilir?**  
Tarayıcınızda ilgili sitede oturum açtıktan sonra komuta `-Cookies firefox` (veya kullandığınız tarayıcı adını) eklemeniz yeterlidir.

**Oynatma listesi bağlantısı verdiğimde neden sadece tek video iniyor?**  
Bir izleme bağlantısındaki `list=` parametresi yüzünden yanlışlıkla tüm listenin inmesini önlemek için varsayılan mod `--no-playlist` olarak çalışır. Tüm listeyi indirmek istediğinizde `-Playlist` bayrağını ekleyin. Not: İçinde `&` karakteri geçen URL'leri komut satırında çift tırnak (`"https://..."`) içinde verin.

**İndirmeyi `Ctrl+C` ile durdurursam baştan mı başlar?**  
Hayır. İptal edildiğinde `.part` uzantılı kısmi dosyalar silinmez. Aynı komutu tekrar çalıştırdığınızda `yt-dlp` kaldığı yerden devam eder.

**Güncelleme ve kaldırma nasıl yapılır?**  
Güncellemek için `download --update`, tamamen kaldırmak için `download --uninstall` komutunu çalıştırın.

---

## Test ve Geliştirme

Birim testlerini (`Pester`) ve kod analizini (`PSScriptAnalyzer`) çalıştırmak için:

```powershell
Invoke-Pester -Path .\tests\download.Tests.ps1
Invoke-ScriptAnalyzer -Path . -Recurse
```

---

## Sorumluluk Notu

Bu araç yalnızca kullanıcının indirme hakkına sahip olduğu içerikler (kendi içeriği, açık lisanslı materyaller veya izin alınmış yayınlar) için tasarlanmıştır. Sitelerin kullanım şartlarına ve telif haklarına uymak kullanıcının sorumluluğundadır. Araç DRM korumasını aşmaya çalışmaz.

---

## English Summary

**windownloader** is a local PowerShell wrapper around `yt-dlp` and `ffmpeg` for Windows that installs into `%LOCALAPPDATA%\VideoDL\` without administrator privileges.

### Install
```powershell
# Inspect install.ps1 first if desired:
# irm https://raw.githubusercontent.com/AybarsBarut/windownloader/main/install.ps1

irm https://raw.githubusercontent.com/AybarsBarut/windownloader/main/install.ps1 | iex
```

### Usage
```powershell
# Interactive mode
download
download https://www.youtube.com/watch?v=...

# Unattended / CLI mode
download <url> -Quality 1080 -Format mp4 -Output "D:\Videos"
download <url> -AudioOnly -Format mp3
download <url> -Quality best
download <url> -Playlist
download <url> -Subs tr,en
download <url> -Cookies firefox

# Update & Uninstall
download --update
download --uninstall
```

### Disclaimer
Use this tool only for content you own, have permission to download, or that is available under an open license. Complying with website Terms of Service and copyright laws is the user's responsibility. This tool does not circumvent DRM.
