!> @file
!! @brief Define a set of utilty procedures which use ESMF
!! @author Denise.Worthen@noaa.gov
!!
!> This module defines the RouteHandle and mapping procedures
!! @author Denise.Worthen@noaa.gov
module utils_esmf_mod

  use ESMF
  use netcdf
  use init_mod  , only : do_ocnprep, debug, logunit, vardefs, fsrc, fdst, ftype, nxr, nyr
  use utils_mod , only : dumpnc, remap
  use arrays_mod, only : maskspval, mask3d

  implicit none

  private

  type(ESMF_RouteHandle) :: rh             !< an ESMF RouteHandle
  type(ESMF_DynamicMask) :: dynamicLevMask !< an ESMF dynamicMask object
  type(ESMF_Mesh)        :: meshsrc        !< an ESMF mesh for the source grid
  type(ESMF_Mesh)        :: meshdst        !< an ESMF mesh for destination grids

  integer :: srcTermProcessing = 0         !< The source term processing flag, required for Dynamic Masking

  interface remapRH
     module procedure remapRH1d
     module procedure remapRH2d
     module procedure remapRH1ddyn
     module procedure remapRH2ddyn
  end interface remapRH

  interface rotremap
     module procedure rotremap2d
     module procedure rotremap3d
  end interface rotremap

  public :: createRH
  public :: remapRH
  public :: rotremap
  public :: ChkErr

  character(len=*), parameter :: u_FILE_u = __FILE__   !< a character string
