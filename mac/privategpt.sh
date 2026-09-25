#!/usr/bin/env bash
# PrivateGPT em http://localhost:8080/ui (Mac)
# uso: bash privategpt.sh [stop]
set -euo pipefail
SCRIPT=privategpt

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

NAME=privategpt
MODEL=qwen3.5:4b
OLLAMA_URL=http://host.docker.internal:11434/v1

if [[ ${1:-} == stop ]]; then
  docker stop "$NAME"; exit
fi

ensure_brew
ensure_docker
ensure_ollama
ensure_model "$MODEL"
ensure_model mxbai-embed-large

ensure_container "$NAME" -p 8080:8080 \
  --add-host=host.docker.internal:host-gateway \
  -e OPENAI_API_BASE="$OLLAMA_URL" \
  -e OPENAI_EMBEDDING_API_BASE="$OLLAMA_URL" \
  -v privategpt-data:/home/worker/app/local_data \
  zylonai/private-gpt:latest

open_when_ready "http://localhost:8080/ui" 240 "docker logs -f $NAME"
