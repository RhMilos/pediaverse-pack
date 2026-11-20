# =====================================================================
#  PédiaVerse - mise à jour du pack joueurs
#  Lance "maj.bat" : ce script prépare le pack et l'envoie sur GitHub.
#  Au prochain lancement, le jeu de tes amis se met à jour tout seul.
# =====================================================================

# ---- Réglages (à modifier si besoin) --------------------------------
$NomPack   = "PédiaVerse"
$Auteur    = "PédiaVerse"
$Minecraft = "1.21.1"
$Fabric    = "0.20.1"
# Dossiers envoyés aux joueurs (ceux qui n'existent pas sont ignorés)
$Dossiers  = @("mods", "config", "resourcepacks", "shaderpacks")
# Fichiers donnés une seule fois (le joueur peut ensuite les changer)
$UneFois   = @("options.txt", "servers.dat")
# ---------------------------------------------------------------------

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Ecrire($chemin, $texte) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot $chemin), $texte, $utf8) }
function Sha256($chemin) { (Get-FileHash -Algorithm SHA256 -LiteralPath $chemin).Hash.ToLower() }
function Sha1($chemin)   { (Get-FileHash -Algorithm SHA1 -LiteralPath $chemin).Hash.ToLower() }
function Q($s) { '"' + (($s -replace '\\', '\\') -replace '"', '\"') + '"' }
function Relatif($full) { $full.Substring($PSScriptRoot.Length + 1).Replace('\', '/') }

Write-Host ""
Write-Host "=== Mise à jour du pack $NomPack ===" -ForegroundColor Cyan

if (-not (Test-Path ".git")) {
    Write-Host "Ce dossier n'est pas relié à GitHub. Suis l'étape 2 du fichier LISEZMOI.txt." -ForegroundColor Red
    exit 1
}

# 1) noms de fichiers sans espace ni accent (sinon le téléchargement peut échouer)
foreach ($d in $Dossiers) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem -LiteralPath $d -Recurse -File | ForEach-Object {
        $propre = ($_.Name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace '[^A-Za-z0-9._+\-]', '_'
        if ($propre -ne $_.Name) {
            Write-Host "  renommé : $($_.Name) -> $propre" -ForegroundColor Yellow
            Rename-Item -LiteralPath $_.FullName -NewName $propre
        }
    }
}

# 2) les mods publiés sur Modrinth sont téléchargés depuis Modrinth (pas besoin de les mettre sur GitHub)
Get-ChildItem -Path "mods" -Filter "*.pw.toml" -File -ErrorAction SilentlyContinue | Remove-Item
$jars = @()
if (Test-Path "mods") { $jars = @(Get-ChildItem -LiteralPath "mods" -Filter "*.jar" -File) }
$sha1 = @{}
foreach ($j in $jars) { $sha1[$j.Name] = Sha1 $j.FullName }
$modrinth = @{}
if ($jars.Count -gt 0) {
    Write-Host "Recherche des mods sur Modrinth..."
    try {
        $body = @{ hashes = @($sha1.Values); algorithm = "sha1" } | ConvertTo-Json
        $rep = Invoke-RestMethod -Method Post -Uri "https://api.modrinth.com/v2/version_files" -Body $body `
            -ContentType "application/json" -Headers @{ "User-Agent" = "PediaVerse-pack/1.0" }
        foreach ($p in $rep.PSObject.Properties) { $modrinth[$p.Name] = $p.Value }
    } catch {
        Write-Host "  Modrinth injoignable : tous les mods seront envoyés sur GitHub." -ForegroundColor Yellow
    }
}

$entrees = New-Object System.Collections.Generic.List[string]
$ignores = New-Object System.Collections.Generic.List[string]
$nbModrinth = 0; $nbGithub = 0

foreach ($j in $jars) {
    $h = $sha1[$j.Name]
    $ver = $modrinth[$h]
    $fichier = $null
    if ($ver) { $fichier = $ver.files | Where-Object { $_.hashes.sha1 -eq $h } | Select-Object -First 1 }
    if ($fichier) {
        $base = [IO.Path]::GetFileNameWithoutExtension($j.Name)
        $meta = "mods/$base.pw.toml"
        $txt = "name = " + (Q $base) + "`n" +
               "filename = " + (Q $j.Name) + "`n" +
               "side = `"both`"`n`n" +
               "[download]`n" +
               "url = " + (Q $fichier.url) + "`n" +
               "hash-format = `"sha1`"`n" +
               "hash = " + (Q $h) + "`n"
        Ecrire $meta $txt
        $entrees.Add("[[files]]`nfile = " + (Q $meta) + "`nhash = " + (Q (Sha256 (Join-Path $PSScriptRoot $meta))) + "`nmetafile = true`n")
        $ignores.Add("mods/" + $j.Name)
        $nbModrinth++
    } else {
        $entrees.Add("[[files]]`nfile = " + (Q ("mods/" + $j.Name)) + "`nhash = " + (Q (Sha256 $j.FullName)) + "`n")
        Write-Host "  sur GitHub : $($j.Name)"
        $nbGithub++
    }
}

# 3) les autres dossiers (config, packs de textures, shaders...)
foreach ($d in $Dossiers) {
    if ($d -eq "mods" -or -not (Test-Path $d)) { continue }
    Get-ChildItem -LiteralPath $d -Recurse -File | ForEach-Object {
        $entrees.Add("[[files]]`nfile = " + (Q (Relatif $_.FullName)) + "`nhash = " + (Q (Sha256 $_.FullName)) + "`n")
    }
}
foreach ($f in $UneFois) {
    if (Test-Path $f) {
        $entrees.Add("[[files]]`nfile = " + (Q $f) + "`nhash = " + (Q (Sha256 (Join-Path $PSScriptRoot $f))) + "`npreserve = true`n")
    }
}

# 4) index.toml puis pack.toml
Ecrire "index.toml" ("hash-format = `"sha256`"`n`n" + ($entrees -join "`n"))
$version = Get-Date -Format "yyyy.MM.dd-HHmm"
Ecrire "pack.toml" ("name = " + (Q $NomPack) + "`nauthor = " + (Q $Auteur) + "`nversion = " + (Q $version) +
    "`npack-format = `"packwiz:1.1.0`"`n`n[index]`nfile = `"index.toml`"`nhash-format = `"sha256`"`nhash = " +
    (Q (Sha256 (Join-Path $PSScriptRoot "index.toml"))) + "`n`n[versions]`nminecraft = " + (Q $Minecraft) +
    "`nfabric = " + (Q $Fabric) + "`n")

# 5) .gitignore : les jars de Modrinth ne partent pas sur GitHub
Ecrire ".gitignore" ("# généré par maj.ps1`n" + ($ignores -join "`n") + "`n")

Write-Host ("Pack prêt : {0} mod(s) depuis Modrinth, {1} fichier(s) de mods sur GitHub, version {2}" -f $nbModrinth, $nbGithub, $version) -ForegroundColor Green

# 6) envoi sur GitHub
$ErrorActionPreference = "Continue"
if (-not (git config user.name)) {
    $n = Read-Host "Ton pseudo GitHub (une seule fois)"
    $m = Read-Host "Ton e-mail GitHub (une seule fois)"
    git config --global user.name $n
    git config --global user.email $m
}
git rm -r -q --cached --ignore-unmatch mods 2>$null | Out-Null
git add -A
git commit -q -m "Pack $version"
git push
if ($LASTEXITCODE -ne 0) {
    Write-Host "L'envoi sur GitHub a échoué (voir le message au-dessus)." -ForegroundColor Red
    exit 1
}

$url = (git remote get-url origin) -replace '\.git$', ''
$branche = git rev-parse --abbrev-ref HEAD
$raw = $url -replace '^https://github\.com/', 'https://raw.githubusercontent.com/'
Write-Host ""
Write-Host "C'est en ligne ! Adresse du pack (à mettre dans Prism) :" -ForegroundColor Green
Write-Host "  $raw/$branche/pack.toml" -ForegroundColor White
Write-Host "Tes amis auront la mise à jour à leur prochain lancement (compte jusqu'à 5 min le temps que GitHub la diffuse)."
