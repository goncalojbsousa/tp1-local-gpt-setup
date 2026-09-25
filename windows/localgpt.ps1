# LocalGPT em http://localhost:3000 (Windows)
# corre no PowerShell: irm https://raw.githubusercontent.com/goncalojbsousa/tp1-local-gpt-setup/main/windows/localgpt.ps1 | iex
& {
$Script = "localgpt"
$ErrorActionPreference = "Stop"
$oldEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Base = "https://raw.githubusercontent.com/goncalojbsousa/tp1-local-gpt-setup/main"

function Msg($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }

if ($env:OS -ne "Windows_NT") {
    throw "Isto é para Windows. No Linux usa: bash <(curl -fsSL $Base/linux/$Script.sh)  |  No Mac: bash <(curl -fsSL $Base/mac/$Script.sh)"
}

function Test-Cmd($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Add-PathIfExists($dir) {
    if ((Test-Path $dir) -and ($env:Path -notlike "*$dir*")) { $env:Path += ";$dir" }
}

# corre um programa e falha se o código de saída não for 0
function Native {
    $exe = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $exe @rest; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "Falhou: $exe $($rest -join ' ')" }
}

function Winget-Install($id) {
    if (-not (Test-Cmd winget)) {
        throw "O winget não existe. Atualiza o Windows ou instala o 'App Installer' na Microsoft Store e tenta outra vez."
    }
    winget install -e --id $id --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Falhou a instalação de $id" }
    Update-Path
}

function Test-DockerUp {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { docker info 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false } finally { $ErrorActionPreference = $old }
}

function Ensure-Docker {
    $bin = "$env:ProgramFiles\Docker\Docker\resources\bin"
    Add-PathIfExists $bin
    if (-not (Test-Cmd docker)) {
        Msg "A instalar o Docker Desktop (aceita o pedido de administrador)"
        Winget-Install "Docker.DockerDesktop"
        Add-PathIfExists $bin
    } else {
        Write-Host "docker já instalado"
    }
    if (-not (Test-DockerUp)) {
        Msg "A arrancar o Docker Desktop"
        $exe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $exe) { Start-Process $exe }
        Write-Host "Se aparecer uma janela do Docker, aceita os termos."
        for ($i = 0; $i -lt 90; $i++) {
            if (Test-DockerUp) { return }
            Start-Sleep -Seconds 2
        }
        throw "O Docker não arrancou. Reinicia o PC, abre o Docker Desktop, aceita os termos e corre este comando outra vez."
    }
}

function Test-Ollama {
    try { Invoke-WebRequest "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

function Ensure-Ollama {
    $dir = "$env:LOCALAPPDATA\Programs\Ollama"
    Add-PathIfExists $dir
    if (-not (Test-Cmd ollama)) {
        Msg "A instalar o Ollama"
        Winget-Install "Ollama.Ollama"
        Add-PathIfExists $dir
    } else {
        Write-Host "ollama já instalado"
    }
    if (-not (Test-Ollama)) {
        $app = "$dir\ollama app.exe"
        if (Test-Path $app) { Start-Process $app } else { Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden }
        for ($i = 0; $i -lt 30; $i++) {
            if (Test-Ollama) { return }
            Start-Sleep -Seconds 1
        }
        throw "O Ollama não respondeu em localhost:11434."
    }
}

function Ensure-Model($m) {
    $have = @(& ollama list | Select-Object -Skip 1 | ForEach-Object { ($_ -split "\s+")[0] })
    if (($have -contains $m) -or ($have -contains "${m}:latest")) {
        Write-Host "modelo $m já existe"
    } else {
        Msg "A descarregar $m"
        Native ollama pull $m
    }
}

function Ensure-Container($name, [string[]]$runArgs) {
    $names = @(& docker ps -a --format "{{.Names}}")
    if ($names -contains $name) {
        Native docker start $name
    } else {
        Msg "A criar o contentor $name"
        Native docker run -d --name $name --restart unless-stopped @runArgs
    }
}

function Open-WhenReady($url, $secs) {
    Write-Host "a esperar por $url"
    for ($i = 0; $i -lt $secs; $i += 2) {
        try {
            Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3 | Out-Null
            Write-Host "pronto: $url"
            Start-Process $url
            return
        } catch { Start-Sleep -Seconds 2 }
    }
    Write-Host "ainda não respondeu, tenta abrir $url daqui a pouco."
}

try {
$Dest = Join-Path $HOME "localGPT"
$Model = "qwen3.5:4b"

if (-not (Test-Cmd git)) {
    Add-PathIfExists "$env:ProgramFiles\Git\cmd"
}
if (-not (Test-Cmd git)) {
    Msg "A instalar o git"
    Winget-Install "Git.Git"
    Add-PathIfExists "$env:ProgramFiles\Git\cmd"
}
Ensure-Docker

if (Test-Path "$Dest\.git") {
    Write-Host "repositório já existe em $Dest"
} else {
    Msg "A clonar o LocalGPT"
    # autocrlf=false: senão os ficheiros ficam com CRLF e os contentores falham
    Native git -c core.autocrlf=false clone https://github.com/PromtEngineer/localGPT.git $Dest
}
if (-not (Test-Path "$Dest\docker.env")) {
    Native git -C $Dest fetch origin localgpt-v2
    Native git -C $Dest checkout localgpt-v2
}

# o docker.env do projeto usa modelos maiores, aqui usa-se o mesmo modelo em tudo
$envFile = Join-Path $Dest "docker.env"
$text = [IO.File]::ReadAllText($envFile)
$text = $text -replace "(?m)^GENERATION_MODEL=.*$", "GENERATION_MODEL=$Model"
$text = $text -replace "(?m)^ENRICHMENT_MODEL=.*$", "ENRICHMENT_MODEL=$Model"
[IO.File]::WriteAllText($envFile, $text, (New-Object System.Text.UTF8Encoding($false)))

Ensure-Ollama
Ensure-Model $Model
Ensure-Model "mxbai-embed-large"

Msg "A construir e arrancar (na primeira vez demora vários minutos)"
Push-Location $Dest
try { Native docker compose --env-file docker.env up --build -d } finally { Pop-Location }
Open-WhenReady "http://localhost:3000" 300
} finally {
    [Console]::OutputEncoding = $oldEnc
}
}
