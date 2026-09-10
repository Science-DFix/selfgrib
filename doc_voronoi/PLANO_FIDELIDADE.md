# Plano de fidelidade — rota nativa voronoi-to-voronoi

Rastreamento dos 5 pontos identificados em 2026-09-09 (ver
`doc_voronoi/relatorio_tecnico/capitulos/13_discussao_limitacoes.tex`)
para a rota nativa se tornar fiel ao `init_atmosphere_model` de
referência em qualquer cenário, não só no caso validado
(`SouthAmerica`, ~60km, 24h, `nVertLevels=55`).

Checkpoint antes de começar: tag `pre-hardening-v1` (commit `2cd4d97`).

**Regra desta fase**: commits locais a cada item concluído; nada é
`git push`ado até pedido explícito.

---

## 1. `config_blend_bdy_terrain` — mistura de terreno de fronteira

**Status**: ✅ implementado e validado no `gen_init_native.F90` (driver
de produção). Melhora substancial, mas critério de aceite original
("mesmo nível do interior") não foi atingido por completo — ver
explicação abaixo, não é um bug remanescente.

**Por quê**: maior impacto numérico já *medido* no caso validado —
resíduo de ~171m concentrado no anel de fronteira (`bdyMaskCell >= 1`)
por não misturar o terreno do alvo regional com o do first-guess nessa
faixa antes de gerar a grade vertical.

**Onde mexeu**: nova subrotina `blend_bdy_terrain_native` em
`vertical_grid.F90`, chamada em `gen_init_native.F90` logo antes de
`compute_vertical_grid`, gated por `cfg % config_blend_bdy_terrain`
(já lido do namelist real). Extraída de `mpas_init_atm_cases.F ::
blend_bdy_terrain` (mpas-bundle-3.0.2, ~linha 6791) — confirmado
também na seção 8.2 do `mpas_atmosphere_users_guide_8.3.0.pdf`.
`gen_vertical_grid.F90` (driver standalone de depuração da Fase 2,
**não usado na orquestração de produção** — confirmado em
`scripts/voronoi/04_gera_init_native.bash`, que chama só
`gen_init_native`) ficou **sem o fix**, decisão deliberada por não
fazer parte do caminho validado; registrar aqui caso algum dia volte a
ser usado standalone.

**Algoritmo** (idêntico ao original, `nBdyLayers=7`, `nSpecLayers=2`,
confirmados batendo contra `bdyMaskCell` real da malha SouthAmerica,
max=7): células com `bdyMaskCell > 5` ("especificadas") recebem o
terreno do first-guess direto, sem mistura; células com
`1 <= bdyMaskCell <= 5` ("relaxamento") recebem uma combinação
ponderada `peso = bdyMaskCell/5`. Diferença deliberada do original: lá
o terreno do first-guess vem de reler+reinterpolar bilinearmente o
campo `SOILHGT` de um arquivo binário WPS; aqui `SOILHGT` já foi
interpolado baricentricamente para a malha-alvo na Fase 1
(`hinterp_native` é genérico sobre todos os campos do first-guess,
`SOILHGT` incluso) — usado direto, sem reprojeção.

**Validação** (caso SouthAmerica, `config_blend_bdy_terrain=true` no
namelist real, comparado contra o `init.nc` real de produção
`init_run/SouthAmerica.init.nc`, não o nosso próprio
`init_run_native/` — cuidado, achado um bug de comparação em cima
disso durante a validação, corrigido antes de aceitar o resultado):

| Campo | Sem blend (anel fronteira) | Com blend (anel fronteira) |
|---|---|---|
| `zgrid` (terreno) | média 0.819m, **máx 171.389m** | média 0.431m, **máx 74.454m** |
| `rho` | máx 0.01840 | máx 0.00715 (-61%) |
| `surface_pressure` | média 10.96 Pa, máx 1792 Pa | média 6.70 Pa, máx 837 Pa (-39%/-53%) |
| `theta`/`w` | quase inalterado | quase inalterado (erro dominado por outra causa, não terreno) |

Nenhuma regressão observada em nenhum campo testado, nem no interior
do domínio (`bdyMaskCell=0`, erro de `zgrid` interior até melhorou
ligeiramente: 0.0040→0.0024m médio).

**Por que o resíduo não zera** (74m ainda > erro do interior, ~7-10m
máx): a referência real usa `SOILHGT` vindo de um *round-trip*
malha-nativa→grade-lat-lon→malha-nativa (rota WPS); nós usamos
`SOILHGT` interpolado diretamente malha-a-malha (baricêntrico, Fase 1).
São duas estimativas legitimamente diferentes do mesmo terreno de
first-guess, não uma delas "errada" — a nossa inclusive evita o erro de
round-trip já documentado (`doc_voronoi/prototipo_scatter/README.md`).
O resíduo remanescente reflete essa diferença de método, não um bug de
implementação do blend em si.

---

## 2. Reamostragem vertical de solo

**Status**: 🔲 não iniciado.

**Por quê**: hoje `tslb`/`smois` são copiados direto célula-a-célula do
first-guess, sem a interpolação linear por profundidade que o código de
referência faz entre o perfil do first-guess e as 4 profundidades-padrão
Noah. Só é seguro porque origem e destino são sempre MPAS-A (mesmo
esquema/profundidades) — quebra silenciosamente com qualquer fonte que
use profundidades de solo diferentes.

