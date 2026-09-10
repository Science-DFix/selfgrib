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
`core/pipeline/native/04_gera_init_native.bash`, que chama só
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

**Status**: ✅ implementado e validado. Achado um bug pré-existente
(não introduzido nesta sessão) no caminho, com impacto muito maior que o
item em si — ver abaixo.

**Por quê**: hoje `tslb`/`smois` são copiados direto célula-a-célula do
first-guess, sem a interpolação linear por profundidade que o código de
referência faz entre o perfil do first-guess e as 4 profundidades-padrão
Noah. Só é seguro porque origem e destino são sempre MPAS-A (mesmo
esquema/profundidades) — quebra silenciosamente com qualquer fonte que
use profundidades de solo diferentes.

**Onde mexeu**: duas subrotinas novas em `surface_fields.F90` —
`adjust_soil_lapse_rate` (extraída de `adjust_input_soiltemps`) e
`resample_soil_profile` (extraída de `init_soil_layers_depth` +
`init_soil_layers_properties`, ambas em
`mpas_atmphys_initialize_real.F`, mpas-bundle-3.0.2). Preserva
deliberadamente duas excentricidades do original (`sm_input(1)` usa
`sm_fg(2)`, não `sm_fg(1)`; âncora de fundo usa `sm_input(nFGSoilLevels)`,
não `nFGSoilLevels+1`) — nenhuma afeta o caso validado, documentado em
comentário no código.

**Achado colateral (o mais importante deste item)**: `compute_vertical_grid`
suaviza o terreno internamente (4ª ordem, `config_nsmterrain`) mas nunca
devolvia esse terreno suavizado pro chamador — `ter_raw` é `intent(in)`,
a suavização rodava só numa cópia local. `gen_init_native.F90` usava
então o terreno **cru** (só com blend de fronteira do item 1, sem
suavização) pra corrigir `skintemp`/`tmn` por lapso térmico — diferente
do original, onde é a mesma variável de terreno (já suavizada) em todo
lugar. Esse bug já existia **antes desta sessão**, só nunca tinha sido
percebido porque `tmn`/`skintemp` são campos de impacto visualmente
pequeno e nunca comparados campo-a-campo em detalhe. Corrigido expondo
`ter_smoothed` como nova saída de `compute_vertical_grid`
(`vertical_grid.F90`) e usando-a em vez de `ter` cru em todas as
correções de lapso térmico.

**Validação** (mesmo caso SouthAmerica, contra `init_run/SouthAmerica.init.nc`
real, células de terra):

| Campo | Antes (item 1 só) | Com item 2 (terreno cru, com bug) | Com item 2 (terreno suavizado, corrigido) |
|---|---|---|---|
| `tmn` | média 0.307, máx 6.95 | idêntico (bug não tocado ainda) | **média 0.00057, máx 0.32** (~540x melhor) |
| `skintemp` | média 0.461, máx 7.07 | idêntico | **média 0.306, máx 3.61** (-34%/-49%) |
| `tslb` | média 0.174, máx 4.79 | média 0.316, máx 6.75 (piorou!) | média 0.174, máx 4.79 (igual/marginal) |
| `smois` | média 0.017, máx 0.42 | idêntico | idêntico (esperado — sem correção de lapso em umidade) |

`zgrid` e todos os campos atmosféricos (`theta`, `rho`, `w`,
`surface_pressure`) confirmados bit-idênticos antes/depois — o fix não
toca a coluna atmosférica, só os diagnósticos de superfície/solo.

**Critério de aceite**: cumprido para `smois` (idêntico) e essencialmente
para `tslb` (a correção de lapso é a mudança real esperada, não uma
regressão); superado para `tmn`/`skintemp`, que melhoraram por conta do
bug colateral corrigido no caminho.

---

## 3. Reclassificação de gelo marinho

**Status**: ✅ implementado; validado negativamente em dois casos
independentes (zero regressão, ver item 5). Validação positiva (uma
célula de verdade reclassificada) continua em aberto — nenhuma das
rodadas globais disponíveis neste ambiente cobre uma região com
`SEAICE>0` dentro do recorte `SouthAmerica` (ver achados do item 5);
precisa de `static.nc` de uma região em alta latitude, ainda não
disponível.

