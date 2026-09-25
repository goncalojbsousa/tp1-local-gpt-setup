#!/usr/bin/env bash
# PrivateGPT em http://localhost:8080/ui
# uso: bash privategpt.sh [stop]
set -euo pipefail
SCRIPT=privategpt

msg() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
err() { printf '\nErro: %s\n' "$*" >&2; exit 1; }

BASE=https://raw.githubusercontent.com/goncalojbsousa/tp1-local-gpt-setup/main
case "$(uname -s)" in
  Linux) ;;
  Darwin) err "isto é para Linux. No Mac usa: bash <(curl -fsSL $BASE/mac/$SCRIPT.sh)" ;;
  *) err "isto é para Linux. No Windows usa o PowerShell: irm $BASE/windows/$SCRIPT.ps1 | iex" ;;
esac

[[ $EUID -eq 0 ]] && err "não corras como root nem com sudo, o script pede a password quando precisar"
command -v sudo >/dev/null || err "sudo não está instalado"

. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *fedora*|*rhel*|*centos*) PKG=dnf ;;
  *debian*|*ubuntu*)        PKG=apt ;;
  *) err "distribuição não suportada: ${PRETTY_NAME:-desconhecida}" ;;
esac

ensure_pkg() {
  command -v "$1" >/dev/null 2>&1 && return
  msg "a instalar $2"
  if [[ $PKG == dnf ]]; then
    sudo dnf install -y "$2"
  else
    sudo apt-get update && sudo apt-get install -y "$2"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "docker já instalado"
  else
    msg "a instalar o docker"
    curl -fsSL https://get.docker.com | sudo sh
  fi
  sudo systemctl enable --now docker
  id -nG "$USER" | grep -qw docker || sudo usermod -aG docker "$USER"
  for _ in $(seq 1 20); do sudo docker info >/dev/null 2>&1 && break; sleep 1; done
  # o grupo docker só vale depois de novo login, até lá usa sudo
  if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
}

ensure_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    echo "ollama já instalado"
  else
    msg "a instalar o ollama"
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  sudo systemctl enable --now ollama 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -fs http://localhost:11434/api/tags >/dev/null 2>&1 && return
    sleep 1
  done
  err "o ollama não respondeu em localhost:11434 (sudo systemctl status ollama)"
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
      command -v xdg-open >/dev/null 2>&1 && xdg-open "$1" >/dev/null 2>&1 &
      return
    fi
    sleep 1
  done
  echo "ainda não respondeu, tenta abrir $1 daqui a pouco. logs: $3"
}

NAME=privategpt
MODEL=qwen3.5:4b
OLLAMA_URL=http://localhost:11434/v1

if [[ ${1:-} == stop ]]; then
  DOCKER=docker; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
  $DOCKER stop "$NAME"; exit
fi

ensure_pkg curl curl
ensure_docker
ensure_ollama
ensure_model "$MODEL"
ensure_model mxbai-embed-large

# network host para o contentor chegar ao ollama em localhost
ensure_container "$NAME" --network host \
  -e OPENAI_API_BASE="$OLLAMA_URL" \
  -e OPENAI_EMBEDDING_API_BASE="$OLLAMA_URL" \
  -v privategpt-data:/home/worker/app/local_data \
  zylonai/private-gpt:latest

open_when_ready "http://localhost:8080/ui" 240 "docker logs -f $NAME"
