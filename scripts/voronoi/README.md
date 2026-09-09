# Pipeline de interpolação nativa Voronoi — `init.nc`/`lbc.*.nc` sem WPS

Rota alternativa/experimental (branch `feature/interpolacao-nativa-voronoi`)
à `scripts/0{1..5}_*.bash` (produção, validada). Não substitui a rota de
produção — coexiste com ela para comparação. Ver
`mpas2intermediate/README.md` §2.4 e o plano de implementação completo em
`/home/dvar/.claude/plans/cheerful-knitting-platypus.md` (achados,
fórmulas, números de validação, o que ainda não foi testado).

## Ordem de execução

| # | Script | O que faz | Reusa de `scripts/`? |
|---|--------|-----------|----------------------|
| 1 | `scripts/01_recorta_regiao.bash` | Recorta a malha regional (`<REGION>.static.nc`) a partir da malha global, via MPAS-Limited-Area. | **Sim, sem alteração** — geometria pura, não depende de WPS nem da rota de interpolação escolhida depois. |
| 2 | `voronoi/02_extrai_first_guess.bash` | Roda `extract_fields` em cada `history.*.nc` da rodada global (níveis de pressão fixos, ainda na malha nativa global). | Novo (substitui a parte `extract_fields` do `run_pipeline.sh`, mas sem `convert_mpas`/grade lat-lon). |
| 3 | `voronoi/03_interp_horizontal_nativa.bash` | Roda `hinterp_native` pra cada tempo: remapeia os campos extraídos direto pros centros de célula da malha-alvo (baricêntrico, sem grade lat-lon). | Novo. |
| 4 | `voronoi/04_gera_init_native.bash` | Roda `gen_init_native` (Fases 2+3+4+6) pro tempo inicial + mescla com `ncks -A` os campos de cópia direta do `static.nc` → `init.nc` completo (135 variáveis). | Novo (substitui `scripts/03_roda_init_atmosphere.bash` — não chama o `init_atmosphere_model` real pra essa etapa). |
| 5 | `voronoi/05_gera_lbc_native.bash` | Roda `gen_lbc_native` pra cada tempo de fronteira (reusa a malha vertical do `init.nc`, não recalcula) → `lbc.*.nc`. | Novo (substitui `scripts/04_gera_lbc.bash`). |
| 6 | `voronoi/06_roda_previsao_native.bash` | Roda a previsão de verdade (`mpas_atmosphere`) a partir do `init.nc`/`lbc.*.nc` nativos. | Cópia de `scripts/05_roda_previsao.bash` (mesmo namelist/streams/executável/tabelas de física) — só os caminhos de entrada mudam (`init_run_native`/`lbc_run_native`). |

## Variáveis de ambiente principais

Convenção igual à de `scripts/`: tudo configurável via `export` antes de
rodar, com defaults sensatos. As mais importantes (ver cada script para a
lista completa):

- `DIR_VORONOI` — raiz deste clone/checkout no Jaci (default:
  `/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi`).
- `DIR_RODADA_GLOBAL` — rodada global MPAS-A já concluída (mesma
  convenção de `02_roda_pipeline_meteorologico.bash`).
- `REGION_NAME`, `DIR_MALHA` — malha regional recortada pelo passo 1.
- `NAMELIST_INIT` / `NAMELIST_LBC` — `namelist.init_atmosphere` real do
  experimento (init_run e lbc_run — só diferem em `config_start_time`/
  `config_stop_time`/`config_blend_bdy_terrain`, ver `FILE_BASE`). Os
  programas novos (`gen_init_native`/`gen_lbc_native`) LEEM esses
  namelists em tempo de execução (`namelist_config.F90`) — não há
  `config_*` fixo no código, então qualquer malha/experimento com um
  namelist real funciona, não só o caso SouthAmerica usado nos testes.
- `TIMES` — lista dos tempos a processar (`AAAA-MM-DD_HH`, separados por
  espaço) — precisa cobrir o tempo inicial (init.nc) + todos os tempos de
  fronteira (lbc.*.nc) desejados.

## Uso rápido (mesmo caso SouthAmerica já validado)

```bash
export DIR_VORONOI=/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi
export DIR_RODADA_GLOBAL=/lustre/projetos/satdas/diego_workdir/SOURCE/dataout/PREV_MPAS/2026010100
export TIMES="2026-01-01_00 2026-01-01_06 2026-01-01_12 2026-01-01_18 2026-01-02_00"

bash scripts/01_recorta_regiao.bash              # passo 1 (reusa a rota de producao)
bash scripts/voronoi/02_extrai_first_guess.bash
bash scripts/voronoi/03_interp_horizontal_nativa.bash
bash scripts/voronoi/04_gera_init_native.bash    # so' o primeiro tempo de $TIMES
bash scripts/voronoi/05_gera_lbc_native.bash     # todos os tempos de $TIMES
```

## Status (2026-09-09)

**Rodado ponta-a-ponta no Jaci de verdade (passos 1-5)** — tudo OK, rápido
(segundos por passo, Lustre local). `init.nc`: 136/135 variáveis (135 reais
+ 1 extra inofensiva), validado campo-a-campo contra o `init.nc` real —
bate exato/quase-exato em tudo. `lbc.*.nc`: auto-consistência exata
(diff=0 contra o próprio `init.nc` no mesmo tempo) E validação consistente
contra os 5 `lbc.*.nc` reais de produção — erro médio pequeno e estável
nos 5 tempos (`u`~0.05-0.09 m/s, `theta`~0.05-0.11K, `rho`~0.006,
`w`~0.004). Único problema real conhecido: bug confirmado na própria
referência (`lbc_qv` constante em todos os níveis, não é nosso).

**Próximo passo — passo 6 (Fase 7)**: rodar a previsão de verdade
(`mpas_atmosphere`) a partir desses arquivos e comparar contra a rodada
de referência já documentada no README principal. Ainda não executado.
