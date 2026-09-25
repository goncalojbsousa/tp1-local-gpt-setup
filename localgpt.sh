#!/usr/bin/env bash
# LocalGPT em http://localhost:3000
# uso: bash localgpt.sh [stop]
set -euo pipefail

msg() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
err() { printf '\nErro: %s\n' "$*" >&2; exit 1; }

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

DEST=$HOME/localGPT
MODEL=qwen3.5:4b

if [[ ${1:-} == stop ]]; then
  [[ -x $DEST/start-docker.sh ]] || err "LocalGPT não está instalado em $DEST"
  cd "$DEST"
  if docker info >/dev/null 2>&1; then ./start-docker.sh stop; else sudo ./start-docker.sh stop; fi
  exit
fi

ensure_pkg curl curl
ensure_pkg git git
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
sed -i "s|^GENERATION_MODEL=.*|GENERATION_MODEL=$MODEL|; s|^ENRICHMENT_MODEL=.*|ENRICHMENT_MODEL=$MODEL|" "$DEST/docker.env"

ensure_ollama
# por defeito o ollama só aceita 127.0.0.1 e os contentores não lhe chegam
OVERRIDE=/etc/systemd/system/ollama.service.d/override.conf
if [[ ! -f $OVERRIDE ]]; then
  sudo mkdir -p "$(dirname "$OVERRIDE")"
  printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | sudo tee "$OVERRIDE" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart ollama
  ensure_ollama
fi
ensure_model "$MODEL"
ensure_model mxbai-embed-large

msg "a construir e arrancar (na primeira vez demora vários minutos)"
cd "$DEST"
if [[ $DOCKER == docker ]]; then ./start-docker.sh local; else sudo ./start-docker.sh local; fi
open_when_ready "http://localhost:3000" 300 "cd $DEST && docker compose logs -f"
