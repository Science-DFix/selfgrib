! Leitura do namelist.init_atmosphere REAL do experimento (mesmo arquivo
! usado pelo pipeline WPS atual/init_atmosphere_model -- nao um formato
! novo) via NAMELIST nativo do Fortran, pra tornar os drivers
! (gen_vertical_grid.F90/gen_init_native.F90) reproduziveis pra qualquer
! malha/experimento, nao so o caso SouthAmerica usado como exemplo
! inicial. Grupos/nomes de variavel conferidos contra
! /mnt/dados2/ungrib_to_mpas/recortes/SouthAmerica/{init_run,lbc_run}/namelist.init_atmosphere
! reais (2026-09-09).
module namelist_config

    use mpas_kind_types, only : RKIND

    implicit none

    type :: init_atm_config_type
        integer :: config_init_case = 7
        character (len=64) :: config_start_time = ''
        character (len=64) :: config_stop_time = ''
        integer :: config_theta_adv_order = 3
        real (kind=RKIND) :: config_coef_3rd_order = 0.25_RKIND
        character (len=64) :: config_interface_projection = 'linear_interpolation'

        integer :: config_nvertlevels = 55
        integer :: config_nsoillevels = 4
        integer :: config_nfglevels = 62
        integer :: config_nfgsoillevels = 4
        integer :: config_gocartlevels = 30

        character (len=64) :: config_met_prefix = 'MPAS'
        logical :: config_use_spechumd = .true.
        integer :: config_fg_interval = 21600

        real (kind=RKIND) :: config_ztop = 30000.0_RKIND
        integer :: config_nsmterrain = 1
        logical :: config_smooth_surfaces = .true.
        real (kind=RKIND) :: config_dzmin = 0.3_RKIND
        integer :: config_nsm = 30
        logical :: config_tc_vertical_grid = .true.
        logical :: config_blend_bdy_terrain = .false.

        character (len=64) :: config_extrap_airtemp = 'lapse-rate'

        logical :: config_static_interp = .false.
        logical :: config_native_gwd_static = .false.
        logical :: config_vertical_grid = .true.
        logical :: config_met_interp = .true.
        logical :: config_input_sst = .false.
        logical :: config_frac_seaice = .true.

        ! Derivados de config_start_time (parseados por parse_config_start_time).
        integer :: start_year, start_month, start_day, start_hour, start_minute, start_second
    end type init_atm_config_type

    contains

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! read_init_atm_namelist
    !
    ! Le os grupos &nhyd_model/&dimensions/&data_sources/&vertical_grid/
    ! &interpolation_control/&preproc_stages de um namelist.init_atmosphere
    ! real. Nao falha se um grupo/variavel especifico estiver ausente do
    ! arquivo (mantem o default do tipo) -- alguns namelists reais (ex.
    ! init_run) nao tem config_fg_interval, so' o lbc_run tem.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine read_init_atm_namelist(filename, cfg)

        implicit none

        character (len=*), intent(in) :: filename
        type (init_atm_config_type), intent(inout) :: cfg

        integer :: unit_nml, ios

        integer :: config_init_case
        character (len=64) :: config_start_time, config_stop_time, config_interface_projection
        integer :: config_theta_adv_order
        real (kind=RKIND) :: config_coef_3rd_order
        namelist /nhyd_model/ config_init_case, config_start_time, config_stop_time, &
                               config_theta_adv_order, config_coef_3rd_order, config_interface_projection

        integer :: config_nvertlevels, config_nsoillevels, config_nfglevels, &
                   config_nfgsoillevels, config_gocartlevels
        namelist /dimensions/ config_nvertlevels, config_nsoillevels, config_nfglevels, &
                               config_nfgsoillevels, config_gocartlevels

        character (len=64) :: config_met_prefix
        logical :: config_use_spechumd
        integer :: config_fg_interval
        namelist /data_sources/ config_met_prefix, config_use_spechumd, config_fg_interval

        real (kind=RKIND) :: config_ztop, config_dzmin
        integer :: config_nsmterrain, config_nsm
        logical :: config_smooth_surfaces, config_tc_vertical_grid, config_blend_bdy_terrain
        namelist /vertical_grid/ config_ztop, config_nsmterrain, config_smooth_surfaces, &
                                  config_dzmin, config_nsm, config_tc_vertical_grid, config_blend_bdy_terrain

        character (len=64) :: config_extrap_airtemp
        namelist /interpolation_control/ config_extrap_airtemp

        logical :: config_static_interp, config_native_gwd_static, config_vertical_grid_nml, &
                   config_met_interp, config_input_sst, config_frac_seaice
        namelist /preproc_stages/ config_static_interp, config_native_gwd_static, config_vertical_grid_nml, &
                                   config_met_interp, config_input_sst, config_frac_seaice

        ! Inicializa as variaveis locais com os defaults do tipo (pra caso
        ! o grupo/variavel nao exista no arquivo, o namelist read simplesmente
        ! nao sobrescreve, mantendo o default em vez de deixar indefinido).
        config_init_case = cfg % config_init_case
        config_start_time = cfg % config_start_time
        config_stop_time = cfg % config_stop_time
        config_theta_adv_order = cfg % config_theta_adv_order
        config_coef_3rd_order = cfg % config_coef_3rd_order
        config_interface_projection = cfg % config_interface_projection
        config_nvertlevels = cfg % config_nvertlevels
        config_nsoillevels = cfg % config_nsoillevels
        config_nfglevels = cfg % config_nfglevels
        config_nfgsoillevels = cfg % config_nfgsoillevels
        config_gocartlevels = cfg % config_gocartlevels
        config_met_prefix = cfg % config_met_prefix
        config_use_spechumd = cfg % config_use_spechumd
        config_fg_interval = cfg % config_fg_interval
        config_ztop = cfg % config_ztop
        config_nsmterrain = cfg % config_nsmterrain
        config_smooth_surfaces = cfg % config_smooth_surfaces
        config_dzmin = cfg % config_dzmin
        config_nsm = cfg % config_nsm
        config_tc_vertical_grid = cfg % config_tc_vertical_grid
        config_blend_bdy_terrain = cfg % config_blend_bdy_terrain
        config_extrap_airtemp = cfg % config_extrap_airtemp
        config_static_interp = cfg % config_static_interp
        config_native_gwd_static = cfg % config_native_gwd_static
        config_vertical_grid_nml = cfg % config_vertical_grid
        config_met_interp = cfg % config_met_interp
        config_input_sst = cfg % config_input_sst
        config_frac_seaice = cfg % config_frac_seaice

        open(newunit=unit_nml, file=trim(filename), status='old', action='read', iostat=ios)
        if (ios /= 0) then
            write(0,*) 'Error: nao consegui abrir namelist '''//trim(filename)//''''
            stop 3
        end if

        read(unit_nml, nml=nhyd_model, iostat=ios)
        rewind(unit_nml)
        read(unit_nml, nml=dimensions, iostat=ios)
        rewind(unit_nml)
        read(unit_nml, nml=data_sources, iostat=ios)
        rewind(unit_nml)
        read(unit_nml, nml=vertical_grid, iostat=ios)
        rewind(unit_nml)
        read(unit_nml, nml=interpolation_control, iostat=ios)
        rewind(unit_nml)
        read(unit_nml, nml=preproc_stages, iostat=ios)
        close(unit_nml)

        cfg % config_init_case = config_init_case
        cfg % config_start_time = config_start_time
        cfg % config_stop_time = config_stop_time
        cfg % config_theta_adv_order = config_theta_adv_order
        cfg % config_coef_3rd_order = config_coef_3rd_order
        cfg % config_interface_projection = config_interface_projection
        cfg % config_nvertlevels = config_nvertlevels
        cfg % config_nsoillevels = config_nsoillevels
        cfg % config_nfglevels = config_nfglevels
        cfg % config_nfgsoillevels = config_nfgsoillevels
        cfg % config_gocartlevels = config_gocartlevels
        cfg % config_met_prefix = config_met_prefix
        cfg % config_use_spechumd = config_use_spechumd
        cfg % config_fg_interval = config_fg_interval
        cfg % config_ztop = config_ztop
        cfg % config_nsmterrain = config_nsmterrain
        cfg % config_smooth_surfaces = config_smooth_surfaces
        cfg % config_dzmin = config_dzmin
        cfg % config_nsm = config_nsm
        cfg % config_tc_vertical_grid = config_tc_vertical_grid
        cfg % config_blend_bdy_terrain = config_blend_bdy_terrain
        cfg % config_extrap_airtemp = config_extrap_airtemp
        cfg % config_static_interp = config_static_interp
        cfg % config_native_gwd_static = config_native_gwd_static
        cfg % config_vertical_grid = config_vertical_grid_nml
        cfg % config_met_interp = config_met_interp
        cfg % config_input_sst = config_input_sst
        cfg % config_frac_seaice = config_frac_seaice

        call parse_config_start_time(cfg)

    end subroutine read_init_atm_namelist


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! parse_config_start_time
    !
    ! 'YYYY-MM-DD_HH:MM:SS' (formato padrao MPAS) -> campos inteiros.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine parse_config_start_time(cfg)

        implicit none

        type (init_atm_config_type), intent(inout) :: cfg

        read(cfg % config_start_time( 1: 4), '(I4)') cfg % start_year
        read(cfg % config_start_time( 6: 7), '(I2)') cfg % start_month
        read(cfg % config_start_time( 9:10), '(I2)') cfg % start_day
        read(cfg % config_start_time(12:13), '(I2)') cfg % start_hour
        read(cfg % config_start_time(15:16), '(I2)') cfg % start_minute
        read(cfg % config_start_time(18:19), '(I2)') cfg % start_second

    end subroutine parse_config_start_time


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! extrap_airtemp_code
    !
    ! 'constant'/'linear'/'lapse-rate' -> 0/1/2 (mesma convencao de
    ! vinterp_native::vertical_interp).
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    integer function extrap_airtemp_code(config_extrap_airtemp) result(code)

        implicit none

        character (len=*), intent(in) :: config_extrap_airtemp

        if (trim(config_extrap_airtemp) == 'constant') then
            code = 0
        else if (trim(config_extrap_airtemp) == 'linear') then
            code = 1
        else if (trim(config_extrap_airtemp) == 'lapse-rate') then
            code = 2
        else
            write(0,*) 'Error: config_extrap_airtemp invalido: '''//trim(config_extrap_airtemp)//''''
            stop 4
        end if

    end function extrap_airtemp_code

end module namelist_config