**Por quê**: o código de referência reclassifica células de água muito
fria (`config_tsk_seaice_threshold`) como gelo marinho, ajustando em
cascata uso do solo, textura, albedo máximo de neve e perfis de
solo/temperatura dessas células. Irrelevante no caso SouthAmerica
(SEAICE=0 em toda a malha, confirmado contra o dado real), mas
obrigatório antes de qualquer malha regional em alta latitude.

**Onde mexeu**: nova subrotina `reclassify_seaice` em
`surface_fields.F90`, extraída literalmente de duas rotinas em
`mpas_atmphys_initialize_real.F` (mpas-bundle-3.0.2):
`physics_init_sst` (~linha 516) e `physics_init_seaice` (~linha 586).
Chamada em `gen_init_native.F90` logo após a reamostragem de solo do
item 2 (precisa de `tslb_out`/`smois_out`/`skintemp_out` já prontos —
mesma ordem do driver real, `init_soil_layers` antes de
`physics_init_seaice`, confirmada lendo `physics_initialize_real`).
Passou a ler/escrever três campos que antes eram só de cópia direta do
`static.nc` (`ivgtyp`, `isltyp`, `snoalb`) e um escalar novo
(`isice_lu`, default 24). Novo parâmetro de namelist lido:
`config_tsk_seaice_threshold` (grupo `&physics`, default 100K —
confirmado ausente do namelist real usado, fica no default).

**Achado real durante a implementação**: `physics_init_sst` (o
`tsk=SST` sobre oceano aberto + limpeza defensiva de `xice`) só é
chamada no driver real (`physics_initialize_real`) dentro de
`if (config_input_sst) then` -- e o namelist real usado neste projeto
tem `config_input_sst=.false.` (TSM vem do próprio first-guess, não de
um arquivo auxiliar separado). Implementar esse bloco sem essa condição
teria forçado `skintemp=SST` em **toda célula de oceano** do caso
validado (já que `xice<limiar` é verdade em toda a malha) -- um desvio
real do comportamento de referência, pego só porque o hábito de
comparar campo a campo contra o `init.nc` real antes de aceitar
qualquer mudança continua valendo a pena. Corrigido condicionando esse
bloco a `config_input_sst` (a reclassificação em si,
`physics_init_seaice`, é chamada incondicionalmente no driver real,
então essa parte não tem esse problema).

**Critério de aceite**: caso SouthAmerica (sem gelo) não pode mudar
nenhum campo -- **confirmado**: `skintemp`/`tmn`/`tslb`/`smois`/`sh2o`
bit-idênticos ao baseline item 1+2; `ivgtyp`/`isltyp`/`snoalb`
idênticos ao `static.nc` em todas as 17064 células; `xice`/`seaice`
seguem zero em toda a malha. Falta um segundo caso de teste com gelo
marinho real pra validar a metade positiva do critério (ver item 5).

**Achados / decisões** (2026-09-10, revisão cruzada com material externo):
comparado contra o módulo `mpas_init_atm_fg_voronoi.F` do MONAN-ATM
(Kubota, INPE/CPTEC, 2024 — relatório técnico + código-fonte em
`doc_paulo_kubota/`, indicado pelo orientador do usuário), que ataca o
mesmo problema por uma rota nativa Voronoi-para-Voronoi independente
(embora com arquitetura diferente — ver \S6 da conclusão do relatório
técnico). **Nem a implementação de referência do próprio MONAN faz a
reclassificação em cascata** — o módulo deles só aplica
`xice = clamp(xice, 0, 1)` após a interpolação, sem tocar uso do
solo/textura/albedo. Isso não torna o item dispensável (a lacuna
documentada continua real), mas é um dado concreto pra calibrar
prioridade: nem o time que mantém o modelo operacional brasileiro
chegou a implementar isso ainda — reforça que fica atrás do item 5
(validação multi-caso) na ordem de ataque, não à frente.

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

**Status**: ⚠️ parcialmente concluído (2026-09-10). Validado com um
segundo caso (mesma malha, data/estado atmosférico independente); a
generalização para uma malha/resolução realmente diferente continua em
aberto por falta de dado disponível neste ambiente (ver "Achados"
abaixo).

**Por quê**: toda a validação numérica e funcional até aqui usava uma
única malha (`SouthAmerica`, ~60km), um único caso (24h a partir de
2026-01-01_00), `nVertLevels=55`. Os 61 níveis de pressão fixa
intermediários eram estatísticos de um único caso e nunca testados em
perfil vertical muito diferente. A generalização estrutural (namelist
lido em runtime) já removia a barreira técnica — faltava só exercitar.

