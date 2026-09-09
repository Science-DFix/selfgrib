program hinterp_native

    ! Fase 1 do plano de interpolacao nativa Voronoi (ver
    ! doc_voronoi/prototipo_scatter/README.md e o plano de implementacao).
    !
    ! Remapeia campos horizontalmente da malha nativa MPAS de origem
    ! (tipicamente extracted_fields.nc, ja interpolado verticalmente pelo
    ! extract_fields, ainda em niveis de pressao fixos) DIRETO para os
    ! centros de celula (latCell/lonCell) de uma malha MPAS de destino
    ! (tipicamente <REGION_NAME>.static.nc) -- sem passar por nenhuma
    ! grade lat-lon intermediaria.
    !
    ! E' essencialmente uma copia de convert_mpas.F90 (mesmos modulos,
    ! mesmo fluxo de scan/remap/write), com uma unica mudanca: em vez de
    ! target_mesh_setup(destination_mesh) ler uma grade lat-lon de um
    ! arquivo 'target_domain', aqui a malha de destino e' lida de um
    ! segundo arquivo MPAS (static.nc da regiao) e passada como lista de
    ! pontos dispersos (modo "scatter", target_mesh_setup(...,
    ! lat2d=..., lon2d=...)) -- exatamente o mesmo modo ja validado em
    ! doc_voronoi/prototipo_scatter/proto_scatter.F90. O motor de pesos
    ! (remapper.F90) e o resto do fluxo de E/S (scan_input.F90,
    ! file_output.F90) sao reusados sem nenhuma modificacao.
    !
    ! Uso:
    !   hinterp_native <malha-alvo.nc> <malha-origem.nc> <dado1.nc> [dado2.nc ...]
    !
    !   malha-alvo.nc   -- malha MPAS de destino (ex.: SouthAmerica.static.nc);
    !                      soh' latCell/lonCell sao usados nesta fase.
    !   malha-origem.nc -- malha MPAS de origem, com conectividade completa
    !                      (cellsOnCell/verticesOnCell/cellsOnVertex), tipicamente
    !                      o history.nc global original (mesma convencao do
    !                      convert_mpas: dado e malha podem vir de arquivos
    !                      separados).
    !   dado*.nc        -- arquivo(s) com os campos a remapear (tipicamente a
    !                      saida do extract_fields), na malha de origem.
    !
    ! Saida fixa: native_target.nc (mesma convencao de latlon.nc do
    ! convert_mpas). ATENCAO: por reusar remapper.F90 sem modificacao, os
    ! campos ficam na dimensao 'longitude' (tamanho nCells) x 'latitude'
    ! (tamanho 1, degenerada) por heranca do modo grade -- o indice ao
    ! longo de 'longitude' e' o que de fato indexa os centros de celula da
    ! malha-alvo, na MESMA ordem de latCell/lonCell do arquivo malha-alvo.nc
    ! (irank=1, ver target_mesh.F90). A variavel 'latitude' herdada desse
    ! mesmo modulo NAO tem valor util em modo scatter (colapsa pro valor de
    ! um unico ponto) -- use as variaveis 'target_latitude'/
    ! 'target_longitude' (escritas por este programa, corretas ponto a
    ! ponto) para saber a lat/lon real de cada indice.

    use copy_atts
    use scan_input
    use mpas_mesh
    use target_mesh
    use remapper
    use file_output
    use field_list
    use timer

    implicit none

    type (timer_type) :: total_timer, read_timer, remap_timer, write_timer

    integer :: stat
    character (len=1024) :: target_mesh_filename, source_mesh_filename, data_filename
    type (mpas_mesh_type) :: target_native_mesh, source_mesh
    type (target_mesh_type) :: destination_mesh
    type (input_handle_type) :: handle
    type (input_field_type) :: field
    type (remap_info_type) :: remap_info
    type (output_handle_type) :: output_handle
    type (target_field_type) :: target_field
    type (field_list_type) :: include_field_list, exclude_field_list

    real, dimension(:,:), allocatable, target :: target_lat2d, target_lon2d
    real, parameter :: rad2deg = 90.0 / asin(1.0)

    integer :: iRec, nRecordsIn, nRecordsOut, iFile, nArgs, nCellsTarget, i

    call timer_start(total_timer)

    nArgs = command_argument_count()
    if (nArgs < 3) then
        write(0,*) ' '
        write(0,*) 'Uso: hinterp_native malha-alvo.nc malha-origem.nc dado1.nc [dado2.nc ...]'
        write(0,*) ' '
        stop 1
    end if

    call get_command_argument(1, target_mesh_filename)
    call get_command_argument(2, source_mesh_filename)

    !
    ! Le a malha de destino (ex.: <REGION_NAME>.static.nc) so' para pegar
    ! latCell/lonCell -- os pontos onde vamos interpolar.
    !
    write(0,*) 'Lendo malha de destino (pontos-alvo) de '''//trim(target_mesh_filename)//''''
    if (mpas_mesh_setup(target_mesh_filename, target_native_mesh) /= 0) then
        write(0,*) 'Error: problemas lendo a malha de destino '//trim(target_mesh_filename)
        stop 2
    end if

    nCellsTarget = target_native_mesh % nCells
    allocate(target_lat2d(nCellsTarget,1))
    allocate(target_lon2d(nCellsTarget,1))
    do i=1,nCellsTarget
        target_lat2d(i,1) = target_native_mesh % latCell(i)
        target_lon2d(i,1) = target_native_mesh % lonCell(i)
    end do
    write(0,*) '  ', nCellsTarget, ' pontos-alvo (centros de celula da malha de destino)'

    !
    ! Monta o "grid" alvo em modo scatter (lista de pontos dispersos, nao
    ! uma grade lat-lon regular) -- mesma tecnica do prototipo.
    !
    if (target_mesh_setup(destination_mesh, lat2d=target_lat2d, lon2d=target_lon2d) /= 0) then
        write(0,*) 'Error: problemas montando a malha de destino em modo scatter'
        stop 3
    end if

    !
    ! Le a malha de origem (conectividade completa) para poder localizar,
    ! para cada ponto-alvo, o triangulo dual de Delaunay que o contem.
    !
    write(0,*) 'Lendo malha de origem (conectividade) de '''//trim(source_mesh_filename)//''''
    if (mpas_mesh_setup(source_mesh_filename, source_mesh) /= 0) then
        write(0,*) 'Error: problemas lendo a malha de origem '//trim(source_mesh_filename)
        stat = target_mesh_free(destination_mesh)
        stop 4
    end if

    write(0,*) ' '
    write(0,*) 'Calculando pesos de interpolacao baricentrica (malha dual de Delaunay)'
    call timer_start(remap_timer)
    if (remap_info_setup(source_mesh, destination_mesh, remap_info) /= 0) then
        write(0,*) 'Error: problemas montando o remapeamento'
        stat = mpas_mesh_free(source_mesh)
        stat = target_mesh_free(destination_mesh)
        stop 5
    end if
    call timer_stop(remap_timer)
    write(0,'(a,f10.6,a)') '    Tempo calculando pesos: ', timer_time(remap_timer), ' s'

    if (file_output_open('native_target.nc', output_handle, mode=FILE_MODE_APPEND, nRecords=nRecordsOut) /= 0) then
        write(0,*) 'Error: problemas abrindo o arquivo de saida'
        stat = mpas_mesh_free(source_mesh)
        stat = target_mesh_free(destination_mesh)
        stat = remap_info_free(remap_info)
        stop 6
    end if

    if (nRecordsOut /= 0) then
        write(0,*) 'Arquivo de saida existente ja tem ', nRecordsOut, ' registros'
    else
        write(0,*) 'Criado novo arquivo de saida (native_target.nc)'
    end if

    stat = field_list_init(include_field_list, exclude_field_list)

    do iFile=3,nArgs
        call get_command_argument(iFile, data_filename)
        write(0,*) 'Remapeando campos de '''//trim(data_filename)//''''

        if (scan_input_open(data_filename, handle, nRecords=nRecordsIn) /= 0) then
            write(0,*) 'Error: problemas abrindo o arquivo de dados '//trim(data_filename)
            stat = file_output_close(output_handle)
            stat = mpas_mesh_free(source_mesh)
            stat = target_mesh_free(destination_mesh)
            stat = remap_info_free(remap_info)
            stop 7
        end if

        write(0,*) 'Arquivo de entrada tem ', nRecordsIn, ' registros'

        if (nRecordsOut == 0) then
            write(0,*) 'Definindo campos no arquivo de saida'

            ! remap_get_target_latitudes/longitudes (remapper.F90) assumem
            ! semantica de grade regular (latitude varia so' ao longo da
            ! dimensao 'latitude', que no nosso modo scatter tem tamanho 1)
            ! -- por isso a variavel 'latitude' de saida acaba com um unico
            ! valor (o do primeiro ponto-alvo), sem sentido no modo scatter.
            ! Mantemos essas duas chamadas como estao (mexer na ordem de
            ! definicao de dimensoes quebrou o arquivo netCDF gerado -- ver
            ! historico) e ADICIONAMOS 'target_latitude'/'target_longitude'
            ! por baixo, com o valor correto de cada ponto-alvo (mesma
            ! dimensao 'longitude' que a variavel 'longitude' original ja
            ! usa corretamente). Downstream: usar target_latitude/
            ! target_longitude (ou, equivalentemente, latCell/lonCell do
            ! proprio arquivo de malha-alvo, na mesma ordem), NUNCA a
            ! variavel 'latitude' deste arquivo.
            stat = remap_get_target_latitudes(remap_info, target_field)
            stat = file_output_register_field(output_handle, target_field)
            stat = free_target_field(target_field)

            stat = remap_get_target_longitudes(remap_info, target_field)
            stat = file_output_register_field(output_handle, target_field)
            stat = free_target_field(target_field)

            call build_scatter_coord_field('target_latitude', target_lat2d(:,1), nCellsTarget, target_field)
            stat = file_output_register_field(output_handle, target_field)
            stat = free_target_field(target_field)

            call build_scatter_coord_field('target_longitude', target_lon2d(:,1), nCellsTarget, target_field)
            stat = file_output_register_field(output_handle, target_field)
            stat = free_target_field(target_field)

            do while (scan_input_next_field(handle, field) == 0)
                if (can_remap_field(field) .and. &
                    should_remap_field(field, include_field_list, exclude_field_list)) then
                    stat = remap_field_dryrun(remap_info, field, target_field)
                    stat = file_output_register_field(output_handle, target_field)
                    stat = copy_field_atts(handle, field, output_handle, target_field)
                    stat = free_target_field(target_field)
                end if
                stat = scan_input_free_field(field)
            end do

            stat = remap_get_target_latitudes(remap_info, target_field)
            stat = file_output_write_field(output_handle, target_field, frame=0)
            stat = free_target_field(target_field)

            stat = remap_get_target_longitudes(remap_info, target_field)
            stat = file_output_write_field(output_handle, target_field, frame=0)
            stat = free_target_field(target_field)

            call build_scatter_coord_field('target_latitude', target_lat2d(:,1), nCellsTarget, target_field)
            stat = file_output_write_field(output_handle, target_field, frame=0)
            stat = free_target_field(target_field)

            call build_scatter_coord_field('target_longitude', target_lon2d(:,1), nCellsTarget, target_field)
            stat = file_output_write_field(output_handle, target_field, frame=0)
            stat = free_target_field(target_field)

            stat = add_latlon_atts(output_handle)
        end if

        do iRec=1,nRecordsIn
            stat = scan_input_rewind(handle)

            do while (scan_input_next_field(handle, field) == 0)
                if (can_remap_field(field) .and. &
                    should_remap_field(field, include_field_list, exclude_field_list)) then
                    write(0,*) 'Remapeando campo '//trim(field % name)//', frame ', irec

                    call timer_start(read_timer)
                    stat = scan_input_read_field(field, frame=iRec)
                    call timer_stop(read_timer)

                    call timer_start(remap_timer)
                    stat = remap_field(remap_info, field, target_field)
                    call timer_stop(remap_timer)

                    call timer_start(write_timer)
                    stat = file_output_write_field(output_handle, target_field, frame=(nRecordsOut+iRec))
                    call timer_stop(write_timer)

                    stat = free_target_field(target_field)
                end if
                stat = scan_input_free_field(field)
            end do
        end do

        nRecordsOut = nRecordsOut + nRecordsIn
        stat = scan_input_close(handle)
    end do

    stat = file_output_close(output_handle)
    stat = mpas_mesh_free(source_mesh)
    stat = mpas_mesh_free(target_native_mesh)
    stat = target_mesh_free(destination_mesh)
    stat = remap_info_free(remap_info)
    stat = field_list_finalize(include_field_list, exclude_field_list)
    deallocate(target_lat2d)
    deallocate(target_lon2d)

    call timer_stop(total_timer)
    write(0,*) ' '
    write(0,'(a,f10.6)') 'Tempo total: ', timer_time(total_timer)
    write(0,*) ' '

    stop

contains

    ! Constroi um target_field_type 1-D de coordenada (latitude ou
    ! longitude), indexado pela dimensao 'longitude' (tamanho
    ! nCellsTarget) -- ver comentario acima sobre por que nao usamos
    ! remap_get_target_latitudes/longitudes do modulo remapper para isso.
    subroutine build_scatter_coord_field(coord_name, values_rad, nPts, out_field)

        implicit none

        character (len=*), intent(in) :: coord_name
        real, dimension(:), intent(in) :: values_rad
        integer, intent(in) :: nPts
        type (target_field_type), intent(out) :: out_field

        out_field % name = coord_name
        out_field % xtype = FIELD_TYPE_REAL
        out_field % ndims = 1
        out_field % isTimeDependent = .false.

        allocate(out_field % dimnames(1))
        allocate(out_field % dimlens(1))
        out_field % dimnames(1) = 'longitude'
        out_field % dimlens(1) = nPts

        allocate(out_field % array1r(nPts))
        out_field % array1r(:) = values_rad(1:nPts) * rad2deg

    end subroutine build_scatter_coord_field

end program hinterp_native
