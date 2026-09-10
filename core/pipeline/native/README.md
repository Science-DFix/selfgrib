# Pipeline de interpolação nativa Voronoi — `init.nc`/`lbc.*.nc` sem WPS

Rota alternativa (branch `feature/interpolacao-nativa-voronoi`) à
`core/pipeline/legacy/0{2..5}_*.bash` (produção, via WPS). Não substitui
a rota de produção — coexiste com ela para comparação lado a lado.
Documentação completa (fundamentação teórica, equações de cada fase,
achados/bugs investigados, resultados de validação numérica e
funcional): ver `core/src/README.md` §2.4 e o relatório
técnico-científico em `doc_voronoi/relatorio_tecnico/` (mantido apenas
local, fora do git).

## Ordem de execução

| # | Script | O que faz | Reusa de `core/pipeline/`? |
|---|--------|-----------|----------------------|
| 1 | `core/pipeline/01_recorta_regiao.bash` | Recorta a malha regional (`<REGION>.static.nc`) a partir da malha global, via MPAS-Limited-Area. | **Sim, sem alteração** — geometria pura, não depende de WPS nem da rota de interpolação escolhida depois. |
| 2 | `02_extrai_first_guess.bash` | Roda `extract_fields` em cada `history.*.nc` da rodada global (níveis de pressão fixos, ainda na malha nativa global). | Novo (substitui a parte `extract_fields` do `run_pipeline.sh`, mas sem `convert_mpas`/grade lat-lon). |
| 3 | `03_interp_horizontal_nativa.bash` | Roda `hinterp_native` pra cada tempo: remapeia os campos extraídos direto pros centros de célula da malha-alvo (baricêntrico, sem grade lat-lon). | Novo. |
| 4 | `04_gera_init_native.bash` | Roda `gen_init_native` (Fases 2+3+4+6) pro tempo inicial + mescla com `ncks -A` os campos de cópia direta do `static.nc` → `init.nc` completo (135 variáveis). | Novo (substitui `core/pipeline/legacy/03_roda_init_atmosphere.bash` — não chama o `init_atmosphere_model` real pra essa etapa). |
| 5 | `05_gera_lbc_native.bash` | Roda `gen_lbc_native` pra cada tempo de fronteira (reusa a malha vertical do `init.nc`, não recalcula) → `lbc.*.nc`. | Novo (substitui `core/pipeline/legacy/04_gera_lbc.bash`). |
| 6 | `06_roda_previsao_native.bash` | Roda a previsão de verdade (`mpas_atmosphere`) a partir do `init.nc`/`lbc.*.nc` nativos. | Cópia de `core/pipeline/legacy/05_roda_previsao.bash` (mesmo namelist/streams/executável/tabelas de física) — só os caminhos de entrada mudam (`init_run_native`/`lbc_run_native`). |

## Variáveis de ambiente principais

Convenção igual à de `core/pipeline/legacy/`: tudo configurável via
`export` antes de rodar, com defaults sensatos. As mais importantes (ver
cada script para a lista completa):

- `DIR_VORONOI` — raiz deste clone/checkout no Jaci (default:
  `/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi`).
- `DIR_RODADA_GLOBAL` — rodada global MPAS-A já concluída (mesma
  convenção de `core/pipeline/legacy/02_roda_pipeline_meteorologico.bash`).
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

bash core/pipeline/01_recorta_regiao.bash              # passo 1 (reusa a rota de producao)
bash core/pipeline/native/02_extrai_first_guess.bash
bash core/pipeline/native/03_interp_horizontal_nativa.bash
bash core/pipeline/native/04_gera_init_native.bash    # so' o primeiro tempo de $TIMES
bash core/pipeline/native/05_gera_lbc_native.bash     # todos os tempos de $TIMES
```

## Status (2026-09-09)

**Pipeline completo (passos 1-6) rodado ponta-a-ponta no Jaci de verdade.**

- **Passos 1-5** (`init.nc`/`lbc.*.nc`): rápido (segundos por passo, Lustre
  local). `init.nc`: 135 variáveis, validado campo-a-campo contra o
  `init.nc` real — bate exato/quase-exato em tudo. `lbc.*.nc`:
  auto-consistência exata (diff=0 contra o próprio `init.nc` no mesmo
  tempo) E validação consistente contra os 5 `lbc.*.nc` reais de produção
  — erro médio pequeno e estável nos 5 tempos (`u`~0.05-0.09 m/s,
  `theta`~0.05-0.11K, `rho`~0.006, `w`~0.004). Único problema conhecido é
  da própria referência, não desta pipeline (`lbc_qv` constante em todos
  os níveis).
- **Passo 6** (`mpas_atmosphere` real): executado com sucesso — previsão
  de 24h completa (240 timesteps), sem erros, a partir exclusivamente dos
  arquivos gerados pelos passos 1-5 (nenhum `init.nc`/`lbc.*.nc` de
  produção usado como entrada). Divergência frente à rota de referência
  (via WPS) cresce de forma suave e limitada ao longo da integração,
  consistente com duas trajetórias vizinhas de um sistema caótico — não
  um artefato de implementação.

Bugs reais encontrados e corrigidos durante o desenvolvimento e a
execução (detalhados no relatório técnico, `doc_voronoi/relatorio_tecnico/`):
divergência de ~2km na grade vertical (`config_hybrid_coordinate`),
indexação de aresta de borda em `ru`, dois bugs em `gen_lbc_native.F90`
(ordem de dimensão NetCDF e alocação de `zb`/`zb3`), `xtime` faltando no
`init.nc` e com lixo de memória no `lbc.*.nc` (derrubava os 32 ranks MPI).

## O que ainda falta (limitações conhecidas)

Documentado em detalhe no capítulo de discussão do relatório técnico:

- `config_blend_bdy_terrain` não implementado — deixa um resíduo de
  ~171m concentrado no anel de células de fronteira.
- Campos de solo (`tslb`/`smois`) copiados diretamente célula-a-célula —
  válido só quando origem e destino usam o mesmo esquema de superfície
  (Noah); sem reamostragem/conversão de esquema.
- Gelo marinho e `config_use_spechumd=.false.` não implementados.
- Validado em um único par malha/caso (`SouthAmerica`, ~60km,
  `nVertLevels=55`, 24h a partir de `2026-01-01_00`) — a leitura de
  `namelist.init_atmosphere` real generaliza a rota estruturalmente para
  qualquer malha/experimento MPAS-A→MPAS-A, mas isso ainda não foi
  exercitado em outro caso.
- A fonte precisa ser especificamente um `history.nc` de uma rodada
  MPAS-A (não um GRIB ou saída de outro modelo global) — `extract_fields`
  espera os nomes/convenções desse formato nativo.
