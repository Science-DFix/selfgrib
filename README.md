# selfgrib

> *self* + *GRIB* — porque o MPAS-A vira sua própria fonte de dados,
> sem precisar de nenhum GRIB externo (GFS, BAM, Eta...). Ele lê a própria
> saída global e usa pra alimentar a si mesmo. Autossuficiente, meio
> narcisista, mas funciona.

## O que é isso

Um "ungrib" alternativo para o MPAS-A: em vez de decodificar GRIB de um
modelo externo (GFS via `ungrib` do WPS, como normalmente se faz), essa
ferramenta lê a saída **nativa** de uma rodada global do próprio MPAS-A
(`history.nc`) e gera o mesmo formato binário intermediário que o
`init_atmosphere_model` já sabe consumir — permitindo criar condição
inicial e fronteira lateral para um novo domínio MPAS-A (regional ou
global) **sem nenhum patch no código-fonte do MPAS-Model**.

## Estrutura do repositório

```
mpas2intermediate/     -- o "selfgrib" propriamente dito (pipeline Fortran)
convert_mpas/           -- ferramenta da NCAR usada como dependencia (remapeamento horizontal)
MPAS-Limited-Area/      -- ferramenta da NCAR para recortar regioes da malha global
docs/                   -- referencias tecnicas (manuais MPAS-A, notas historicas)
```

Cada subdiretório tem seu próprio `README.md`/`HOWTO_*.md` com detalhes de
uso. Ponto de partida: [`mpas2intermediate/README.md`](mpas2intermediate/README.md)
— tem instruções de compilação, como rodar, e a documentação técnica
completa (de onde vieram as funções adaptadas, método de interpolação,
campos gerados, bugs encontrados e corrigidos no caminho).

## Origem

Nasceu de uma pergunta simples: "dá pra gerar condição inicial do MPAS-A
usando uma rodada global do próprio MPAS-A, em vez de depender de GRIB
externo?" A resposta, depois de bastante investigação no código-fonte do
`init_atmosphere_model` e comparação direta com arquivos de produção reais,
foi sim — e o resultado está aqui.
