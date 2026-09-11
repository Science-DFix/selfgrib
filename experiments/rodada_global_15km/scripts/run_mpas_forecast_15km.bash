#!/bin/bash
# ==============================================================================
# run_mpas_forecast_15km.bash — Previsao MPAS-A (malha global 15km)
# Cluster: Jaci (CPTEC/INPE)
# Chamado por: master_run_15km.bash
#
# Adaptado de scripts/run_mpas_forecast.bash (malha 60km) para a malha global
# 15km (x1.2621442). Entrada e saida deste experimento ficam exclusivamente
# em rodada_global_15km/.
# ==============================================================================

MESH="${MESH:-x1.2621442}"

# --- Caminhos fixos (ajuste DIR_ROOT/DIR_BASE para o seu ambiente) ---
DIR_ROOT="${DIR_ROOT:-/lustre/projetos/satdas/diego_workdir}"
DIR_BASE="${DIR_BASE:-${DIR_ROOT}/SOURCE/rodada_global_15km}"
DIR_DATAOUT="${DIR_DATAOUT:-${DIR_BASE}/forecast}"
DIR_DATAIN_MPAS="${DIR_DATAIN_MPAS:-${DIR_BASE}/init}"
DIR_GRID="${DIR_GRID:-${DIR_BASE}/grid}"
DIR_INVARIANT="${DIR_INVARIANT:-${DIR_BASE}/invariant}"
FILE_BASE_15KM="${FILE_BASE_15KM:-${DIR_BASE}/FILE_BASE_15km}"

# DIR_EXE, DIR_PHYSICS e PRECISION vem do master_run_15km.bash
DIR_EXE=${DIR_EXE:-"${DIR_ROOT}/build-mpich/bin"}
DIR_PHYSICS=${DIR_PHYSICS:-"${DIR_ROOT}/build-mpich/_deps/mpas_data-src/atmosphere/physics_wrf/files"}
PRECISION=${PRECISION:-"double"}

# --- Parametros do master (com defaults) ---
RUN_DURATION=${RUN_DURATION:-"1_00:00:00"}
OUTPUT_INTERVAL=${OUTPUT_INTERVAL:-"03:00:00"}
DIAG_INTERVAL=${DIAG_INTERVAL:-"03:00:00"}
DT=${DT:-"90"}
RADT_INTERVAL=${RADT_INTERVAL:-"00:30:00"}
SST_UPDATE=${SST_UPDATE:-"false"}
IAU_OPTION=${IAU_OPTION:-"off"}

# --- Ambiente ---
ENV_ALL="${ENV_ALL:-${DIR_ROOT}/env_wrf_wps.bash}"
source "$ENV_ALL"

# --- Validacao ---
if [ -z "$TIMESTAMP" ]; then
    echo "ERRO: TIMESTAMP nao definido."
    exit 1
fi

ano=${TIMESTAMP:0:4}
mes=${TIMESTAMP:4:2}
dia=${TIMESTAMP:6:2}
hora=${TIMESTAMP:8:2}
start_date="${ano}-${mes}-${dia}_${hora}:00:00"

WORK_DIR="${DIR_DATAOUT}/${TIMESTAMP}"
NP_RUN=${NP:-256}

echo "--- Forecast 15km [${PRECISION}]: $TIMESTAMP | ${start_date} | ${RUN_DURATION} | IAU=${IAU_OPTION} ---"

# --- Verificacoes ---
if [ ! -f "${DIR_DATAIN_MPAS}/${TIMESTAMP}/${MESH}.init.nc" ]; then
    echo "ERRO: init.nc nao encontrado em ${DIR_DATAIN_MPAS}/${TIMESTAMP}"
    echo "Execute o run_mpas_atmosphere_15km.bash primeiro."
    exit 1
fi

if [ ! -f "${DIR_INVARIANT}/${MESH}.invariant.nc" ]; then
    echo "ERRO: invariant.nc nao encontrado em ${DIR_INVARIANT}"
    echo "Execute o job_invariant_15km.sh primeiro (gera o invariant a partir do static.nc)."
    exit 1
fi

if [ ! -f "${DIR_EXE}/mpas_atmosphere" ]; then
    echo "ERRO: mpas_atmosphere nao encontrado em ${DIR_EXE}"
    exit 1
fi

mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || exit 1

# --- Links ---
ln -sf "${DIR_DATAIN_MPAS}/${TIMESTAMP}/${MESH}.init.nc" .
ln -sf "${DIR_EXE}/mpas_atmosphere" .
ln -sf "${DIR_GRID}/${MESH}.graph.info.part.${NP_RUN}" .
ln -sf "${DIR_INVARIANT}/${MESH}.invariant.nc" invariant.nc