**Onde mexeu**: nenhum código novo — rodou-se o pipeline já existente
(`extract_fields` → `hinterp_native` → `gen_init_native`) fim-a-fim numa
segunda inicialização, usando a mesma malha-alvo (`SouthAmerica.static.nc`)
mas uma rodada global-fonte totalmente independente:
`/lustre/.../SOURCE/dataout/PREV_MPAS/2026011500/history.2026-01-15_00.00.00.nc`
(mesma malha global uniforme de origem, `nCells=163842`, ~60km — mas 14
dias depois do caso original, estado sinótico completamente distinto).
Buscou-se também uma malha-alvo com resolução/região diferente
(`SouthAmerica` é a única disponível neste ambiente — nenhum outro
`*.static.nc` foi encontrado nos mounts `/mnt/JACI`/`/mnt/dados2`) e uma
rodada global com gelo marinho real (todas as 35 rodadas disponíveis em
`PREV_MPAS/` são sobre o mesmo domínio global, mas o recorte
`SouthAmerica` fica inteiramente em baixa latitude — nenhuma célula tem
`SEAICE>0` em nenhuma data testada).

**Critério de aceite**: pipeline roda sem erro fim-a-fim no segundo caso
— **confirmado** (Fases 1+2+3+4+6 completas, sem crash). Sanidade física
— **confirmada**: zero `NaN` em todos os 135 campos numéricos, `zgrid`
estritamente monotônico nas 17064 células (938.520 pares nível-célula
verificados), faixas de `theta`/`rho`/`w`/`u`/`qv`/`tslb`/`smois`/`sh2o`/
`tmn` fisicamente plausíveis e da mesma ordem de grandeza do caso
original. Confirmado que é de fato um estado atmosférico independente
(não uma cópia acidental): diferença média de $3{,}4$K em `theta`
(máx. $42$K), $478$Pa em `surface_pressure` (máx. $3599$Pa), $5{,}8$m/s
em `u` (máx. $103$m/s) frente ao caso original. Sem referência real
(`init.nc` de produção) pra essa segunda data, não dá pra validar
campo-a-campo bit a bit — só sanidade/plausibilidade.

**Achados / decisões**: este ambiente de trabalho só tem uma malha-alvo
(`SouthAmerica`) e uma única região global de baixa latitude disponível
localmente — não foi possível testar uma malha/resolução genuinamente
diferente (ex.: 15--25km, ou uma região em alta latitude) nem exercitar
a metade positiva do item 3 (célula real de gelo marinho sendo
corretamente reclassificada), porque nenhuma das 35 rodadas globais
disponíveis em `PREV_MPAS/` cobre uma região com `SEAICE>0` dentro do
recorte `SouthAmerica`. Este item permanece parcialmente aberto: a
generalização estrutural (código não depende de malha/resolução
fixa, já demonstrado pelo `namelist.init_atmosphere` lido em runtime)
está validada por construção, mas a demonstração empírica com uma malha
realmente diferente depende de dado externo (`static.nc` de outra
região/resolução + `history.nc` global cobrindo latitude com gelo
marinho) que precisa ser providenciado pelo usuário quando disponível.

---

## 6. `config_smooth_surfaces` não conectado (achado revisando o manual)

**Status**: ✅ implementado e validado (2026-09-10, motivado por pedido
explícito do usuário de manter as duas ramificações `true`/`false` de
toda flag `config_*` refletindo a dinâmica real do modelo — ver memória
`feedback_config_flags_both_branches`).

**Por quê**: o manual (namelist `&vertical_grid`) documenta
`config_smooth_surfaces` (logical, default `true`) como o interruptor
que liga/desliga a suavização iterativa das superfícies zeta por nível
(`config_nsm` controla quantas passadas, no máximo). `namelist_config.F90`
já lia `config_smooth_surfaces` pro tipo de config, mas
`compute_vertical_grid` nunca recebia esse argumento — a suavização
rodava incondicionalmente sempre que `config_nsm>0`.

