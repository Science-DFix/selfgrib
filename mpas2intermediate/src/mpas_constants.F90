! Subconjunto copiado sem alteracoes de MPAS-Model/src/framework/mpas_constants.F
! (so' as constantes fisicas usadas pelo bloco de geracao de grade vertical/
! balanco hidrostatico extraido de mpas_init_atm_cases.F -- ver
! vertical_grid.F90/hydrostatic.F90). Valores conferidos linha a linha
! contra o arquivo original em 2026-09-08.

module mpas_constants

   use mpas_kind_types, only : RKIND

   real (kind=RKIND), parameter :: pii     = 3.141592653589793_RKIND
   real (kind=RKIND), parameter :: gravity = 9.80616_RKIND
   real (kind=RKIND), parameter :: rgas    = 287.0_RKIND
   real (kind=RKIND), parameter :: rv      = 461.6_RKIND
   real (kind=RKIND), parameter :: cp      = 7.0_RKIND*rgas/2.0_RKIND
   real (kind=RKIND), parameter :: rvord   = rv / rgas
   real (kind=RKIND), parameter :: cv      = cp - rgas
   real (kind=RKIND), parameter :: cvpm    = -cv / cp
   real (kind=RKIND), parameter :: p0      = 1.0e5_RKIND

end module mpas_constants
