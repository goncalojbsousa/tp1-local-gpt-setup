#!/usr/bin/env bash
# LocalGPT em http://localhost:3000 (Mac)
# uso: bash localgpt.sh [stop]
set -euo pipefail
SCRIPT=localgpt

msg() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
err() { printf '\nErro: %s\n' "$*" >&2; exit 1; }

BASE=https://raw.githubusercontent.com/goncalojbsousa/tp1-local-gpt-setup/main
case "$(uname -s)" in
  Darwin) ;;
  Linux) err "isto é para Mac. No Linux usa: bash <(curl -fsSL $BASE/linux/$SCRIPT.sh)" ;;
  *) err "isto é para Mac. No Windows usa o PowerShell: irm $BASE/windows/$SCRIPT.ps1 | iex" ;;
esac

[[ $EUID -eq 0 ]] && err "não corras como root nem com sudo, o script pede a password quando precisar"

export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"

load_brew() {
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x $b ]]; then eval "$($b shellenv)"; return; fi
  done
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 || load_brew
  if command -v brew >/dev/null 2>&1; then
    echo "homebrew já instalado"
    return
  fi
  msg "a instalar o homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew
  command -v brew >/dev/null 2>&1 || err "o homebrew não ficou disponível, fecha e abre o terminal e tenta outra vez"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 && [[ ! -d /Applications/Docker.app ]]; then
    msg "a instalar o docker desktop"
    brew install --cask docker-desktop || brew install --cask docker
  fi
  if ! docker info >/dev/null 2>&1; then
    msg "a arrancar o docker desktop"
    open -a Docker
    echo "se aparecer uma janela do docker, aceita os termos e escreve a password do mac"
    for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 2; done
  fi
  docker info >/dev/null 2>&1 || err "o docker não arrancou. abre o Docker Desktop, aceita os termos e corre o comando outra vez"
  DOCKER=docker
}

ensure_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    echo "ollama já instalado"
  else
    msg "a instalar o ollama"
    brew install ollama
  fi
  if ! curl -fs http://localhost:11434/api/tags >/dev/null 2>&1; then
    brew services start ollama >/dev/null 2>&1 || { nohup ollama serve >/dev/null 2>&1 & }
  fi
  for _ in $(seq 1 30); do
    curl -fs http://localhost:11434/api/tags >/dev/null 2>&1 && return
    sleep 1
  done
  err "o ollama não respondeu em localhost:11434"
}

ensure_model() {
  if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -Eqx "${1}(:latest)?"; then
    echo "modelo $1 já existe"
  else
    msg "a descarregar $1"
    ollama pull "$1"
  fi
}

ensure_container() {
  local name=$1; shift
  if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$name"; then
    $DOCKER start "$name" >/dev/null && echo "contentor $name arrancado"
  else
    msg "a criar o contentor $name"
    $DOCKER run -d --name "$name" --restart unless-stopped "$@"
  fi
}

open_when_ready() {
  echo "a esperar por $1"
  for _ in $(seq 1 "$2"); do
    if curl -fs -o /dev/null "$1"; then
      echo "pronto: $1"
      open "$1" >/dev/null 2>&1 &
      return
    fi
    sleep 1
  done
  echo "ainda não respondeu, tenta abrir $1 daqui a pouco. logs: $3"
}

DEST=$HOME/localGPT
MODEL=qwen3.5:4b

if [[ ${1:-} == stop ]]; then
  [[ -x $DEST/start-docker.sh ]] || err "LocalGPT não está instalado em $DEST"
  cd "$DEST" && ./start-docker.sh stop; exit
fi

ensure_brew
ensure_docker

if [[ -d $DEST/.git ]]; then
  echo "repositório já existe em $DEST"
else
  msg "a clonar o LocalGPT"
  git clone https://github.com/PromtEngineer/localGPT.git "$DEST"
fi
if [[ ! -f $DEST/start-docker.sh ]]; then
  git -C "$DEST" fetch origin localgpt-v2 && git -C "$DEST" checkout localgpt-v2
fi
[[ -f $DEST/start-docker.sh ]] || err "start-docker.sh não encontrado"
chmod +x "$DEST/start-docker.sh"

# o docker.env do projeto usa modelos maiores, aqui usa-se o mesmo modelo em tudo
sed -i.bak "s|^GENERATION_MODEL=.*|GENERATION_MODEL=$MODEL|; s|^ENRICHMENT_MODEL=.*|ENRICHMENT_MODEL=$MODEL|" "$DEST/docker.env"
rm -f "$DEST/docker.env.bak"

ensure_ollama
ensure_model "$MODEL"
ensure_model mxbai-embed-large

msg "a construir e arrancar (na primeira vez demora vários minutos)"
cd "$DEST"
./start-docker.sh local
open_when_ready "http://localhost:3000" 300 "cd $DEST && docker compose logs -f"
