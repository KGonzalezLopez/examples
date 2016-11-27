! md_nvt_lj_le.f90
! MD, NVT ensemble, Lees-Edwards boundaries
PROGRAM md_nvt_lj_le

  USE, INTRINSIC :: iso_fortran_env, ONLY : input_unit, output_unit, error_unit, iostat_end, iostat_eor

  USE config_io_module, ONLY : read_cnf_atoms, write_cnf_atoms
  USE averages_module,  ONLY : time_stamp, run_begin, run_end, blk_begin, blk_end, blk_add, variable_type
  USE md_module,        ONLY : introduction, conclusion, allocate_arrays, deallocate_arrays, &
       &                       force, r, v, f, n, potential_type

  IMPLICIT NONE

  ! Takes in a configuration of atoms (positions, velocities)
  ! Cubic periodic boundary conditions, with Lees-Edwards shear
  ! Conducts molecular dynamics, SLLOD algorithm, with isokinetic thermostat
  ! Refs: Pan et al J Chem Phys 122 094114 (2005)

  ! Reads several variables and options from standard input using a namelist nml
  ! Leave namelist empty to accept supplied defaults

  ! Positions r are divided by box length after reading in and we assume mass=1 throughout
  ! However, input configuration, output configuration, most calculations, and all results 
  ! are given in simulation units defined by the model
  ! For example, for Lennard-Jones, sigma = 1, epsilon = 1

  ! Despite the program name, there is nothing here specific to Lennard-Jones
  ! The model is defined in md_module

  ! Most important variables
  REAL :: box         ! Box length
  REAL :: density     ! Density
  REAL :: dt          ! Time step
  REAL :: strain_rate ! Strain_rate (velocity gradient) dv_x/dr_y
  REAL :: strain      ! Strain (integrated velocity gradient) dr_x/dr_y
  REAL :: r_cut       ! Potential cutoff distance

  ! Quantities to be averaged
  TYPE(variable_type), DIMENSION(:), ALLOCATABLE :: variables

  ! Composite interaction = pot & cut & vir & lap & ovr variables
  TYPE(potential_type) :: total

  INTEGER            :: blk, stp, nstep, nblock, ioerr
  REAL, DIMENSION(3) :: vcm

  CHARACTER(len=4), PARAMETER :: cnf_prefix = 'cnf.'
  CHARACTER(len=3), PARAMETER :: inp_tag    = 'inp'
  CHARACTER(len=3), PARAMETER :: out_tag    = 'out'
  CHARACTER(len=3)            :: sav_tag    = 'sav' ! May be overwritten with block number

  NAMELIST /nml/ nblock, nstep, r_cut, dt, strain_rate

  WRITE ( unit=output_unit, fmt='(a)' ) 'md_nvt_lj_le'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Molecular dynamics, constant-NVT ensemble, Lees-Edwards'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Particle mass=1 throughout'
  CALL introduction ( output_unit )
  CALL time_stamp ( output_unit )

  ! Set sensible default run parameters for testing
  nblock      = 10
  nstep       = 1000
  r_cut       = 2.5
  dt          = 0.005
  strain_rate = 0.01

  ! Read run parameters from namelist
  ! Comment out, or replace, this section if you don't like namelists
  READ ( unit=input_unit, nml=nml, iostat=ioerr )
  IF ( ioerr /= 0 ) THEN
     WRITE ( unit=error_unit, fmt='(a,i15)') 'Error reading namelist nml from standard input', ioerr
     IF ( ioerr == iostat_eor ) WRITE ( unit=error_unit, fmt='(a)') 'End of record'
     IF ( ioerr == iostat_end ) WRITE ( unit=error_unit, fmt='(a)') 'End of file'
     STOP 'Error in md_nvt_lj_le'
  END IF

  ! Write out run parameters
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of blocks',          nblock
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of steps per block', nstep
  WRITE ( unit=output_unit, fmt='(a,t40,f15.6)' ) 'Potential cutoff distance', r_cut
  WRITE ( unit=output_unit, fmt='(a,t40,f15.6)' ) 'Time step',                 dt
  WRITE ( unit=output_unit, fmt='(a,t40,f15.6)' ) 'Strain rate',               strain_rate

  ! Read in initial configuration and allocate necessary arrays
  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box ) ! First call just to get n and box
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of particles',   n
  WRITE ( unit=output_unit, fmt='(a,t40,f15.6)' ) 'Simulation box length', box
  density = REAL(n) / box**3
  WRITE ( unit=output_unit, fmt='(a,t40,f15.6)' ) 'Density', density
  CALL allocate_arrays ( box, r_cut )
  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box, r, v ) ! Second call gets r and v
  strain = 0.0                                              ! For simplicity assume that this is true
  r(:,:) = r(:,:) / box                                     ! Convert positions to box units
  r(1,:) = r(1,:) - ANINT ( r(2,:) ) * strain               ! Extra correction (box=1 units)
  r(:,:) = r(:,:) - ANINT ( r(:,:) )                        ! Periodic boundaries (box=1 units)
  vcm(:) = SUM ( v(:,:), dim=2 ) / REAL(n)                  ! Centre-of mass velocity
  v(:,:) = v(:,:) - SPREAD ( vcm(:), dim = 2, ncopies = n ) ! Set COM velocity to zero

  ! Initial forces, potential, etc plus overlap check
  CALL force ( box, r_cut, strain, total )
  IF ( total%ovr ) THEN
     WRITE ( unit=error_unit, fmt='(a)') 'Overlap in initial configuration'
     STOP 'Error in md_nvt_lj_le'
  END IF
  CALL calculate ( 'Initial values' )

  ! Initialize arrays for averaging and write column headings
  CALL run_begin ( output_unit, variables )

  DO blk = 1, nblock ! Begin loop over blocks

     CALL blk_begin

     DO stp = 1, nstep ! Begin loop over steps

        ! Isokinetic SLLOD algorithm (Pan et al)

        CALL a_propagator  ( dt/2.0)
        CALL b1_propagator ( dt/2.0 )

        CALL force ( box, r_cut, strain, total )
        IF ( total%ovr ) THEN
           WRITE ( unit=error_unit, fmt='(a)') 'Overlap in configuration'
           STOP 'Error in md_nvt_lj_le'
        END IF

        CALL b2_propagator ( dt )
        CALL b1_propagator ( dt/2.0 )
        CALL a_propagator  ( dt/2.0 )

        ! Calculate and accumulate variables for this step
        CALL calculate ( )
        CALL blk_add ( variables )

     END DO ! End loop over steps

     CALL blk_end ( blk, output_unit )                              ! Output block averages
     IF ( nblock < 1000 ) WRITE(sav_tag,'(i3.3)') blk               ! Number configuration by block
     CALL write_cnf_atoms ( cnf_prefix//sav_tag, n, box, r*box, v ) ! Save configuration

  END DO ! End loop over blocks

  CALL run_end ( output_unit )

  CALL force ( box, r_cut, strain, total )
  IF ( total%ovr ) THEN ! should never happen
     WRITE ( unit=error_unit, fmt='(a)') 'Overlap in final configuration'
     STOP 'Error in md_nvt_lj_le'
  END IF
  CALL calculate ( 'Final values' )

  CALL write_cnf_atoms ( cnf_prefix//out_tag, n, box, r*box, v ) ! Write out final configuration
  CALL time_stamp ( output_unit )

  CALL deallocate_arrays
  CALL conclusion ( output_unit )

CONTAINS

  SUBROUTINE a_propagator ( t ) ! A propagator
    IMPLICIT NONE
    REAL, INTENT(in) :: t ! Time over which to propagate (typically dt/2)

    REAL :: x

    x = t * strain_rate ! Change in strain (dimensionless)

    r(1,:) = r(1,:) + x * r(2,:)        ! Extra strain term
    r(:,:) = r(:,:) + t * v(:,:) / box  ! Drift half-step (positions in box=1 units)
    strain = strain + x                 ! Advance strain and hence boundaries

    r(1,:) = r(1,:) - ANINT ( r(2,:) ) * strain ! Extra PBC correction (box=1 units)
    r(:,:) = r(:,:) - ANINT ( r(:,:) )          ! Periodic boundaries (box=1 units)

  END SUBROUTINE a_propagator

  SUBROUTINE b1_propagator ( t ) ! B1 propagator
    IMPLICIT NONE
    REAL, INTENT(in) :: t ! Time over which to propagate (typically dt/2)

    REAL :: x, c1, c2
    
    x = t * strain_rate ! Change in strain (dimensionless)

    c1 = x * SUM ( v(1,:)*v(2,:) ) / SUM ( v(:,:)**2 )
    c2 = ( x**2 ) * SUM ( v(2,:)**2 ) / SUM ( v(:,:)**2 )

    v(1,:) = v(1,:) - x*v(2,:)
    v(:,:) = v(:,:) / SQRT ( 1.0 - 2.0*c1 + c2 )

  END SUBROUTINE b1_propagator

  SUBROUTINE b2_propagator ( t ) ! B2 propagator
    IMPLICIT NONE
    REAL, INTENT(in) :: t ! Time over which to propagate (typically dt)

    REAL :: alpha, beta, h, e, dt_factor, prefactor
    
    alpha = SUM ( f(:,:)*v(:,:) ) / SUM ( v(:,:)**2 )
    beta  = SQRT ( SUM ( f(:,:)**2 ) / SUM ( v(:,:)**2 ) )
    h     = ( alpha + beta ) / ( alpha - beta )
    e     = EXP ( -beta * t )

    dt_factor = ( 1 + h - e - h / e ) / ( ( 1 - h ) * beta )
    prefactor = ( 1 - h ) / ( e - h / e )

    v(:,:) = prefactor * ( v(:,:) + dt_factor * f(:,:) )

  END SUBROUTINE b2_propagator

  SUBROUTINE calculate ( string ) 
    USE md_module,       ONLY : potential_lrc, pressure_lrc
    USE averages_module, ONLY : write_variables
    IMPLICIT NONE
    CHARACTER (len=*), INTENT(in), OPTIONAL :: string

    ! This routine calculates all variables of interest and (optionally) writes them out
    ! They are collected together in the variables array, for use in the main program

    TYPE(variable_type) :: e_s, p_s, e_f, p_f, t_k, t_c
    REAL                :: vol, rho, kin, fsq, tmp

    ! Preliminary calculations
    vol = box**3                  ! Volume
    rho = REAL(n) / vol           ! Density
    kin = 0.5*SUM(v**2)           ! NB v(:,:) are taken to be peculiar velocities
    fsq = SUM(f**2)               ! Total squared force
    tmp = 2.0 * kin / REAL(3*n-3) ! Remove three degrees of freedom for momentum conservation

    ! Variables of interest, of type variable_type, containing three components:
    !   %val: the instantaneous value
    !   %nam: used for headings
    !   %method: indicating averaging method
    ! If not set below, %method adopts its default value of avg
    ! The %nam and some other components need only be defined once, at the start of the program,
    ! but for clarity and readability we assign all the values together below

    ! Internal energy (cut-and-shifted) per atom
    ! Total KE plus total cut-and-shifted PE divided by N
    e_s = variable_type ( nam = 'E/N cut&shifted', val = (kin+total%pot)/REAL(n) )

    ! Internal energy (full, including LRC) per atom
    ! LRC plus total KE plus total cut (but not shifted) PE divided by N
    e_f = variable_type ( nam = 'E/N full', val = potential_lrc(rho,r_cut) + (kin+total%cut)/REAL(n) )

    ! Pressure (cut-and-shifted)
    ! Ideal gas contribution plus total virial divided by V 
    p_s = variable_type ( nam = 'P cut&shifted', val = rho*tmp + total%vir/vol )   

    ! Pressure (full, including LRC)
    ! LRC plus ideal gas contribution plus total virial divided by V 
    p_f = variable_type ( nam = 'P full', val = pressure_lrc(rho,r_cut) + rho*tmp + total%vir/vol )

    ! Kinetic temperature
    t_k = variable_type ( nam = 'T kinetic', val = tmp )

    ! Configurational temperature
    ! Total squared force divided by total Laplacian
    t_c = variable_type ( nam = 'T config', val = fsq/total%lap )

    ! Collect together for averaging
    ! Fortran 2003 should automatically allocate this first time
    variables = [ e_s, p_s, e_f, p_f, t_k, t_c ]

    IF ( PRESENT ( string ) ) THEN
       WRITE ( unit=output_unit, fmt='(a)' ) string
       CALL write_variables ( output_unit, variables )
    END IF

  END SUBROUTINE calculate

END PROGRAM md_nvt_lj_le

