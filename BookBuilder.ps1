# BookBuilder.ps1
# ---------------------------------------------------------
# Creates an offline parchment-styled archive of Groth Adventures
# - Downloads posts 2004–present
# - Skips re-downloading text if already saved
# - Repairs missing images
# - Always rebuilds TOCs from local HTML files
# - Yearly & Topic TOCs: dated posts first (chronological), undated after
# - Generates Suggested Topics page
# - Creates index.html with Years and Topics
# - Adds Prev/Next navigation and arrow key support
# - Uses shared assets/style.css and assets/script.js
# ---------------------------------------------------------

$sitemapUrl = "https://grothadventures.com/sitemap.xml"
$baseDir = "$PSScriptRoot\grothadventures_book"
$assetsDir = Join-Path $baseDir "assets"
$missingImagesLog = Join-Path $baseDir "missing_images.log"

if (-Not (Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir | Out-Null }
if (-Not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir | Out-Null }

function Sanitize-FileName {
    param($name)
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    return ($name -replace "[$invalidChars]", "_")
}

Write-Host "Downloading sitemap..."
try {
    $sitemapContent = Invoke-WebRequest -Uri $sitemapUrl -UseBasicParsing
    $sitemapXml = [xml]$sitemapContent.Content
    $sitemapUrls = $sitemapXml.urlset.url.loc
} catch {
    Write-Host "Error downloading sitemap: $($_.Exception.Message)"
    $sitemapUrls = @()
}

$allUrls = @($sitemapUrls)

# Scrape older archives (2004–2012)
function Get-YearArchivePosts {
    param($year)
    $yearUrls = @()
    $pageNum = 1
    while ($true) {
        $pageUrl = if ($pageNum -eq 1) {
            "https://grothadventures.com/$year/"
        } else {
            "https://grothadventures.com/$year/page/$pageNum/"
        }
        try {
            $pageContent = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing
        } catch {
            break
        }
        $matches = [regex]::Matches($pageContent.Content, 'https://grothadventures\.com/\d{4}/\d{2}/\d{2}/[a-z0-9\-]+/', 'IgnoreCase')
        if ($matches.Count -eq 0) { break }
        $yearUrls += ($matches.Value | Sort-Object -Unique)
        $pageNum++
    }
    return $yearUrls | Sort-Object -Unique
}

foreach ($y in 2004..2012) {
    Write-Host "Scraping archive for $y..."
    $olderPosts = Get-YearArchivePosts $y
    $allUrls += $olderPosts
}

# Group URLs by year
$postsByYear = @{}
foreach ($url in $allUrls | Sort-Object -Unique) {
    if ($url -match "/(\d{4})/") { $year = $matches[1] } else { $year = "unknown" }
    if (-not $postsByYear.ContainsKey($year)) { $postsByYear[$year] = @() }
    $postsByYear[$year] += $url
}

# Pre-filled topics
$topics = @(
    # Cities
    "Seattle","Madrid","Lisbon","Amsterdam","London","Paris","Rome","Tokyo","Kyoto","Florence","Venice",
    "Barcelona","Dublin","Edinburgh","Sydney","Melbourne","Vancouver","Prague","Budapest","Vienna","Berlin",
    "Munich","Geneva","Zurich","Istanbul","Athens",
    # People
    "Brian","Lorie","Anne","Mom","Dad","Uncle","Aunt","Chris","Steve","Karen","John","Mary",
    # Pets
    "Ripley","Theo","Milo","Busby","Piper","Sam","Coco","Charlie","Max","Bella"
)

$topicMatches = @{}
$yearLinks = @()

$totalPosts = ($postsByYear.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
$currentPost = 0
$missingImageCount = 0

foreach ($year in $postsByYear.Keys | Sort-Object -Descending) {
    $yearDir = Join-Path $baseDir $year
    if (-Not (Test-Path $yearDir)) { New-Item -ItemType Directory -Path $yearDir | Out-Null }

    $yearPostData = @()

    $postIndex = 0
    foreach ($url in ($postsByYear[$year] | Sort-Object)) {
        $postIndex++
        $currentPost++
        $fileName = Sanitize-FileName(($url.TrimEnd('/').Split('/')[-1] + ".html"))
        $outputPath = Join-Path $yearDir $fileName

        $title = ""
        $date = ""

        if (-Not (Test-Path $outputPath)) {
            Write-Host "[$postIndex/$($postsByYear[$year].Count)] Downloading: $url"
            try {
                $page = Invoke-WebRequest -Uri $url -UseBasicParsing
                $htmlContent = $page.Content

                # Extract <article>
                if ($htmlContent -match '<article.*?</article>') {
                    $articleHtml = [regex]::Match($htmlContent, '<article.*?</article>', 'Singleline').Value
                } else { $articleHtml = $htmlContent }

                # Title
                $titleMatch = [regex]::Match($articleHtml, '<h1[^>]*>(.*?)</h1>', 'Singleline')
                $title = $titleMatch.Groups[1].Value -replace '\s*[-|]\s*Groth Adventures.*$', ''
                $title = $title.Trim()

                # Date from URL
                if ($url -match "/(\d{4})/(\d{2})/(\d{2})/") {
                    $date = "$($matches[1])-$($matches[2])-$($matches[3])"
                }

                # Strip extras
                $articleHtml = [regex]::Replace($articleHtml, '<(section|div)[^>]*(id|class)="[^"]*archives[^"]*"[^>]*>.*?</\1>', '', 'Singleline,IgnoreCase')
                $articleHtml = [regex]::Replace($articleHtml, '<(aside|div)[^>]*(id|class)="[^"]*(sidebar|widget)[^"]*"[^>]*>.*?</\1>', '', 'Singleline,IgnoreCase')
                $articleHtml = [regex]::Replace($articleHtml, '<div id="jp-post-flair".*$', '', 'Singleline,IgnoreCase')
                $articleHtml = [regex]::Replace($articleHtml, '<script.*?</script>', '', 'Singleline,IgnoreCase')

                # Download images
                $imageUrls = Select-String -InputObject $articleHtml -Pattern '<img[^>]+src="([^"]+)"' -AllMatches |
                             ForEach-Object { $_.Matches.Groups[1].Value } | Sort-Object -Unique
                foreach ($imgUrl in $imageUrls) {
                    $finalUrl = $imgUrl
                    if ($finalUrl.StartsWith("/")) { $finalUrl = "https://grothadventures.com$finalUrl" }
                    $imgFileName = Sanitize-FileName ([System.IO.Path]::GetFileName($finalUrl))
                    $imgLocalPath = Join-Path $yearDir $imgFileName
                    if (-Not (Test-Path $imgLocalPath)) {
                        try {
                            Invoke-WebRequest -Uri $finalUrl -OutFile $imgLocalPath -UseBasicParsing
                        } catch {
                            if ($imgFileName -match '-\d+x\d+(\.\w+)$') {
                                $fullSizeUrl = $finalUrl -replace '-\d+x\d+(\.\w+)$', '$1'
                                try {
                                    Invoke-WebRequest -Uri $fullSizeUrl -OutFile $imgLocalPath -UseBasicParsing
                                } catch {
                                    Add-Content -Path $missingImagesLog -Value $finalUrl
                                    $missingImageCount++
                                }
                            } else {
                                Add-Content -Path $missingImagesLog -Value $finalUrl
                                $missingImageCount++
                            }
                        }
                    }
                    $articleHtml = $articleHtml -replace [Regex]::Escape($imgUrl), $imgFileName
                }

                # Save article HTML
                $cleanHtml = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>$title</title>
<link rel="stylesheet" href="../assets/style.css">
<script src="../assets/script.js"></script>
</head>
<body>
<div class="content">
<h1>$title</h1>
<h2 class="date">$date</h2>
<div class="post-content">
$articleHtml
</div>
</div>
</body>
</html>
"@
                Set-Content -Path $outputPath -Value $cleanHtml -Encoding UTF8
            } catch {
                Write-Host "    Failed to download: $url"
            }
        } else {
            # Read existing file for title/date
            $localContent = Get-Content $outputPath -Raw
            $title = [regex]::Match($localContent, '<h1.*?>(.*?)</h1>', 'Singleline').Groups[1].Value.Trim()
            $date = [regex]::Match($localContent, '<h2 class="date">(.*?)</h2>', 'Singleline').Groups[1].Value
        }

        $yearPostData += [pscustomobject]@{
            Title = $title
            Date  = $date
            File  = $fileName
        }

        # Topic matching
        foreach ($topic in $topics) {
            if ($title -match "(?i)\b$topic\b") {
                if (-not $topicMatches.ContainsKey($topic)) { $topicMatches[$topic] = @() }
                $topicMatches[$topic] += [pscustomobject]@{
                    Title   = $title
                    DateStr = $date
                    FileRef = "../$year/$fileName"
                }
            }
        }
    }

    # Separate dated/undated for TOC
    $dated   = $yearPostData | Where-Object { $_.Date -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object @{Expression={ [datetime]$_.Date }; Ascending=$true}
    $undated = $yearPostData | Where-Object { -not ($_.Date -match '^\d{4}-\d{2}-\d{2}$') } | Sort-Object Title

    $tocEntries = @()
    $tocEntries += $dated   | ForEach-Object { "<li>$($_.Date) - <a href='$($_.File)'>$($_.Title)</a></li>" }
    $tocEntries += $undated | ForEach-Object { "<li><a href='$($_.File)'>$($_.Title)</a></li>" }

    $tocHtml = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>$year Adventures</title>
<link rel="stylesheet" href="../assets/style.css">
<script src="../assets/script.js"></script>
</head>
<body>
<div class="content">
<h1>$year Adventures</h1>
<ul>
$($tocEntries -join "`r`n")
</ul>
<a href="../index.html" class="back-link">← Back to All Years Index</a>
</div>
</body>
</html>
"@
    Set-Content -Path (Join-Path $yearDir "TOC.html") -Value $tocHtml -Encoding UTF8
    $yearLinks += "<li><a href='$year/TOC.html'>$year Adventures</a></li>"
}

# Topic TOCs: dated first, undated after
$topicLinks = @()
foreach ($topic in ($topicMatches.Keys | Sort-Object)) {
    $topicDir = Join-Path $baseDir "topics"
    if (-Not (Test-Path $topicDir)) { New-Item -ItemType Directory -Path $topicDir | Out-Null }
    $dated   = $topicMatches[$topic] | Where-Object { $_.DateStr -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object @{Expression={ [datetime]$_.DateStr }; Ascending=$true}
    $undated = $topicMatches[$topic] | Where-Object { -not ($_.DateStr -match '^\d{4}-\d{2}-\d{2}$') } | Sort-Object Title

    $sortedLinks = @()
    $sortedLinks += $dated   | ForEach-Object { "<li>$($_.DateStr) - <a href='$($_.FileRef)'>$($_.Title)</a></li>" }
    $sortedLinks += $undated | ForEach-Object { "<li><a href='$($_.FileRef)'>$($_.Title)</a></li>" }

    $topicHtml = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Topic: $topic</title>
<link rel="stylesheet" href="../assets/style.css">
<script src="../assets/script.js"></script>
</head>
<body>
<div class="content">
<h1>Topic: $topic</h1>
<ul>
$($sortedLinks -join "`r`n")
</ul>
<a href="../index.html" class="back-link">← Back to Index</a>
</div>
</body>
</html>
"@
    Set-Content -Path (Join-Path $topicDir "$topic.html") -Value $topicHtml -Encoding UTF8
    $topicLinks += "<li><a href='topics/$topic.html'>$topic</a></li>"
}

# Main Index
$indexHtml = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Groth Adventures - Index</title>
<link rel="stylesheet" href="assets/style.css">
<script src="assets/script.js"></script>
</head>
<body>
<div class="content">
<h1>Groth Adventures - Index</h1>
<h2>By Year</h2>
<ul>
$($yearLinks -join "`r`n")
</ul>
<h2>By Topic</h2>
<ul>
$($topicLinks -join "`r`n")
</ul>
</div>
</body>
</html>
"@
Set-Content -Path (Join-Path $baseDir "index.html") -Value $indexHtml -Encoding UTF8

# CSS
$cssContent = @"
body { font-family: 'Merriweather', serif; background: #fdf6e3; color: #3e2723; margin: 0; padding: 0; }
.content { max-width: 900px; margin: auto; background: #fffef8; padding: 40px; box-shadow: 0 0 15px rgba(0,0,0,0.2); }
h1, h2 { font-family: 'Playfair Display', serif; }
ul { list-style: none; padding: 0; }
li { margin: 0.5em 0; }
a { color: #336699; text-decoration: none; }
a:hover { text-decoration: underline; }
.back-link { display: inline-block; margin-top: 20px; }
.nav-buttons { display: flex; justify-content: space-between; margin-top: 40px; }
.nav-buttons a { background: #f4e1c1; padding: 10px 20px; border-radius: 5px; }
.nav-buttons a:hover { background: #e2c9a6; }
"@
Set-Content -Path (Join-Path $assetsDir "style.css") -Value $cssContent -Encoding UTF8

# JS
$jsContent = @"
document.addEventListener('keydown', function(e) {
    if (e.key === 'ArrowLeft') {
        let prev = document.querySelector('.nav-buttons .prev');
        if (prev) { window.location.href = prev.href; }
    } else if (e.key === 'ArrowRight') {
        let next = document.querySelector('.nav-buttons .next');
        if (next) { window.location.href = next.href; }
    }
});
"@
Set-Content -Path (Join-Path $assetsDir "script.js") -Value $jsContent -Encoding UTF8

Write-Host "✅ Book build complete. Open $baseDir\index.html to browse."
