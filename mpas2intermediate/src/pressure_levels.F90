! Lista de niveis de pressao-alvo para a extracao MPAS -> intermediario.
!
! Os 55 valores abaixo NAO sao arbitrarios: sao a pressao MEDIANA de cada um
! dos 55 niveis de modelo nativos do MPAS-A (calculada sobre as celulas
! interiores -- bdyMaskCell==0 -- do dominio SouthAmerica.region.nc, rodada
! 2026-01-02_00, arquivo history.2026-01-02_00.00.00.nc). Preservam portanto
! o mesmo espacamento vertical real do modelo (denso na baixa/media
! troposfera, esparso na estratosfera) em vez de uma lista generica GFS.
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

   integer, parameter, public :: N_PLEVELS = 55

   real(kind=RKIND), parameter, public :: plevels_hPa(N_PLEVELS) = (/ &
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
