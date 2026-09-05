! Lista de niveis de pressao-alvo para a extracao MPAS -> intermediario.
!
! Os 55 valores mais densos (12.24 a 1002.15 hPa) NAO sao arbitrarios: sao a
! pressao MEDIANA de cada um dos 55 niveis de modelo nativos do MPAS-A
! (calculada sobre as celulas interiores -- bdyMaskCell==0 -- do dominio
! SouthAmerica.region.nc, rodada 2026-01-02_00, arquivo
! history.2026-01-02_00.00.00.nc). Preservam portanto o mesmo espacamento
! vertical real do modelo (denso na baixa/media troposfera, esparso na
! estratosfera) em vez de uma lista generica GFS.
!
! BUG REAL (2026-09-05): usar so esses 55 niveis deixa ZERO margem de
! seguranca no topo -- o valor mais alto (12.24 hPa) e a MEDIANA da altura
! do nivel de modelo 55 numa rodada de referencia especifica, entao para
! ~metade das celulas (e para dias/rodadas diferentes, com atmosfera um
! pouco mais fria/comprimida no topo) o topo real do dominio MPAS
! (config_ztop) fica ACIMA da altura correspondente a 12.24 hPa. O
! init_atmosphere_model (consumidor) nao aceita esse caso: trava com
! "ERROR: extrap_type == 2 not implemented for target_z >= zf(1,nz)"
! seguido de erro fatal na interpolacao de t(k,iCell) no ultimo nivel (k
! igual ao numero de niveis de pressao, ou seja, o topo). Confirmado ao
! vivo: com config_nfglevels ja corrigido para 56 (ver README.md secao
! 6.1), o erro persistiu porque a causa era esta, nao a contagem de niveis.
!
! CORRECAO: os 6 niveis extras abaixo (1, 2, 3, 5, 7, 10 hPa) sao os
! MESMOS niveis reais que o `ungrib`/GFS de producao ja usa acima de 12
! hPa -- confirmados lendo os headers (campo XLVL) de um FILE:* real de
! producao (FILE:2025-12-28_00, GFS 0.25 graus): niveis distintos ate
! 100 Pa = 1 hPa. Nao sao um buffer arbitrario: reproduzem o teto vertical
! que o proprio init_atmosphere_model ja consome sem erro em producao (1
! hPa ~ 48 km, bem acima de qualquer config_ztop usado). Servem apenas
! como margem -- os valores de T/U/V/RH extrapolados para eles (pela
! formula proporcional de interp_tofixed_pressure, que nao trava acima do
! topo do history.nc) nunca sao fisicamente relevantes, pois nenhuma
! celula real do dominio MPAS chega perto dessa altitude.
!
! BUG 2 REAL (2026-09-05, mesmo dia): a correcao acima sozinha NAO
! resolveu o erro -- confirmado ao vivo, mesmo com N_PLEVELS=61 o
! init_atmosphere_model continuou travando no mesmo
! "extrap_type == 2 not implemented for target_z >= zf(1,nz)". Causa:
! interp_tofixed_pressure usa a MESMA formula de extrapolacao acima do
! topo para TODOS os campos, inclusive GHT: field_out = field_in(topo) *
! (pressao_alvo/pressao_topo). Essa formula e plausivel para campos como
! temperatura, mas e FISICAMENTE INVERTIDA para altura -- como
! pressao_alvo < pressao_topo nos niveis de buffer, o resultado e uma
! altura MENOR que a do topo nativo, nao maior.
!
! BUG 3 REAL (2026-09-05, mesmo dia, ainda): a primeira tentativa de
! correcao (fixar GHT so nos 6 primeiros indices de plevels_hPa, 1-10
! hPa, ancorada no indice 7 = 12.24 hPa) tambem nao bastou -- confirmado
! ao vivo, o mesmo erro voltou a ocorrer, agora em indices variados
! (k=1 numa celula, k=55 noutra). Causa: 12.24 hPa e a MEDIANA da pressao
! do nivel nativo mais alto ENTRE CELULAS -- para ~metade das celulas, a
! pressao real do topo nativo DESSA celula especifica e MAIOR que 12.24
! hPa (confirmado numa celula real: 13.10 hPa), entao o proprio "nivel
! nativo" de 12.24 hPa TAMBEM cai no ramo de extrapolacao com a formula
! errada para essa celula -- so que a correcao anterior so cobria os
! indices 1-6, nao o 7. Isso produzia GHT(12.24hPa) MENOR que
! GHT(14.06hPa) (interpolacao real, correta), quebrando monotonicidade.
!
! CORRECAO (parcial): em extract_fields.F90, a correcao de GHT passou a
! ser feita POR CELULA, comparando cada plevels_hPa(k) contra o topo
! nativo REAL dessa celula (pressure(nVertLevels,iCell), sempre dado
! real) -- nao mais um indice fixo do array.
!
! BUG 4 REAL (2026-09-05, mesmo dia, ainda -- rodando o pipeline
! completo, nao so extract_fields isolado): a correcao "por celula"
! tambem nao bastou -- confirmado ao vivo, mesmo com zero inversoes na
! malha NATIVA global (validado numericamente), o init_atmosphere_model
! continuou travando, agora consistentemente em k=1 em celulas
! diferentes da malha REGIONAL. Causa: comparar contra o topo real DE
! CADA CELULA faz com que celulas vizinhas NA MALHA GLOBAL tratem o
! MESMO nivel de pressao de formas diferentes (uma extrapola, a vizinha
! usa dado real) sempre que o topo real de uma esta abaixo e da outra
! acima daquele nivel -- uma "troca de regime" espacial. O convert_mpas
! (proximo estagio do pipeline, remapeamento horizontal malha nativa ->
! grade lat-lon) mistura os dados dessas celulas vizinhas; misturar um
! valor extrapolado (formula isotermica) com um valor real (fisica de
! verdade) de celulas adjacentes pode gerar um perfil nao-monotonico no
! ponto de grade remapeado, mesmo cada celula nativa sendo isoladamente
! monotonica.
!
! CORRECAO DEFINITIVA: usar um CONJUNTO FIXO de indices (N_ALWAYS_EXTRAP,
! os mesmos para TODAS as celulas) sempre corrigidos com a extrapolacao
! hipsometrica, eliminando a troca de regime espacial -- toda celula
! trata os mesmos primeiros N_ALWAYS_EXTRAP niveis da mesma forma
! (extrapolacao, variando suavemente so pela ancora p_topo_real/
! z_topo_real/T_topo_real de cada celula, que sao continuas no espaco).
! Confirmado numa malha global real (163842 celulas): a pressao do topo
! nativo NUNCA excede 13.86 hPa -- ver N_ALWAYS_EXTRAP abaixo para a
! margem escolhida.
!
! IMPORTANTE sobre a ordem: a rotina interp_tofixed_pressure (extraida de
! mpas_isobaric_diagnostics.F) espera press_in/press_out em ordem CRESCENTE
! de pressao (indice 1 = menor pressao / topo). O array nativo do MPAS
! (pressure(k,iCell)) tem k=1 na SUPERFICIE (maior pressao) e k=nVertLevels
! no topo -- ou seja, DECRESCENTE. O proprio mpas_isobaric_diagnostics.F
! inverte isso explicitamente antes de chamar a rotina (kk = nVertLevels+1-k,
! linha ~678). O array abaixo ja esta na ordem exigida (crescente); o
! programa principal deve fazer a mesma inversao ao montar press_in/field_in
! a partir dos campos nativos lidos do history.nc.
!
! Unidades: hPa (mesma convencao usada internamente por interp_tofixed_pressure
! e compute_slp). Converter para Pa apenas na hora de escrever o registro do
! formato intermediario do WPS (que usa Pa no campo xlvl).

