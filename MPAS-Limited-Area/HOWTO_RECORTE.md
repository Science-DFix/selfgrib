# Como recortar uma região regional a partir da malha global do MPAS-A

Este diretório é um clone do [MPAS-Dev/MPAS-Limited-Area](https://github.com/MPAS-Dev/MPAS-Limited-Area)
(ferramenta oficial da NCAR). Este arquivo documenta especificamente como
usá-lo no nosso fluxo de trabalho, com um exemplo real já testado (América
do Sul).

## 1. Preparar (não precisa compilar — é Python puro)

```bash
pip install -r requirements.txt   # numpy, netCDF4
# opcional, só para o modo -p/--plot:
pip install matplotlib cartopy
```

Não é necessário instalar nada em PATH; basta chamar `python3 create_region`
de dentro deste diretório (ou usar o caminho completo do script).

## 2. Definir o domínio (arquivo `.pts`)

A ferramenta aceita 4 formas de definir a região: `circle`, `ellipse`,
`custom` (polígono) e `channel`. Exemplos completos de cada uma estão em
`docs/points-examples/`.

**Recomendação:** prefira `circle` ou `ellipse` (formas convexas). Regiões
côncavas ou que cruzam longitudes perto dos polos causam erros na
interpolação de campos estáticos do `init_atmosphere_model` — ver a seção
"Notes on creating regions from .grid.nc files" no `README.md` original.

### Exemplo real: América do Sul (`South_America.ellipse.pts`)

Já incluído neste diretório:

```
Name: SouthAmerica
Type: ellipse
Point: -15.0, -60.0        # centro aproximado do continente (MT, Brasil)
Semi-major-axis: 4700000   # metros, eixo N-S (cobre ~25.5N a ~-57.3S)
Semi-minor-axis: 3000000   # metros, eixo L-O (cobre ~-88W a ~-32W na latitude do centro)
Orientation-angle: 0.0     # eixo maior alinhado ao norte verdadeiro (N-S)
```

Resultado visual (gerado com `-p`, ver passo 4): `region.png` — cobre todo o
continente com margem oceânica confortável em todas as direções (importante
para a zona de relaxamento da fronteira lateral).

## 3. Qual arquivo usar como malha global (`grid`)

O `create_region` aceita um `grid.nc` (malha crua) ou um `static.nc` (malha
+ estáticos já interpolados) como fonte. **Duas opções, dependendo do
propósito:**

- **Para gerar a malha REGIONAL completa (produção):** use o arquivo
  `x1.<N>.static.nc` da malha global correspondente (contém terreno,
  categorias de uso do solo, climatologia mensal de vegetação/albedo —
  campos que `history.nc`/`mpasout.nc` NÃO têm). Isso evita ter que rodar
  `config_static_interp=true` com o `WPS_GEOG` do zero para a região nova.

- **Para testes rápidos/plot** (sem se importar com os campos estáticos):
  qualquer `history.*.nc` real da rodada global serve, porque o MPAS grava
  a malha completa (conectividade `cellsOnCell`, `verticesOnCell`, etc.) em
  toda saída do stream `output` por padrão. **Atenção:** o arquivo
  `x1.<N>.init.nc` normalmente aparece como link simbólico para o cluster
  (Lustre) e pode não estar acessível fora dele — não é necessário de
  qualquer forma, já que `history.nc`/`static.nc` já bastam.

## 4. Rodar

Plot rápido (não gera a malha, só a figura de validação — rápido, útil para
conferir a geometria antes de gastar tempo com o recorte de verdade):

```bash
python3 create_region -v 2 South_America.ellipse.pts \
    /caminho/para/x1.163842.static.nc -p
# gera region.png
```

Recorte de verdade:

```bash
python3 create_region -v 2 South_America.ellipse.pts \
    /caminho/para/x1.163842.static.nc
# gera SouthAmerica.static.nc + SouthAmerica.graph.info
```

(Se a fonte for um `.static.nc`, a saída também se chama `<nome>.static.nc`;
se a fonte for `.init.nc`, sai `<nome>.init.nc`; se for `.grid.nc` genérico,
sai `<nome>.region.nc` — o sufixo de saída acompanha o sufixo de entrada.)

No teste feito com a elipse acima sobre a malha `x1.163842` (60 km, 163842
células globais), o recorte resultou em **17064 células** — rodou em cerca
de 3-4 minutos lendo um arquivo de ~1.8 GB via rede.

## 5. Particionar para execução paralela (opcional)

```bash
gpmetis -minconn -contig -niter=200 SouthAmerica.graph.info N
# gera SouthAmerica.graph.info.part.N, para rodar com N tarefas MPI
```

## 6. Próximo passo

O `SouthAmerica.static.nc` (ou `.init.nc`/`.region.nc`) gerado aqui é o
arquivo que vai no `streams.init_atmosphere` (stream `input`) do
`init_atmosphere_model`, junto com os arquivos meteorológicos intermediários
gerados pela nossa pipeline em `../mpas2intermediate/` (ver o `README.md` lá
para o processo completo: extração de dados globais → preparação dos
arquivos → execução do MPAS-A).