**Onde mexeu**: `vertical_grid.F90` (`compute_vertical_grid`, novo
argumento `config_smooth_surfaces` envolvendo o laço "Suavização
iterativa de hx por nível" num `if`) + `gen_init_native.F90`/
`gen_vertical_grid.F90` (passam `cfg % config_smooth_surfaces`).
Confirmado no código-fonte real (`mpas_init_atm_cases.F`, ~linha
3217-3300) que o ramo `.false.` do original **não substitui por outra
suavização** -- só faz *logging*, deixando `hx(k,:)` igual ao terreno já
suavizado pela 4ª ordem em todos os níveis (valor já atribuído antes do
laço por nível). Por isso o ramo `.false.` aqui não precisa reatribuir
nada, só pular o laço.

**Critério de aceite**: com `config_smooth_surfaces=true` (caso real
validado) -- **confirmado**: `zgrid`/`zz`/`theta`/`rho`/`w`/
`surface_pressure` bit-idênticos ao baseline (regressão zero). Com
`config_smooth_surfaces=false` (nunca exercitado em produção, sem
referência real pra comparar) -- rodado como teste de sanidade: sem
`NaN`, sem inversão/degeneração de camada (espaçamento vertical mínimo
$\sim$47m, sempre positivo em toda a malha), `zgrid` difere do caso
suavizado como esperado (máx. $\sim$1140m, nos níveis mais altos, onde
a suavização por nível mais atua) e os campos hidrostáticos seguem em
faixa fisicamente plausível. Sem referência real, não dá pra confirmar
bit a bit -- mas não há sinal de bug.

**Achados / decisões**: revisão do manual (seção 8.1) também confirmou
que `config_sst_update`/`surface.nc` (atualização periódica de SST/gelo
marinho durante a previsão) **não é uma lacuna desta rota** — é uma
opção do núcleo `mpas_atmosphere` (não do `init_atmosphere_model`),
desligada deliberadamente (`config_sst_update=false`) tanto na rota
antiga quanto na nativa, e o próprio manual diz que é dispensável para
previsões curtas (poucos dias) como a validada aqui. Não vira item de
pendência.

---

## 7. Robustez de fonte de dado (achados da revisão cruzada com o MONAN)

**Status**: 🔲 não iniciado (baixíssima prioridade — nenhuma delas afeta
o caso validado, e ambas exigiriam uma fonte de first-guess diferente
da testada pra sequer serem exercitadas).

**Por quê**: comparando com `mpas_init_atm_fg_voronoi.F` (Kubota,
MONAN-ATM/INPE, 2024 — ver item 3 acima), dois pontos onde a
implementação deles é **mais autossuficiente** que a nossa, por
assumirem um `history.nc` mais "magro" (menos streams de diagnóstico
habilitados):

- **Derivação de T/p a partir do estado prognóstico bruto**: eles
  calculam `T`/`p` a partir de `theta_m`/`rho_zz`/`qv` via equação de
  estado (fórmula aproximada, erro autodocumentado `<0,2K`). Nós lemos
  `theta`/`pressure` já prontos, direto do `history.nc` (campos
  diagnósticos que o MPAS já grava) — mais preciso, mas **quebra se um
  `history.nc` de origem não tiver esses dois campos habilitados no
  stream**.
- **Reconstrução de vento a partir de `u_normal`**: eles reconstroem
  `u_cell`/`v_cell` por mínimos quadrados locais a partir do vento
  normal nas arestas. Nós lemos `uReconstructZonal/Meridional`, já
  pronto no `history.nc` — de novo, mais simples pra nós, mas depende
  desse campo estar no stream.

**Onde mexeria**: `extract_fields.F90` (ambos os fallbacks, condicionais
à ausência de `theta`/`pressure`/`uReconstructZonal/Meridional` no
`history.nc` de entrada).

**Critério de aceite**: com o `history.nc` já validado (todos os campos
diagnósticos presentes, caso atual), resultado idêntico — os fallbacks
só entrariam em jogo com uma fonte de first-guess diferente.

**Achados / decisões**: registrado aqui só como referência de como
resolver o problema *se* algum dia aparecer uma fonte MPAS-A sem esses
streams de diagnóstico habilitados (por exemplo, um `history.nc` de
produção configurado de forma mais enxuta que o caso testado) — não é
uma lacuna do caso validado, não implementar preventivamente.

---

## 8. `config_tc_vertical_grid` — fórmula alternativa da grade vertical (achado revisando o manual)

**Status**: ✅ implementado e validado (2026-09-10, mesma classe do item 6
— achado próprio, não do plano original, motivado pelo mesmo pedido
explícito do usuário de manter as duas ramificações `true`/`false` de
toda flag `config_*` — ver memória `feedback_config_flags_both_branches`).

**Por quê**: `compute_vertical_grid` sempre calculou `zw(k)` (posição dos
níveis $\zeta$ antes do reajuste sobre o terreno) com a fórmula
"experimentos de furacão de 2014" (achatamento não-linear que concentra
níveis perto da superfície), citada no código-fonte real como
`config_tc_vertical_grid=.true.`. Só que essa é uma flag lógica de
namelist (`namelist_config.F90` já a lia, com default `.true.`) — o
código real (`mpas_init_atm_cases.F`, ~linhas 3040-3130) tem uma
estrutura de três vias: `config_specified_zeta_levels` (fora do escopo
desta rota, sem uso real conhecido) → `config_tc_vertical_grid=.true.`
(já implementado) → `else` ("MPAS 2.0 e anterior", fórmula bem mais
simples, uma lei de potência: $\zeta_w(k) = z_{top}\left(\frac{k-1}{n_z-1}\right)^{1.5}$).
O ramo `.false.` nunca tinha sido implementado — a fórmula TC2014 era
aplicada incondicionalmente, mesmo que o namelist real pedisse a outra.

**Onde mexeu**: `vertical_grid.F90` (`compute_vertical_grid`, novo
argumento `config_tc_vertical_grid` logo após `config_smooth_surfaces`,
envolvendo o laço de cálculo de `zw(k)` num `if/else`: ramo `.true.`
mantém a fórmula TC2014 já existente, ramo `.false.` novo com a lei de
potência simples) + `gen_init_native.F90`/`gen_vertical_grid.F90` (passam
`cfg % config_tc_vertical_grid` na nova posição do argumento).
Confirmado por `grep` que as variáveis auxiliares da fórmula TC2014
(`als`/`alt`/`zetal`/`zl`) só são usadas dentro do próprio ramo
`.true.`, sem vazamento pro resto da rotina.

**Critério de aceite**: com `config_tc_vertical_grid=true` (caso real
validado, `namelist.init_atmosphere` do SouthAmerica) — **confirmado**:
diferença máxima de $4,5\times10^{-13}$ em `theta` e ordens de grandeza
menores nos demais campos (`qv`, `relhum`, `rho`, `u`, `w`) frente ao
checkpoint do item 6 — ruído de ponto flutuante (nível de épsilon de
máquina), não regressão. Com `config_tc_vertical_grid=false` (nunca
exercitado em produção, sem referência real pra comparar) — rodado como
teste de sanidade: sem `NaN`, `zgrid` estritamente monotônico em toda a
malha (938.520 pares nível-célula verificados, zero inversões — mesmo
resultado no ramo `.true.`), ancorado corretamente no terreno
($\zeta=0$) e no topo do modelo ($z=30000$m) em ambos os ramos. A
diferença entre os dois esquemas é fisicamente coerente com o que cada
fórmula foi desenhada pra fazer: a lei de potência simples (`.false.`)
distribui os níveis de forma mais uniforme, enquanto a fórmula TC2014
(`.true.`) concentra níveis perto da superfície (diferença média de
$\sim$3.400m na média-troposfera, caindo a zero nas duas extremidades).

**Achados / decisões**: nenhum impacto no caso validado, já que o
namelist real usa `.true.` (o mesmo valor que já estava implicitamente
hardcoded antes). A implementação do ramo `.false.` deixa a rota pronta
pra qualquer experimento futuro que opte pela grade vertical clássica do
MPAS 2.0 (por exemplo, ao reproduzir configurações mais antigas), sem
exigir recompilação.

---

## Ordem de ataque

1 (✅ feito) → 2 (✅ feito) → 3 (✅ feito, validação negativa em dois
casos; positiva bloqueada por falta de dado) → 6 (✅ feito) → 8
(✅ feito) → 5 (⚠️ parcial — sanidade em segundo caso confirmada;
malha/resolução realmente diferente e gelo marinho real seguem
bloqueados por falta de dado externo) → 4/7 (só viram relevantes com uma
fonte/config diferente da testada).

**Bloqueio comum aos itens 3 (metade positiva) e 5 (parte restante)**:
ambos precisam do mesmo dado externo ainda não disponível neste
ambiente — um `static.nc` de uma malha/região em alta latitude (ideal:
resolução também diferente de ~60km, pra testar generalização de
resolução ao mesmo tempo) mais um `history.nc` global cobrindo essa
região. Sem isso, os dois itens ficam no estado atual até o usuário
providenciar o dado.
