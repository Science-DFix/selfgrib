#!/bin/bash
# ==============================================================================
# master_run_selfgrib.bash — Orquestra o experimento selfgrib (Jaci):
#   1) recorte da malha regional               (01_recorta_regiao.bash)
#   2) pipeline meteorológico (selfgrib)        (02_roda_pipeline_meteorologico.bash)
#   3) init_atmosphere_model (gera o init.nc)   (03_roda_init_atmosphere.bash)
#
# Os 3 scripts de etapa em scripts/ têm prefixo numérico (01_, 02_, 03_)
# exatamente para deixar essa ordem óbvia mesmo rodando cada um à mão
# (sem passar pelo master), fora deste orquestrador.
#
# Chamado pelo submete_jaci_selfgrib.pbs (mesmo padrão de
# ../../scripts/master_run.bash + submete_jaci.pbs já usados em produção).
# Cada etapa é idempotente — os scripts individuais pulam o que já existe,
# então reexecutar o master só refaz o que falhou ou ainda não foi feito.
# ==============================================================================

set -euo pipefail

DIR_SELFGRIB="${DIR_SELFGRIB:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/selfgrib}"
DIR_SCRIPTS="${DIR_SELFGRIB}/scripts"

# NP vem do .pbs (export NP=...), como em master_run.bash / submete_jaci.pbs.
export NP_RUN="${NP_RUN:-${NP:-32}}"
export NP_PARTS="${NP_PARTS:-32 64 128 256}"

LOG="${LOG:-${DIR_SELFGRIB}/execucao_selfgrib.log}"

echo "======================================================" | tee -a "$LOG"
echo " selfgrib — experimento de init.nc regional"           | tee -a "$LOG"
echo " Início : $(date)"                                      | tee -a "$LOG"
echo " NP_RUN : ${NP_RUN}"                                     | tee -a "$LOG"
echo "======================================================" | tee -a "$LOG"

echo "--- [1/3] Recorte da malha regional ---" | tee -a "$LOG"
bash "${DIR_SCRIPTS}/01_recorta_regiao.bash" 2>&1 | tee -a "$LOG"

echo "--- [2/3] Pipeline meteorológico (selfgrib) ---" | tee -a "$LOG"
bash "${DIR_SCRIPTS}/02_roda_pipeline_meteorologico.bash" 2>&1 | tee -a "$LOG"

echo "--- [3/3] init_atmosphere_model ---" | tee -a "$LOG"
bash "${DIR_SCRIPTS}/03_roda_init_atmosphere.bash" 2>&1 | tee -a "$LOG"

echo "======================================================" | tee -a "$LOG"
echo " Fim: $(date)"                                           | tee -a "$LOG"
echo "======================================================" | tee -a "$LOG"