**Onde mexe**: `surface_fields.F90` (ou novo módulo `soil_resample.F90`).

**Critério de aceite**: com origem/destino usando as mesmas 4
profundidades (caso atual), resultado deve ser bit-idêntico à cópia
direta atual (a interpolação degenera pra identidade quando as
profundidades batem) — não pode regredir o caso já validado.

**Achados / decisões**: —

---

## 3. Reclassificação de gelo marinho

**Status**: 🔲 não iniciado.

**Por quê**: o código de referência reclassifica células de água muito
fria (`config_tsk_seaice_threshold`) como gelo marinho, ajustando em
cascata uso do solo, textura, albedo máximo de neve e perfis de
solo/temperatura dessas células. Não implementado. Irrelevante no caso
SouthAmerica (SEAICE=0 em toda a malha, confirmado contra o dado real),
mas obrigatório antes de qualquer malha regional em alta latitude.

**Onde mexe**: `surface_fields.F90` (novo bloco condicional em
`config_frac_seaice`, já parcialmente tratado — ver correção do limiar
fracionário vs. binário documentada no relatório).

**Critério de aceite**: caso SouthAmerica (sem gelo) não pode mudar
nenhum campo. Precisa de um segundo caso de teste com gelo marinho real
para validar de fato (ver item 5).

**Achados / decisões**: —

---

## 4. `qv` via umidade relativa (`config_use_spechumd=.false.`)

**Status**: 🔲 não iniciado (baixa prioridade).

**Por quê**: só o caminho "umidade específica direta do first-guess"
está implementado. O outro caminho (RH → razão de mistura via
Flatau/Thompson, função `rslf`) não existe — o programa detecta a
config oposta e recusa rodar, em vez de dar resultado errado em
silêncio. Só vira bloqueio real se aparecer um first-guess sem `qv`.

**Onde mexe**: `hydrostatic.F90` (`compute_q2`/`convert_relhum_wrt_ice`
já tem parte da lógica de umidade; falta o caminho RH→qv sem spechumd).

**Critério de aceite**: com `config_use_spechumd=.true.` (caso atual),
resultado idêntico ao atual. Precisa de um first-guess sem `qv` pra
validar o novo caminho de verdade.

**Achados / decisões**: —

---

## 5. Validação multi-caso (outra malha/resolução/estação)

**Status**: 🔲 não iniciado.

**Por quê**: toda a validação numérica e funcional até aqui usa uma
única malha (`SouthAmerica`, ~60km), um único caso (24h a partir de
2026-01-01_00), `nVertLevels=55`. Os 61 níveis de pressão fixa
intermediários são estatísticos de um único caso e nunca testados em
perfil vertical muito diferente. A generalização estrutural (namelist
lido em runtime) já remove a barreira técnica — falta só exercitar.

**Onde mexe**: nenhum código novo, necessariamente — é rodar o pipeline
já existente numa segunda malha/data e comparar contra uma segunda
referência real, se existir.

**Critério de aceite**: pipeline roda sem erro fim-a-fim num segundo
caso; erro campo-a-campo contra uma referência real (se disponível)
fica na mesma ordem de grandeza do caso SouthAmerica.

**Achados / decisões**: —

---

## 6. `config_smooth_surfaces` não conectado (achado revisando o manual)

**Status**: 🔲 não iniciado (baixa prioridade, achado 2026-09-09 relendo
`docs/mpas_atmosphere_users_guide_8.3.0.pdf` a pedido do usuário).

**Por quê**: o manual (namelist `&vertical_grid`) documenta
`config_smooth_surfaces` (logical, default `true`) como o interruptor
que liga/desliga a suavização iterativa das superfícies zeta por nível
(`config_nsm` controla quantas passadas, no máximo). `namelist_config.F90`
já lê `config_smooth_surfaces` pro tipo de config, mas
`compute_vertical_grid` nunca recebe esse argumento — a suavização roda
incondicionalmente sempre que `config_nsm>0`. Só não apareceu na
validação porque o namelist real usado (`FILE_BASE`) tem
`config_smooth_surfaces=true` explícito, igual ao default — o caminho
`.false.` nunca foi exercitado nem bloqueado.

**Onde mexe**: `vertical_grid.F90` (`compute_vertical_grid`, gatear o
loop "Suavização iterativa de hx por nível" com um novo argumento
`config_smooth_surfaces`) + `gen_init_native.F90` (passar
`cfg % config_smooth_surfaces` na chamada).

**Critério de aceite**: com `config_smooth_surfaces=true` (caso atual),
resultado idêntico ao atual (regressão zero). Não há caso de teste real
com `.false.` disponível — like item 4, só importa se aparecer.

**Achados / decisões**: revisão do manual (seção 8.1) também confirmou
que `config_sst_update`/`surface.nc` (atualização periódica de SST/gelo
marinho durante a previsão) **não é uma lacuna desta rota** — é uma
opção do núcleo `mpas_atmosphere` (não do `init_atmosphere_model`),
desligada deliberadamente (`config_sst_update=false`) tanto na rota
antiga quanto na nativa, e o próprio manual diz que é dispensável para
previsões curtas (poucos dias) como a validada aqui. Não vira item de
pendência.

---

## Ordem de ataque

1 (✅ feito) → 2/3 (decidem se a ferramenta serve além de
MPAS-A→MPAS-A/baixa latitude) → 5 (mais barato, só esforço de teste) →
4/6 (só viram relevantes com uma fonte/config diferente da testada).