module pressure_levels

   use mpas_kind_types, only : RKIND

   implicit none
   private

   integer, parameter, public :: N_PLEVELS = 61

   ! Quantos dos N_PLEVELS primeiros indices (menor pressao) sao SEMPRE
   ! corrigidos com extrapolacao hipsometrica em extract_fields.F90,
   ! para TODAS as celulas igualmente -- ver "BUG 4" no comentario acima.
   ! 8 cobre ate 14.06 hPa; confirmado numa malha global real (163842
   ! celulas) que a pressao do topo nativo NUNCA excede 13.86 hPa (min
   ! 8.44, max 13.86, mediana 12.17) -- 14.06 hPa fica sempre ~0.2 hPa
   ! acima do pior caso observado, e os indices 9+ (16.19 hPa em diante)
   ! ficam com folga bem maior. Ajuste para cima se um novo recorte de
   ! malha ou uma rodada diferente mostrar topo nativo mais alto que isso.
   integer, parameter, public :: N_ALWAYS_EXTRAP = 8

   real(kind=RKIND), parameter, public :: plevels_hPa(N_PLEVELS) = (/ &
         1.00_RKIND,   2.00_RKIND,   3.00_RKIND,   5.00_RKIND,   7.00_RKIND, &
        10.00_RKIND, &
        12.24_RKIND,  14.06_RKIND,  16.19_RKIND,  18.66_RKIND,  21.53_RKIND, &
        24.88_RKIND,  28.78_RKIND,  33.37_RKIND,  38.77_RKIND,  45.12_RKIND, &
        52.59_RKIND,  61.61_RKIND,  72.52_RKIND,  85.50_RKIND, 100.55_RKIND, &
       117.27_RKIND, 135.38_RKIND, 154.96_RKIND, 175.92_RKIND, 198.16_RKIND, &
       221.67_RKIND, 246.32_RKIND, 271.98_RKIND, 298.84_RKIND, 326.47_RKIND, &
       354.80_RKIND, 383.74_RKIND, 413.25_RKIND, 443.24_RKIND, 473.29_RKIND, &
       503.51_RKIND, 533.77_RKIND, 563.89_RKIND, 593.86_RKIND, 623.48_RKIND, &
       652.60_RKIND, 681.19_RKIND, 708.99_RKIND, 736.01_RKIND, 762.15_RKIND, &
       787.28_RKIND, 811.31_RKIND, 834.20_RKIND, 855.88_RKIND, 876.31_RKIND, &
       895.42_RKIND, 913.07_RKIND, 929.33_RKIND, 944.12_RKIND, 957.47_RKIND, &
       969.31_RKIND, 979.66_RKIND, 988.58_RKIND, 996.08_RKIND, 1002.15_RKIND /)

   ! Pseudo-niveis de superficie/nivel-do-mar na convencao do formato
   ! intermediario do WPS (ver Vtable.BAM / Vtable.ETA ja validados):
   real(kind=RKIND), parameter, public :: LEVEL_SFC_PA    = 200100.0_RKIND  ! pseudo-nivel "superficie" (2 m / 10 m / PSFC)
   real(kind=RKIND), parameter, public :: LEVEL_SEALVL_PA = 201300.0_RKIND  ! pseudo-nivel "nivel do mar" (PMSL)

end module pressure_levels
