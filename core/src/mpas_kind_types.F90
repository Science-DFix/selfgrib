! Copiado sem alteracoes de MPAS-Model/src/framework/mpas_kind_types.F
! (modulo standalone, sem dependencias) para manter o mesmo RKIND (double
! precision) usado pelas rotinas extraidas de mpas_isobaric_diagnostics.F.

module mpas_kind_types

   integer, parameter :: R4KIND = selected_real_kind(6)
   integer, parameter :: R8KIND = selected_real_kind(12)
   integer, parameter :: RKIND  = selected_real_kind(12)

   integer, parameter :: I8KIND = selected_int_kind(18)

   integer, parameter :: StrKIND = 512
   integer, parameter :: ShortStrKIND = 64

end module mpas_kind_types
