program proto_scatter

    use mpas_mesh
    use target_mesh
    use remapper
    use scan_input

    implicit none

    type (mpas_mesh_type) :: source_mesh
    type (target_mesh_type) :: destination_mesh
    type (remap_info_type) :: remap_info
    type (input_handle_type) :: handle
    type (input_field_type) :: field
    type (target_field_type) :: target_field

    character (len=1024) :: mesh_filename, data_filename
    integer :: stat, nRecords, i
    integer, parameter :: nPts = 5
    real, dimension(nPts,1), target :: lat2d, lon2d

    mesh_filename = 'test_mesh.nc'
    data_filename = 'test_mesh.nc'

    ! Scatter target points (radians), built from values printed by the
    ! Python inspection step:
    !   pts 1-4: exact cell centers (100, 500, 1000, 1500) -> expect exact recovery
    !   pt 5   : midpoint between cell 500 and neighbor cell 1419 (0-based)
    !            -> expect barycentric-interpolated value, compared against
    !               the analytic field value at that lat/lon
    lat2d(1,1) = 0.733280;  lon2d(1,1) = 1.973043
    lat2d(2,1) = 0.675239;  lon2d(2,1) = -0.192258
    lat2d(3,1) = -0.693280; lon2d(3,1) = 0.177013
    lat2d(4,1) = -0.276597; lon2d(4,1) = 0.794355
    lat2d(5,1) = 0.5*(0.675239 + 0.747407); lon2d(5,1) = 0.5*(-0.192258 + (-0.164590))

    write(0,*) 'Setting up scatter target mesh with ', nPts, ' points'
    stat = target_mesh_setup(destination_mesh, lat2d=lat2d, lon2d=lon2d)
    if (stat /= 0) then
        write(0,*) 'Error in target_mesh_setup'
        stop 1
    end if
    write(0,*) 'irank=', destination_mesh % irank, ' nLat=', destination_mesh % nLat, ' nLon=', destination_mesh % nLon

    write(0,*) 'Reading source MPAS mesh from ', trim(mesh_filename)
    stat = mpas_mesh_setup(mesh_filename, source_mesh)
    if (stat /= 0) then
        write(0,*) 'Error in mpas_mesh_setup'
        stop 2
    end if

    write(0,*) 'Computing barycentric remap weights (Delaunay dual)'
    stat = remap_info_setup(source_mesh, destination_mesh, remap_info)
    if (stat /= 0) then
        write(0,*) 'Error in remap_info_setup'
        stop 3
    end if

    stat = scan_input_open(data_filename, handle, nRecords=nRecords)
    if (stat /= 0) then
        write(0,*) 'Error opening data file'
        stop 4
    end if

    stat = scan_input_for_field(handle, 'test_smooth', field)
    if (stat /= 0) then
        write(0,*) 'Error: field test_smooth not found'
        stop 5
    end if

    stat = scan_input_read_field(field, frame=1)
    if (stat /= 0) then
        write(0,*) 'Error reading field test_smooth'
        stop 6
    end if

    stat = remap_field_dryrun(remap_info, field, target_field)
    stat = remap_field(remap_info, field, target_field)

    write(0,*) 'target_field ndims=', target_field % ndims
    write(0,*) 'target_field dimlens=', target_field % dimlens

    write(*,*) '--- RESULTS (interpolated via barycentric Delaunay-dual remap) ---'
    do i=1,nPts
        write(*,'(a,i2,a,f12.6,a,f12.6)') 'pt ', i, ': interpolated=', target_field % array2r(i,1), &
            '  analytic=', cos(lat2d(i,1))*sin(2.0*lon2d(i,1))
    end do

    stat = free_target_field(target_field)
    stat = scan_input_free_field(field)
    stat = scan_input_close(handle)
    stat = mpas_mesh_free(source_mesh)
    stat = target_mesh_free(destination_mesh)
    stat = remap_info_free(remap_info)

end program proto_scatter
