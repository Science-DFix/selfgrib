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

**Status**: 🔲 em investigação (localizando código-fonte de referência).

**Por quê**: maior impacto numérico já *medido* no caso validado —
resíduo de ~171m concentrado no anel de fronteira (`bdyMaskCell >= 1`)
por não misturar o terreno do alvo regional com o do first-guess nessa
faixa antes de gerar a grade vertical.

**Onde mexe**: `vertical_grid.F90` / `gen_vertical_grid.F90` (a mistura
acontece *antes* de `compute_vertical_grid`, usando `ter` do alvo e
`ter` do first-guess interpolado + `bdyMaskCell`).

**Critério de aceite**: resíduo de altura no anel de fronteira cai de
~171m para o mesmo nível de erro do interior do domínio (sub-metro,
como já validado longe da fronteira); teste de regressão no caso
SouthAmerica não pode piorar o que já bate exato/quase-exato.

**Achados / decisões**: (preencher durante a implementação)

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

## Ordem de ataque

1 → 2/3 (decidem se a ferramenta serve além de MPAS-A→MPAS-A/baixa
latitude) → 5 (mais barato, só esforço de teste) → 4 (só vira relevante
com uma fonte diferente).