contains
  !> Create a RH
  !!
  !! @param[in]  srcmeshfile  the file name of the source mesh
  !! @param[in]  dstmeshfile  the file name of the destination mesh
  !! @param[out] rc           an error return code
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine createRH(srcmeshfile,dstmeshfile,rc)

    character(len=*), intent(in)  :: srcmeshfile
    character(len=*), intent(in)  :: dstmeshfile
    integer,          intent(out) :: rc

    ! local variables
    type(ESMF_Field)             :: fldsrc
    type(ESMF_Field)             :: flddst
    type(ESMF_RegridMethod_Flag) :: regridmethod
    type(ESMF_ExtrapMethod_Flag) :: extrapmethod
    type(ESMF_Field)             :: dststatusfield
    integer, pointer             :: dststatus(:)
    character(len=20)            :: subname = 'remapRH1d'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a)')'enter '//trim(subname)
    rc = ESMF_SUCCESS

    ! use nstod for ice to maintain thermodynamically consistent values
    ! w/in layers and categories
    if (do_ocnprep) then
       regridmethod = ESMF_REGRIDMETHOD_BILINEAR
       extrapmethod = ESMF_EXTRAPMETHOD_NEAREST_IDAVG
    else
       regridmethod = ESMF_REGRIDMETHOD_NEAREST_STOD
       extrapmethod = ESMF_EXTRAPMETHOD_NEAREST_STOD
    end if

    meshsrc = ESMF_MeshCreate(filename=trim(srcmeshfile), fileformat=ESMF_FILEFORMAT_ESMFMESH, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) call ESMF_Finalize(endflag=ESMF_END_ABORT)
    fldsrc = ESMF_FieldCreate(meshsrc, ESMF_TYPEKIND_R8, name='mshsrc', meshloc=ESMF_MESHLOC_ELEMENT, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) call ESMF_Finalize(endflag=ESMF_END_ABORT)

    meshdst = ESMF_MeshCreate(filename=trim(dstmeshfile), fileformat=ESMF_FILEFORMAT_ESMFMESH, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) call ESMF_Finalize(endflag=ESMF_END_ABORT)
    flddst = ESMF_FieldCreate(meshdst, ESMF_TYPEKIND_R8, name='mshdst', meshloc=ESMF_MESHLOC_ELEMENT, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) call ESMF_Finalize(endflag=ESMF_END_ABORT)

    dststatusfield = ESMF_FieldCreate(meshdst, ESMF_TYPEKIND_I4, meshloc=ESMF_MESHLOC_ELEMENT, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call ESMF_FieldGet(dststatusfield, farrayptr=dststatus, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call ESMF_FieldRegridStore(fldsrc, flddst, routehandle=rh, &
         srcMaskValues=(/0/), dstMaskValues=(/0/),             &
         regridMethod=regridmethod,                            &
         extrapMethod=extrapmethod,                            &
         polemethod=ESMF_POLEMETHOD_ALLAVG,                    &
         ignoreDegenerate=.true.,                              &
         srcTermProcessing=srcTermProcessing,                  &
         dstStatusField=dststatusfield,                        &
         unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) call ESMF_Finalize(endflag=ESMF_END_ABORT)

    ! Create a dynamic mask object
    call ESMF_DynamicMaskSetR8R8R8(dynamicLevMask, dynamicSrcMaskValue=maskspval, &
         dynamicMaskRoutine=DynLevMaskProc, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    if (debug) then
       call dumpnc(trim(ftype)//'.'//trim(fdst)//'.dststat.nc', 'dststat',        &
            dims=(/nxr,nyr/), field=real(dststatus,8))
    end if

    if (debug)write(logunit,'(a)')'exit '//trim(subname)
  end subroutine createRH

  !> Remap a field of nlen via ESMF RH
  !!
  !! @param[in]  kk           the vertical or category index
  !! @param[in]  src_field    the field on the source grid
  !! @param[out] dst_field    the field on the destination grid
  !! @param[out] rc           an error return code
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine remapRH1d(kk,src_field,dst_field,rc)

    integer,      intent(in)  :: kk
    real(kind=8), intent(in)  :: src_field(:)
    real(kind=8), intent(out) :: dst_field(:)
    integer,      intent(out) :: rc

    ! local variables
    type(ESMF_Field)      :: fldsrc
    type(ESMF_Field)      :: flddst
    real(kind=8), pointer :: srcptr(:), dstptr(:)
    character(len=20)     :: subname = 'remapRH1d'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a,i5)')'enter '//trim(subname)//' ',kk
    rc = ESMF_SUCCESS

    fldsrc = ESMF_FieldCreate(meshsrc, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT,rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    flddst = ESMF_FieldCreate(meshdst, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT,rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_FieldGet(fldsrc, farrayptr=srcptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call ESMF_FieldGet(flddst, farrayptr=dstptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    srcptr = src_field
    if (ESMF_RouteHandleIsCreated(rh,rc=rc)) then
       call ESMF_FieldRegrid(fldsrc, flddst, routehandle=rh, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    else
       call ESMF_LogWrite(trim(subname)//": RH not created ", ESMF_LOGMSG_INFO)
       rc=ESMF_FAILURE
    end if
    dst_field = dstptr

    if (debug)write(logunit,'(a,i5)')'exit '//trim(subname)//' ',kk
  end subroutine remapRH1d

  !> Remap a packed field of nflds,nlen via ESMF RH
  !!
  !! @param[in]  src_field    the field on the source grid
  !! @param[out] dst_field    the field on the destination grid
  !! @param[out] rc           an error return code
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine remapRH2d(src_field,dst_field,rc)

    real(kind=8), intent(in)  :: src_field(:,:)
    real(kind=8), intent(out) :: dst_field(:,:)
    integer,      intent(out) :: rc

    ! local variables
    type(ESMF_Field)      :: fldsrc
    type(ESMF_Field)      :: flddst
    real(kind=8), pointer :: srcptr(:,:), dstptr(:,:)
    character(len=20)     :: subname = 'remapRH2d'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a)')'enter '//trim(subname)
    rc = ESMF_SUCCESS

    fldsrc = ESMF_FieldCreate(meshsrc, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT, &
         ungriddedLbound=(/1/), ungriddedUbound=(/size(src_field,1)/),                 &
         gridToFieldMap=(/2/), rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    flddst = ESMF_FieldCreate(meshdst, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT, &
         ungriddedLbound=(/1/), ungriddedUbound=(/size(dst_field,1)/),                 &
         gridToFieldMap=(/2/), rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_FieldGet(fldsrc, farrayptr=srcptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call ESMF_FieldGet(flddst, farrayptr=dstptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    srcptr = src_field
    if (ESMF_RouteHandleIsCreated(rh,rc=rc)) then
       call ESMF_FieldRegrid(fldsrc, flddst, routehandle=rh, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    else
       call ESMF_LogWrite(trim(subname)//": RH not created ", ESMF_LOGMSG_INFO)
       rc=ESMF_FAILURE
    end if
    dst_field = dstptr

    if (debug)write(logunit,'(a)')'exit '//trim(subname)
  end subroutine remapRH2d

  !> Remap a field of nlen via ESMF RH with dynamic masking
  !!
  !! @param[in]  kk           the vertical or category index
  !! @param[in]  src_field    the field on the source grid
  !! @param[in]  hmask        the mask field to use with dynamic masking
  !! @param[out] dst_field    the field on the destination grid
  !! @param[out] rc           an error return code
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine remapRH1ddyn(kk,src_field,dst_field,hmask,rc)

    !nflds,nlen
    integer,      intent(in)  :: kk
    real(kind=8), intent(in)  :: src_field(:)
    real(kind=8), intent(in)  :: hmask(:)
    real(kind=8), intent(out) :: dst_field(:)
    integer,      intent(out) :: rc

    ! local variables
    type(ESMF_Field)      :: fldsrc
    type(ESMF_Field)      :: flddst
    real(kind=8), pointer :: srcptr(:), dstptr(:)
    character(len=20)     :: subname = 'remapRH1ddyn'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a,i5)')'enter '//trim(subname)//' ',kk
    rc = ESMF_SUCCESS

    fldsrc = ESMF_FieldCreate(meshsrc, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    flddst = ESMF_FieldCreate(meshdst, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_FieldGet(fldsrc, farrayptr=srcptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call ESMF_FieldGet(flddst, farrayptr=dstptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    srcptr = src_field
    where(hmask .eq. maskspval)srcptr = maskspval

    if (ESMF_RouteHandleIsCreated(rh,rc=rc)) then
       call ESMF_FieldRegrid(fldsrc, flddst, routehandle=rh, dynamicMask=dynamicLevMask, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    else
       call ESMF_LogWrite(trim(subname)//": RH not created ", ESMF_LOGMSG_INFO)
       rc=ESMF_FAILURE
    end if
    dst_field = dstptr

    if (debug)write(logunit,'(a,i5)')'exit '//trim(subname)//' ',kk
  end subroutine remapRH1ddyn

  !> Remap a packed field of nflds,nlen via ESMF RH with dyanmic masking
  !!
  !! @param[in]  kk           the vertical or category index
  !! @param[in]  src_field    the field on the source grid
  !! @param[in]  hmask        the mask field to use with dynamic masking
  !! @param[out] dst_field    the field on the destination grid
  !! @param[out] rc           an error return code
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine remapRH2ddyn(kk,src_field,dst_field,hmask,rc)

    integer,      intent(in)  :: kk
    real(kind=8), intent(in)  :: src_field(:,:)
    real(kind=8), intent(in)  :: hmask(:)
    real(kind=8), intent(out) :: dst_field(:,:)
    integer,      intent(out) :: rc

    ! local variables
    type(ESMF_Field)      :: fldsrc
    type(ESMF_Field)      :: flddst
    integer               :: i,n
    real(kind=8), pointer :: srcptr(:,:), dstptr(:,:)
    character(len=20)     :: subname = 'remapRH2ddyn'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a,i5)')'enter '//trim(subname)//' ',kk
    rc = ESMF_SUCCESS

    fldsrc = ESMF_FieldCreate(meshsrc, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT, &
         ungriddedLbound=(/1/), ungriddedUbound=(/size(src_field,1)/),                 &
         gridToFieldMap=(/2/), rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    flddst = ESMF_FieldCreate(meshdst, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT, &
         ungriddedLbound=(/1/), ungriddedUbound=(/size(dst_field,1)/),                 &
         gridToFieldMap=(/2/), rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_FieldGet(fldsrc, farrayptr=srcptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call ESMF_FieldGet(flddst, farrayptr=dstptr, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    srcptr = src_field
    do n = 1,ubound(src_field,2)
       do i = 1,ubound(src_field,1)
          if(hmask(n) .eq. maskspval)srcptr(i,n) = maskspval
       end do
    end do

    if (ESMF_RouteHandleIsCreated(rh,rc=rc)) then
       call ESMF_FieldRegrid(fldsrc, flddst, routehandle=rh, dynamicMask=dynamicLevMask, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    else
       call ESMF_LogWrite(trim(subname)//": RH not created ", ESMF_LOGMSG_INFO)
       rc=ESMF_FAILURE
    end if
    dst_field = dstptr

    if (debug)write(logunit,'(a,i5)')'exit '//trim(subname)//' ',kk
  end subroutine remapRH2ddyn

  !> Rotate 2D vectors from EN->IJ and map back to native staggers
  !!
  !! @param[in]  wdir     the path to the required ESMF regridding weights
  !! @param[in]  cosrot   the cosine of the rotation angle
  !! @param[in]  sinrot   the sine of the rotation angle
  !! @param[in]  vars     a structure describing the variable metadata
  !! @param[in]  dims     the dimensions of the fields
  !! @param[in]  nflds    the number of fields in the packed array
  !! @param[out] fields   the rotated and mapped fields
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine rotremap2d(wdir, vars, cosrot, sinrot, dims, nflds, fields)

    character(len=*), intent(in)    :: wdir
    real(kind=8),     intent(in)    :: cosrot(:),sinrot(:)
    type(vardefs),    intent(in)    :: vars(:)
    integer,          intent(in)    :: dims(:)
    integer,          intent(in)    :: nflds
    real(kind=8),     intent(inout) :: fields(:,:)

    integer            :: n, idx1, idx2
    real(kind=8), allocatable, dimension(:) :: urot, vrot
    character(len=10)  :: vgrid1, vgrid2
    character(len=240) :: wgtsfile
    character(len=20)  :: subname = 'rotremap2d'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a)')'enter '//trim(subname)

    idx1 = 0; idx2 = 0
    do n = 1,nflds
       if (len_trim(vars(n)%var_pair) > 0 .and. idx1 .eq. 0) then
          idx1 = n
          idx2 = n+1
       end if
    end do
    if (idx1 .eq. 0)return

    vgrid1 = vars(idx1)%var_grid(1:2)
    vgrid2 = vars(idx1)%var_pair_grid(1:2)

    allocate(urot(1:dims(1)*dims(2))); urot = 0.0
    allocate(vrot(1:dims(1)*dims(2))); vrot = 0.0
    urot(:) = fields(idx1,:)*cosrot(:) - fields(idx2,:)*sinrot(:)
    vrot(:) = fields(idx2,:)*cosrot(:) + fields(idx1,:)*sinrot(:)

    wgtsfile = trim(wdir)//'tripole.'//trim(fdst)//'.Ct.to.'//trim(vgrid1)//'.bilinear.nc'
    call remap(trim(wgtsfile), urot, fields(idx1,:))
    if (debug) write(logunit,'(a)')'use '//trim(wgtsfile)//' to restagger from Ct to '//trim(vgrid1)

    wgtsfile = trim(wdir)//'tripole.'//trim(fdst)//'.Ct.to.'//trim(vgrid2)//'.bilinear.nc'
    call remap(trim(wgtsfile), vrot, fields(idx2,:))
    if (debug) write(logunit,'(a)')'use '//trim(wgtsfile)//' to restagger from Ct to '//trim(vgrid2)

    if (debug)write(logunit,'(a)')'exit '//trim(subname)
  end subroutine rotremap2d

  !> Rotate 3D vectors on nlevs from EN->IJ and map back to native staggers
  !!
  !! @param[in]  wdir     the path to the required ESMF regridding weights
  !! @param[in]  cosrot   the cosine of the rotation angle
  !! @param[in]  sinrot   the sine of the rotation angle
  !! @param[in]  vars     a structure describing the variable metadata
  !! @param[in]  dims     the dimensions of the fields
  !! @param[in]  nflds    the number of fields in the packed array
  !! @param[out] fields   the rotated and mapped fields
  !!
  !! @author Denise.Worthen@noaa.gov
  subroutine rotremap3d(wdir, vars, cosrot, sinrot, dims, nflds, fields)

    character(len=*), intent(in)    :: wdir
    real(kind=8),     intent(in)    :: cosrot(:),sinrot(:)
    type(vardefs),    intent(in)    :: vars(:)
    integer,          intent(in)    :: dims(:)
    integer,          intent(in)    :: nflds
    real(kind=8),     intent(inout) :: fields(:,:,:)

    integer            :: k, n, idx1, idx2
    real(kind=8), allocatable, dimension(:) :: urot, vrot
    character(len=10)  :: vgrid1, vgrid2
    character(len=240) :: wgtsfile
    character(len=20)  :: subname = 'rotremap3d'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a)')'enter '//trim(subname)

    idx1 = 0; idx2 = 0
    do n = 1,nflds
       if (len_trim(vars(n)%var_pair) > 0 .and. idx1 .eq. 0) then
          idx1 = n
          idx2 = n+1
       end if
    end do
    if (idx1 .eq. 0)return

    vgrid1 = vars(idx1)%var_grid(1:2)
    vgrid2 = vars(idx1)%var_pair_grid(1:2)
    if (debug) write(logunit,'(a)')'restagger from Ct to '//trim(vgrid1)//' and '//trim(vgrid2)

    allocate(urot(1:dims(1)*dims(2))); urot = 0.0
    allocate(vrot(1:dims(1)*dims(2))); vrot = 0.0
    do k = 1,dims(3)
       urot(:) = fields(idx1,k,:)*cosrot(:) - fields(idx2,k,:)*sinrot(:)
       vrot(:) = fields(idx2,k,:)*cosrot(:) + fields(idx1,k,:)*sinrot(:)
       wgtsfile = trim(wdir)//'tripole.'//trim(fdst)//'.Ct.to.'//trim(vgrid1)//'.bilinear.nc'
       call remap(trim(wgtsfile), urot, fields(idx1,k,:))
       wgtsfile = trim(wdir)//'tripole.'//trim(fdst)//'.Ct.to.'//trim(vgrid2)//'.bilinear.nc'
       call remap(trim(wgtsfile), vrot, fields(idx2,k,:))
    end do

    if (debug)write(logunit,'(a)')'exit '//trim(subname)
  end subroutine rotremap3d

  !> A dynamic mask procedure for ocean vertical levels
  !!
  !! @param[in]  dynamicMaskList      an ESMF Dynamic Mask element list
  !! @param[in]  dynamicSrcMaskValue  the masking value on the source grid (optional)
  !! @param[in]  dynamicDstMaskValue  the masking value on the destination grid (optional)
  !! @param[out] rc                   an error return code
  !!
  !! @author Adapted from example in ESMF Reference manual (37.2.6 Dynamic Masking)
  subroutine dynLevMaskProc(dynamicMaskList, dynamicSrcMaskValue, dynamicDstMaskValue, rc)

    ! input/output arguments
    type(ESMF_DynamicMaskElementR8R8R8) , pointer :: dynamicMaskList(:)
    real(ESMF_KIND_R8), intent(in), optional      :: dynamicSrcMaskValue
    real(ESMF_KIND_R8), intent(in), optional      :: dynamicDstMaskValue
    integer           , intent(out)               :: rc

    ! local variables
    integer  :: i, j
    real(ESMF_KIND_R8) :: renorm
    character(len=20)  :: subname = 'dynLevMaskProc'
    !----------------------------------------------------------------------------

    if (debug)write(logunit,'(a)')'enter '//trim(subname)
    rc = ESMF_SUCCESS

    if (associated(dynamicMaskList)) then
       do i=1, size(dynamicMaskList)
          dynamicMaskList(i)%dstElement = 0.0 ! set to zero
          renorm = 0.0 ! reset
          do j = 1, size(dynamicMaskList(i)%factor)
             if (dynamicSrcMaskValue /= dynamicMaskList(i)%srcElement(j)) then
                dynamicMaskList(i)%dstElement = dynamicMaskList(i)%dstElement + &
                     (dynamicMaskList(i)%factor(j) * dynamicMaskList(i)%srcElement(j))
                renorm = renorm + dynamicMaskList(i)%factor(j)
             endif
          enddo
          if (renorm > 0.0) then
             dynamicMaskList(i)%dstElement = dynamicMaskList(i)%dstElement / renorm
          else if (present(dynamicSrcMaskValue)) then
             dynamicMaskList(i)%dstElement = dynamicSrcMaskValue
          else
             rc = ESMF_RC_ARG_BAD  ! error detected
             return
          endif
       enddo
    endif
    if (debug)write(logunit,'(a)')'exit '//trim(subname)

  end subroutine DynLevMaskProc

  !> Handle ESMF errors
  !!
  !! @param[in]  rc         return code to check
  !! @param[in]  line       integer source line number
  !! @param[in]  file       user-provided source file name
  !! @return     ChkErr     a logical indicating if an ESMF error was detected
  !!
  !! @author Denise.Worthen@noaa.gov
  logical function ChkErr(rc, line, file)
    integer, intent(in) :: rc
    integer, intent(in) :: line
    character(len=*), intent(in) :: file
    integer :: lrc
    !----------------------------------------------------------------------------
    ChkErr = .false.
    lrc = rc
    if (ESMF_LogFoundError(rcToCheck=lrc, msg=ESMF_LOGERR_PASSTHRU, line=line, file=file)) then
       ChkErr = .true.
    endif
  end function ChkErr
end module utils_esmf_mod
