#!/usr/bin/env bash
# Baixa os arquivos abertos de CNPJ da RFB (Nextcloud público via WebDAV) de forma GENTIL.
# - Cooldown inicial (evita rate-limit acumulado).
# - Probe leve único antes de baixar; se o servidor estiver fora (500/429), espera e re-probe.
# - Download SEQUENCIAL, 1 conexão por vez, com pausa entre arquivos.
# - Resumível (curl -C -) e idempotente (pode reexecutar).
# Uso: bash src/download_rfb.sh   (recomendado em background)
set -uo pipefail

TOKEN="gn672Ad4CF8N6TK"
REMOTE_DIR="Dados/Cadastros/CNPJ/2026-07"
BASE="https://arquivos.receitafederal.gov.br/public.php/webdav/${REMOTE_DIR}"
DEST="./raw-data"
LOG="${DEST}/download.log"

COOLDOWN=${COOLDOWN:-1800}    # espera inicial (s) — default 30 min
PROBE_WAIT=300                # espera entre probes quando servidor fora (s)
POLITE_GAP=15                # pausa entre arquivos baixados com sucesso (s)
FILE_BACKOFF=300             # recuo quando um arquivo falha (s)
MAX_HOURS=12                 # limite de parede total

mkdir -p "$DEST"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

FILES=( Cnaes.zip Motivos.zip Municipios.zip Naturezas.zip Paises.zip Qualificacoes.zip Simples.zip )
for i in $(seq 0 9); do FILES+=( "Empresas${i}.zip" "Estabelecimentos${i}.zip" "Socios${i}.zip" ); done

is_ok() { [ -f "$1" ] && [ "$(head -c2 "$1" 2>/dev/null)" = "PK" ]; }

# probe leve: 1 range GET de 1 byte no menor arquivo; 200/206 = servidor OK
probe() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 --connect-timeout 30 \
         -u "${TOKEN}:" "${BASE}/Cnaes.zip")
  [ "$code" = "200" ] || [ "$code" = "206" ]
}

log "==== Downloader GENTIL RFB 2026-07 (${#FILES[@]} arquivos) ===="
log "Cooldown inicial de ${COOLDOWN}s antes de qualquer requisição..."
sleep "$COOLDOWN"

DEADLINE=$(( $(date +%s) + MAX_HOURS*3600 ))

# 1) espera o servidor responder (probe leve, 1 req a cada PROBE_WAIT)
until probe; do
  [ "$(date +%s)" -ge "$DEADLINE" ] && { log "Limite atingido esperando o servidor."; log "DOWNLOAD_FAILED"; exit 1; }
  log "Servidor indisponível (probe). Nova tentativa em ${PROBE_WAIT}s..."
  sleep "$PROBE_WAIT"
done
log "Servidor respondeu ao probe. Iniciando downloads sequenciais."

# 2) baixa 1 arquivo por vez, com pausa; recua em falha
for fname in "${FILES[@]}"; do
  out="${DEST}/${fname}"
  while :; do
    [ "$(date +%s)" -ge "$DEADLINE" ] && { log "Limite de ${MAX_HOURS}h atingido."; log "DOWNLOAD_FAILED"; exit 1; }
    is_ok "$out" && { log "OK (já existe): ${fname}"; break; }
    log "Baixando ${fname}..."
    if curl -f -sS -C - --retry 2 --retry-delay 15 --connect-timeout 30 \
            -u "${TOKEN}:" "${BASE}/${fname}" -o "$out" && is_ok "$out"; then
      log "CONCLUÍDO ${fname} ($(stat -c%s "$out") bytes)"
      sleep "$POLITE_GAP"
      break
    fi
    [ -f "$out" ] && ! is_ok "$out" && rm -f "$out"   # descarta corpo de erro
    log "  Falha em ${fname}; recuando ${FILE_BACKOFF}s antes de tentar de novo..."
    sleep "$FILE_BACKOFF"
  done
done

COUNT=$(ls -1 "$DEST"/*.zip 2>/dev/null | wc -l)
log "==== Concluído: ${COUNT}/${#FILES[@]} zips, $(du -sh "$DEST" | cut -f1) ===="
[ "$COUNT" -eq "${#FILES[@]}" ] && { log "DOWNLOAD_OK"; exit 0; } || { log "DOWNLOAD_FAILED"; exit 1; }