for f in "${DIR_PHYSICS}"/*.TBL "${DIR_PHYSICS}"/*.DBL \
          "${DIR_PHYSICS}"/*DATA "${DIR_PHYSICS}"/VERSION \
          "${DIR_PHYSICS}"/COMPATIBILITY; do
    [ -e "$f" ] && ln -sf "$f" ./
done

if [ "${PRECISION}" = "single" ]; then
    ln -sf "${DIR_PHYSICS}/RRTMG_SW_DATA"     ./RRTMG_SW_DATA
    ln -sf "${DIR_PHYSICS}/RRTMG_LW_DATA"     ./RRTMG_LW_DATA
else
    ln -sf "${DIR_PHYSICS}/RRTMG_SW_DATA.DBL" ./RRTMG_SW_DATA
    ln -sf "${DIR_PHYSICS}/RRTMG_LW_DATA.DBL" ./RRTMG_LW_DATA
fi

# --- IAU ---
if [ "${IAU_OPTION}" = "on" ]; then
    IAU_FILE="${DIR_DATAIN_MPAS}/${TIMESTAMP}/${MESH}.AmB.${ano}-${mes}-${dia}_${hora}.00.00.nc"
    if [ -f "${IAU_FILE}" ]; then
        ln -sf "${IAU_FILE}" .
        echo "IAU ativado: $(basename ${IAU_FILE})"
    else
        echo "AVISO: IAU_OPTION=on mas arquivo AmB nao encontrado. Desativando IAU."
        IAU_OPTION="off"
    fi
fi

# --- SST ---
if [ "${SST_UPDATE}" = "true" ]; then
    if [ -f "${DIR_DATAIN_MPAS}/${TIMESTAMP}/${MESH}.sfc_update.nc" ]; then
        ln -sf "${DIR_DATAIN_MPAS}/${TIMESTAMP}/${MESH}.sfc_update.nc" .
        echo "SST update ativado"
    else
        echo "AVISO: sfc_update.nc nao encontrado. Desativando SST_UPDATE."
        SST_UPDATE="false"
    fi
fi

# --- Configuracoes ---
cp "${FILE_BASE_15KM}/core_atmosphere/namelist.atmosphere" .
cp "${FILE_BASE_15KM}/core_atmosphere/streams.atmosphere" .
cp "${FILE_BASE_15KM}/core_atmosphere/stream_list.atmosphere."* .

sed -i -E "s|config_start_time\s*=\s*'[^']*'|config_start_time = '${start_date}'|"              namelist.atmosphere
sed -i -E "s|config_run_duration\s*=\s*'[^']*'|config_run_duration = '${RUN_DURATION}'|"        namelist.atmosphere
sed -i -E "s|config_dt\s*=\s*[0-9.]+|config_dt = ${DT}.0|"                                      namelist.atmosphere
sed -i -E "s|config_radtlw_interval\s*=\s*'[^']*'|config_radtlw_interval = '${RADT_INTERVAL}'|" namelist.atmosphere
sed -i -E "s|config_radtsw_interval\s*=\s*'[^']*'|config_radtsw_interval = '${RADT_INTERVAL}'|" namelist.atmosphere
sed -i -E "s|config_sst_update\s*=\s*\S+|config_sst_update = ${SST_UPDATE}|"                    namelist.atmosphere
sed -i -E "s|config_IAU_option\s*=\s*'[^']*'|config_IAU_option = '${IAU_OPTION}'|"              namelist.atmosphere

sed -i "/history\.\$Y/,/output_interval/ s|output_interval=\"[^\"]*\"|output_interval=\"${OUTPUT_INTERVAL}\"|" streams.atmosphere
sed -i "/diag\.\$Y/,/output_interval/ s|output_interval=\"[^\"]*\"|output_interval=\"${DIAG_INTERVAL}\"|"      streams.atmosphere
sed -i "/da_state/,/output_interval/ s|output_interval=\"[^\"]*\"|output_interval=\"${OUTPUT_INTERVAL}\"|"      streams.atmosphere

if [ "${SST_UPDATE}" = "true" ]; then
    sed -i "/sfc_update/,/input_interval/ s|input_interval=\"none\"|input_interval=\"24:00:00\"|" streams.atmosphere
fi

# --- Execucao ---
ulimit -s unlimited
export GFORTRAN_CONVERT_UNIT='big_endian:101-200'
echo "Rodando mpas_atmosphere [${PRECISION}] com ${NP_RUN} processos..."
mpiexec -n ${NP_RUN} -iface hsn0 -bind-to core -launcher fork ./mpas_atmosphere

if [ $? -eq 0 ]; then
    echo "--- Forecast SUCESSO: $TIMESTAMP [${PRECISION}] ---"
    ls -lh history.*.nc diag.*.nc mpasout.*.nc 2>/dev/null | awk '{print "  "$NF, $5}'
    exit 0
else
    echo "--- Forecast ERRO: $TIMESTAMP [${PRECISION}] ---"
    tail -20 log.atmosphere.0000.err 2>/dev/null
    exit 1
fi
