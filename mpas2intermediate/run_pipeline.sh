#!/bin/bash
# run_pipeline.sh
#
# Orquestra a pipeline completa (extract_fields -> convert_mpas ->
# pack_intermediate) sobre TODOS os arquivos history.*.nc de um diretorio de
# rodada global do MPAS-A, gerando um arquivo intermediario por tempo,
# pronto para o config_met_prefix do init_atmosphere_model.
#
# Idempotente: pula tempos cujo arquivo final ja existe (reprocessamento
# agil - reexecutar so refaz o que falta).
#
# Uso: run_pipeline.sh <dir_rodada_global> <dir_saida> <prefixo> \
#                       <startlat> <endlat> <startlon> <endlon> [nlat] [nlon]
#
# Exemplo:
#   ./run_pipeline.sh /mnt/dados2/dataout/PREV_MPAS/2025122800 \
#                      /tmp/pipeline_out MPAS -60.0 25.0 -90.0 -30.0 170 240

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Caminho do binario convert_mpas (compilado em ../convert_mpas, ver README).
# Sobrescreva via env var CONVERT_MPAS_BIN se estiver em outro lugar.
CONVERT_MPAS_BIN="${CONVERT_MPAS_BIN:-${SCRIPT_DIR}/../convert_mpas/convert_mpas}"

SRC_DIR="$1"
OUT_DIR="$2"
PREFIX="$3"
STARTLAT="$4"
ENDLAT="$5"
STARTLON="$6"
ENDLON="$7"
NLAT="${8:-170}"
NLON="${9:-240}"

[ -x "$CONVERT_MPAS_BIN" ] || { echo "ERRO: convert_mpas não encontrado/executável em $CONVERT_MPAS_BIN (defina CONVERT_MPAS_BIN)"; exit 1; }

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

cp -f "$CONVERT_MPAS_BIN" .

cat > target_domain << EOF
nlat = $NLAT
nlon = $NLON
startlat = $STARTLAT
endlat = $ENDLAT
startlon = $STARTLON
endlon = $ENDLON
EOF

n_ok=0
n_skip=0
n_fail=0
t_start=$(date +%s)

for f in "$SRC_DIR"/history.*.nc; do
    [ -e "$f" ] || continue

    base=$(basename "$f")
    hdate=$(echo "$base" | sed -E 's/^history\.([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2})\..*/\1/')
    outfile="${PREFIX}:${hdate}"

    if [ -f "$outfile" ]; then
        echo "[SKIP] $hdate -- $outfile ja existe"
        n_skip=$((n_skip+1))
        continue
    fi

    echo "[RUN ] $hdate -- fonte: $base"
    t0=$(date +%s)

    if ! "$SCRIPT_DIR/extract_fields" "$f" "extracted_${hdate}.nc" > "log_extract_${hdate}.log" 2>&1; then
        echo "[FAIL] $hdate -- extract_fields (veja log_extract_${hdate}.log)"
        n_fail=$((n_fail+1))
        continue
    fi

    if ! ./convert_mpas "$f" "extracted_${hdate}.nc" > "log_convert_${hdate}.log" 2>&1; then
        echo "[FAIL] $hdate -- convert_mpas (veja log_convert_${hdate}.log)"
        n_fail=$((n_fail+1))
        continue
    fi
    mv -f latlon.nc "latlon_${hdate}.nc"

    if ! "$SCRIPT_DIR/pack_intermediate" "latlon_${hdate}.nc" "${hdate}:00:00" "$PREFIX" > "log_pack_${hdate}.log" 2>&1; then
        echo "[FAIL] $hdate -- pack_intermediate (veja log_pack_${hdate}.log)"
        n_fail=$((n_fail+1))
        continue
    fi

    t1=$(date +%s)
    echo "[ OK ] $hdate -- ${outfile} ($((t1-t0))s)"
    n_ok=$((n_ok+1))

    # limpeza dos intermediarios grandes deste tempo (mantem so o binario final e os logs)
    rm -f "extracted_${hdate}.nc" "latlon_${hdate}.nc"
done

t_end=$(date +%s)
echo ""
echo "===================================================="
echo "OK=$n_ok  SKIP=$n_skip  FAIL=$n_fail  tempo_total=$((t_end-t_start))s"
echo "Saida em: $OUT_DIR"
echo "===================================================="

[ "$n_fail" -eq 0 ]
