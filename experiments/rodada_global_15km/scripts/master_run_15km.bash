#!/bin/bash
# ==============================================================================
# MASTER RUN SCRIPT 15km - MPAS-A (Init + Forecast), malha global x1.2621442
# Cluster: Jaci (CPTEC/INPE)
# Chamado por: submete_jaci_15km.pbs
#
# Adaptado de scripts/master_run.bash (malha 60km) para gerar uma previsao
# global de 24h na malha 15km ja baixada em rodada_global_15km/. Toda
# entrada/saida deste experimento (grid, static, invariant, init, forecast)
# fica exclusivamente dentro de rodada_global_15km/.
# ==============================================================================

# --- 1. Processamento (vem do PBS via export) ---
# 256 = todos os cores fisicos de 1 no do Jaci (ian05). NUNCA usar select=2
# com MPICH no Jaci (falha SSH inter-no) - ver Mpich_hydra_jaci_optimization.MD
export NP=${NP:-256}

# --- 2. PRECISAO: "single" ou "double" ---
export PRECISION="single"

# --- 3. Diretorios de build conforme precisao (ajuste para o seu ambiente) ---
DIR_ROOT="${DIR_ROOT:-/lustre/projetos/satdas/diego_workdir}"
if [ "${PRECISION}" = "single" ]; then
    export DIR_BUILD="${DIR_BUILD_SINGLE:-${DIR_ROOT}/build-mpich-single}"
    export MPAS_DOUBLE_PRECISION="false"
else
    export DIR_BUILD="${DIR_BUILD_DOUBLE:-${DIR_ROOT}/build-mpich}"
    export MPAS_DOUBLE_PRECISION="true"
fi
export DIR_EXE="${DIR_BUILD}/bin"
export DIR_PHYSICS="${DIR_BUILD}/_deps/mpas_data-src/atmosphere/physics_wrf/files"

# --- 4. Configuracoes da Previsao: 24h, malha 15km ---
export RUN_DURATION="1_00:00:00"
export OUTPUT_INTERVAL="03:00:00"
export DIAG_INTERVAL="03:00:00"
# dt[s] ~= 6 * dx[km] (regra pratica MPAS): 60km usava 360s -> 15km usa 90s
export DT="90"
export RADT_INTERVAL="00:30:00"
export SST_UPDATE="true"
export PHYSICS_SUITE="mesoscale_reference"
export IAU_OPTION="off"

# --- 5. Periodo de Rodada ---
# 2026-01-31 00Z: GFS de backup local disponivel (f000..f048, cobre as 24h)
ANOS="2026"
MESES="01"
DIAS="31"
HORAS="00"

# --- 6. Diretorio deste experimento (tudo fica aqui, nada em FILE_BASE/dataout/rodadas) ---
DIR_BASE="${DIR_BASE:-${DIR_ROOT}/SOURCE/rodada_global_15km}"
cd "${DIR_BASE}/scripts" || exit 1

# --- 7. Log central ---
LOG_GERAL="${DIR_BASE}/execucao_total_15km.log"

echo "======================================================" | tee -a $LOG_GERAL
echo " EXPERIMENTO: malha global 15km (x1.2621442)"           | tee -a $LOG_GERAL
echo " PRECISAO   : ${PRECISION}"                              | tee -a $LOG_GERAL
echo " BUILD      : ${DIR_BUILD}"                               | tee -a $LOG_GERAL
echo " NP         : ${NP}"                                      | tee -a $LOG_GERAL
echo " Iniciado   : $(date)"                                    | tee -a $LOG_GERAL
echo "======================================================" | tee -a $LOG_GERAL

# --- 8. Pre-requisito: invariant.nc precisa existir (gerado 1x por malha) ---
if [ ! -f "${DIR_BASE}/invariant/x1.2621442.invariant.nc" ]; then
    echo "ERRO: ${DIR_BASE}/invariant/x1.2621442.invariant.nc nao existe." | tee -a $LOG_GERAL
    echo "Rode antes: qsub ${DIR_BASE}/scripts/job_invariant_15km.sh"      | tee -a $LOG_GERAL
    exit 1
fi

# --- 9. Loop de Execucao ---
for ano in $ANOS; do
    for mes in $MESES; do
        for dia in $DIAS; do
            for hora in $HORAS; do
                export TIMESTAMP="${ano}${mes}${dia}${hora}"
                DIR_INIT="${DIR_BASE}/init/${TIMESTAMP}"
                DIR_FCST="${DIR_BASE}/forecast/${TIMESTAMP}"

                echo "=== INICIANDO CICLO $TIMESTAMP EM $(date) ===" | tee -a $LOG_GERAL

                # --- PASSO 1: INIT ---
                start_init=$(date +%s)
                ./run_mpas_atmosphere_15km.bash
                res_init=$?
                end_init=$(date +%s)
                diff_init=$((end_init - start_init))

                if [ $res_init -eq 0 ]; then
                    echo "Init OK: $((diff_init/60))m $((diff_init%60))s" > "${DIR_INIT}/tempo.log"
                    echo "Precisao: ${PRECISION}" >> "${DIR_INIT}/tempo.log"

                    # --- PASSO 2: FORECAST ---
                    start_fcst=$(date +%s)
                    ./run_mpas_forecast_15km.bash
                    res_fcst=$?
                    end_fcst=$(date +%s)
                    diff_fcst=$((end_fcst - start_fcst))

                    if [ $res_fcst -eq 0 ]; then
                        echo "Forecast OK: $((diff_fcst/60))m $((diff_fcst%60))s" > "${DIR_FCST}/tempo.log"
                        echo "Precisao: ${PRECISION}" >> "${DIR_FCST}/tempo.log"
                        echo "SUCESSO: $TIMESTAMP | Init: ${diff_init}s | Fcst: ${diff_fcst}s" | tee -a $LOG_GERAL
                    else
                        echo "ERRO no Forecast de $TIMESTAMP" | tee -a $LOG_GERAL
                        exit 1
                    fi
                else
                    echo "ERRO no Init de $TIMESTAMP" | tee -a $LOG_GERAL
                    exit 1
                fi

            done
        done
    done
done

echo "=== CONCLUIDO EM $(date) ===" | tee -a $LOG_GERAL
