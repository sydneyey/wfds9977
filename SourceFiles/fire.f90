MODULE FIRE
 
! Compute combustion 
 
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND
 
IMPLICIT NONE
PRIVATE
CHARACTER(255), PARAMETER :: fireid='$Id: fire.f90 9845 2012-01-16 18:07:29Z mcgratta $'
CHARACTER(255), PARAMETER :: firerev='$Revision: 9845 $'
CHARACTER(255), PARAMETER :: firedate='$Date: 2012-01-16 10:07:29 -0800 (Mon, 16 Jan 2012) $'

TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB) :: Q_UPPER

PUBLIC COMBUSTION, GET_REV_fire
 
CONTAINS
 

SUBROUTINE COMBUSTION(NM)

INTEGER, INTENT(IN) :: NM
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

IF (INIT_HRRPUV) RETURN

CALL POINT_TO_MESH(NM)

! Upper bounds on local HRR per unit volume

Q_UPPER = HRRPUA_SHEET/CELL_SIZE + HRRPUV_AVERAGE

! Call combustion ODE solver
CALL COMBUSTION_GENERAL

TUSED(10,NM)=TUSED(10,NM)+SECOND()-TNOW

END SUBROUTINE COMBUSTION


SUBROUTINE COMBUSTION_GENERAL

! Generic combustion routine for multi step reactions with kinetics either mixing controlled, finite rate, 
! or a temperature threshhold mixed approach

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_DIFF
INTEGER :: I,J,K,NS,NR,II,JJ,KK,IIG,JJG,KKG,IW,N
REAL(EB):: ZZ_GET(0:N_TRACKED_SPECIES),ZZ_MIN=1.E-10_EB,DZZ(0:N_TRACKED_SPECIES),CP,HDIFF
LOGICAL :: DO_REACTION,REACTANTS_PRESENT,Q_EXISTS
TYPE (REACTION_TYPE),POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM,SM0

Q          = 0._EB
D_REACTION = 0._EB
Q_EXISTS = .FALSE.
SM0 => SPECIES_MIXTURE(0)

DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         !Check to see if a reaction is possible
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ILOOP
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         ZZ_GET(0) = 1._EB - MIN(1._EB,SUM(ZZ_GET(1:N_TRACKED_SPECIES)))
         DO_REACTION = .FALSE.
         DO NR=1,N_REACTIONS
            RN=>REACTION(NR)
            REACTANTS_PRESENT = .TRUE.
            DO NS=0,N_TRACKED_SPECIES
               IF (RN%NU(NS)<0._EB .AND. ZZ_GET(NS) < ZZ_MIN) THEN
                  REACTANTS_PRESENT = .FALSE.
                  EXIT
               ENDIF
            END DO            
            IF (.NOT. DO_REACTION) DO_REACTION = REACTANTS_PRESENT     
         END DO
         IF (.NOT. DO_REACTION) CYCLE ILOOP
         DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) ! store old ZZ for divergence term
         ! Easily allow for user selected ODE solver
         SELECT CASE (COMBUSTION_ODE)
            CASE(SINGLE_EXACT)
               CALL ODE_EXACT(I,J,K,ZZ_GET,Q(I,J,K))
            CASE(EXPLICIT_EULER)
               CALL ODE_EXPLICIT_EULER(I,J,K,ZZ_GET,Q(I,J,K))
            CASE(RUNGE_KUTTA_2)
               CALL ODE_RUNGE_KUTTA_2(I,J,K,ZZ_GET,Q(I,J,K))
            CASE(IMPLICIT_TRAPEZOID)
               CALL ODE_IMPLICIT_TRAPEZOID(I,J,K,ZZ_GET,Q(I,J,K))
         END SELECT        

         ! Update RSUM and ZZ       
         IF (ABS(Q(I,J,K)) > ZERO_P) THEN
            Q_EXISTS = .TRUE.
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 
            TMP(I,J,K) = PBAR(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*RHO(I,J,K))
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES)
            ! Divergence term
            DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) - DZZ(1:N_TRACKED_SPECIES)
            CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(I,J,K))
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               CALL GET_SENSIBLE_ENTHALPY_DIFF(N,TMP(I,J,K),HDIFF)
               D_REACTION(I,J,K) = D_REACTION(I,J,K) + ( (SM%RCON-SM0%RCON)/RSUM(I,J,K) - &
                                                         HDIFF/(CP*TMP(I,J,K)) )*DZZ(N)/DT
            ENDDO
         ENDIF

      ENDDO ILOOP
   ENDDO
ENDDO

IF (.NOT. Q_EXISTS) RETURN

! Set Q in the ghost cell, just for better visualization.
DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (WALL(IW)%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY .AND. WALL(IW)%BOUNDARY_TYPE/=OPEN_BOUNDARY) CYCLE
   II  = WALL(IW)%II
   JJ  = WALL(IW)%JJ
   KK  = WALL(IW)%KK
   IIG = WALL(IW)%IIG
   JJG = WALL(IW)%JJG
   KKG = WALL(IW)%KKG
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO

END SUBROUTINE COMBUSTION_GENERAL

SUBROUTINE ODE_EXACT(I,J,K,ZZ_GET,Q_NEW)
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_NEW
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: DZF,Q_BOUND_1,Q_BOUND_2,RATE_CONSTANT,Z_LIMITER,REACTANT_MIN,DT2
LOGICAL :: MIN_FOUND
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

Q_NEW = 0._EB
RN=>REACTION(1)
CALL COMPUTE_RATE_CONSTANT(1,RN%MODE,1,0._EB,RATE_CONSTANT,ZZ_GET,I,J,K)

IF(RATE_CONSTANT < ZERO_P) RETURN

Z_LIMITER = RATE_CONSTANT*MIX_TIME(I,J,K)

DZF = -1._EB
!Check for reactant (i.e. fuel or oxidizer) limited combustion
MIN_FOUND = .FALSE.
REACTANT_MIN=1._EB
DO NS=0,N_TRACKED_SPECIES
   IF (RN%NU(NS) < -ZERO_P) &
      REACTANT_MIN = MIN(REACTANT_MIN,-ZZ_GET(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(SPECIES_MIXTURE(NS)%MW*RN%NU(NS)))
   IF (ABS(Z_LIMITER - REACTANT_MIN) <= SPACING(Z_LIMITER)) THEN
      MIN_FOUND = .TRUE.
      DZF = REACTANT_MIN*(1._EB-EXP(-DT/MIX_TIME(I,J,K)))
      EXIT
   ENDIF
ENDDO

!For product limited combsiton find time of switch from product limited to reactant limited (if it occurs)
!and do two step exact solution
IF (.NOT. MIN_FOUND) THEN
   DT2 = MIX_TIME(I,J,K)*LOG((Z_LIMITER+REACTANT_MIN)/(2._EB*Z_LIMITER))
   IF (DT2 < DT) THEN
      DZF = ZZ_GET(RN%FUEL_SMIX_INDEX) - Z_LIMITER*(EXP(DT2/MIX_TIME(I,J,K))-1._EB)
      REACTANT_MIN = REACTANT_MIN - DZF
      DZF = DZF + REACTANT_MIN*(1._EB-EXP(-(DT-DT2)/MIX_TIME(I,J,K)))
   ELSE
      DZF = ZZ_GET(RN%FUEL_SMIX_INDEX) - Z_LIMITER*(EXP(DT/MIX_TIME(I,J,K))-1._EB)
   ENDIF
ENDIF

DZF = MIN(DZF,ZZ_GET(RN%FUEL_SMIX_INDEX))

!****** TEMP OVERRIDE TO ENSURE SAME RESULTS AS PREVIOUS *******
!DZF = Z_LIMITER*(1._EB-EXP(-DT/MIX_TIME(I,J,K)))
!***************************************************************

Q_BOUND_1 = DZF*RHO(I,J,K)*RN%HEAT_OF_COMBUSTION/DT
Q_BOUND_2 = Q_UPPER
Q_NEW = MIN(Q_BOUND_1,Q_BOUND_2)
DZF = Q_NEW*DT/(RHO(I,J,K)*RN%HEAT_OF_COMBUSTION)         

ZZ_GET = ZZ_GET + DZF*RN%NU*SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW

END SUBROUTINE ODE_EXACT


SUBROUTINE ODE_EXPLICIT_EULER(I,J,K,ZZ_GET,Q_OUT)
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_OUT
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ZZ_0(0:N_TRACKED_SPECIES),ZZ_I(0:N_TRACKED_SPECIES),ZZ_N(0:N_TRACKED_SPECIES),DZZDT(0:N_TRACKED_SPECIES),&
            DT_ODE,DT_NEW,RATE_CONSTANT(1:N_REACTIONS),Q_NR(1:N_REACTIONS),Q_SUM,DT_SUM
INTEGER :: NR,I_TS,NS
INTEGER, PARAMETER :: NODETS=20
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

Q_OUT = 0._EB
ZZ_0 = MAX(0._EB,ZZ_GET)
ZZ_I = ZZ_0
DT_ODE = DT/REAL(NODETS,EB)
DT_NEW = DT_ODE
DT_SUM = 0._EB
I_TS = 1
ODE_LOOP: DO WHILE (DT_SUM < DT)
   DZZDT = 0._EB
   RATE_CONSTANT = 0._EB
   Q_NR = 0._EB
   REACTION_LOOP: DO NR = 1, N_REACTIONS   
      RN => REACTION(NR)      
      CALL COMPUTE_RATE_CONSTANT(NR,RN%MODE,I_TS,Q_OUT,RATE_CONSTANT(NR),ZZ_I,I,J,K)
      IF (RATE_CONSTANT(NR) < ZERO_P) CYCLE REACTION_LOOP
      Q_NR(NR) = RATE_CONSTANT(NR)*RN%HEAT_OF_COMBUSTION*RHO(I,J,K)
      DZZDT = DZZDT + RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANT(NR)
   END DO REACTION_LOOP     
   IF (ALL(DZZDT < ZERO_P)) EXIT ODE_LOOP
   ZZ_N = ZZ_I + DZZDT * DT_NEW

   IF (ANY(ZZ_N < 0._EB)) THEN
      DO NS=0,N_TRACKED_SPECIES
          IF (ZZ_N(NS) < 0._EB .AND. ABS(DZZDT(NS))>ZERO_P) DT_NEW = MIN(DT_NEW,-ZZ_I(NS)/DZZDT(NS))
      ENDDO
   ENDIF  

   Q_SUM = SUM(Q_NR)
   IF (Q_OUT + Q_SUM*DT_NEW > Q_UPPER * DT) THEN
      DT_NEW = MAX(0._EB,(Q_UPPER * DT - Q_OUT))/Q_SUM
      Q_OUT = Q_OUT+Q_SUM*DT_NEW
      ZZ_I = ZZ_I + DZZDT * DT_NEW
      EXIT ODE_LOOP
   ENDIF   
   Q_OUT = Q_OUT+Q_SUM*DT_NEW
   ZZ_I = ZZ_I + DZZDT * DT_NEW
   DT_SUM = DT_SUM + DT_NEW
   IF (DT_NEW < DT_ODE) DT_NEW = DT_ODE
   IF (DT_NEW + DT_SUM > DT) DT_NEW = DT - DT_SUM
   I_TS = I_TS + 1
ENDDO ODE_LOOP

ZZ_GET = ZZ_GET + ZZ_I - ZZ_0
Q_OUT = Q_OUT / DT

RETURN

END SUBROUTINE ODE_EXPLICIT_EULER


SUBROUTINE ODE_RUNGE_KUTTA_2(I,J,K,ZZ_GET,Q_OUT)
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_OUT
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ZZ_0(0:N_TRACKED_SPECIES),ZZ_I(0:N_TRACKED_SPECIES),ZZ_N(0:N_TRACKED_SPECIES),&
            DZZDT(0:N_TRACKED_SPECIES),DZZDT2(0:N_TRACKED_SPECIES),&
            DT_ODE,DT_NEW,RATE_CONSTANT(1:N_REACTIONS),Q_NR(1:N_REACTIONS),Q_NR2(1:N_REACTIONS),Q_SUM,DT_SUM
INTEGER :: NR,I_TS,NS
INTEGER, PARAMETER :: NODETS=20
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()


Q_OUT = 0._EB
ZZ_0 = MAX(0._EB,ZZ_GET)
ZZ_I = ZZ_0
DT_ODE = DT/REAL(NODETS,EB)
DT_NEW = DT_ODE
DT_SUM = 0._EB
I_TS = 1
ODE_LOOP: DO WHILE (DT_SUM < DT)
   DZZDT = 0._EB
   DZZDT2 = 0._EB
   Q_NR = 0._EB
   Q_NR2 = 0._EB
   RATE_CONSTANT = 0._EB
   REACTION_LOOP: DO NR = 1, N_REACTIONS   
      RN => REACTION(NR)      
      CALL COMPUTE_RATE_CONSTANT(NR,RN%MODE,I_TS,Q_OUT,RATE_CONSTANT(NR),ZZ_I,I,J,K)
      IF (RATE_CONSTANT(NR) < ZERO_P) CYCLE REACTION_LOOP
      Q_NR(NR) = RATE_CONSTANT(NR)*RN%HEAT_OF_COMBUSTION*RHO(I,J,K)
      DZZDT = DZZDT + RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANT(NR)
   END DO REACTION_LOOP   
   IF (ALL(DZZDT < ZERO_P)) EXIT ODE_LOOP    
   ZZ_N = ZZ_I + DZZDT * DT_NEW

   IF (ANY(ZZ_N < 0._EB)) THEN
      DO NS=0,N_TRACKED_SPECIES
          IF (ZZ_N(NS) < 0._EB .AND. ABS(DZZDT(NS))>ZERO_P) DT_NEW = MIN(DT_NEW,-ZZ_I(NS)/DZZDT(NS))
      ENDDO
   ENDIF  

   ZZ_N = ZZ_I + DZZDT * DT_NEW
   
   REACTION_LOOP2: DO NR = 1, N_REACTIONS   
      RN => REACTION(NR)      
      CALL COMPUTE_RATE_CONSTANT(NR,RN%MODE,I_TS,Q_OUT,RATE_CONSTANT(NR),ZZ_N,I,J,K)
      IF (RATE_CONSTANT(NR) < ZERO_P) CYCLE REACTION_LOOP2
      Q_NR2(NR) = RATE_CONSTANT(NR)*RN%HEAT_OF_COMBUSTION*RHO(I,J,K)
      DZZDT2 = DZZDT2 + RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANT(NR)
   END DO REACTION_LOOP2    
   IF (ALL(DZZDT2 < ZERO_P)) EXIT ODE_LOOP
   ZZ_N = ZZ_I +0.5_EB*(DZZDT+DZZDT2)*DT_NEW
   
   IF (ANY(ZZ_N < 0._EB)) THEN
      DO NS=0,N_TRACKED_SPECIES
          IF (ZZ_N(NS) < 0._EB .AND. ABS(DZZDT(NS)+DZZDT2(NS))>ZERO_P) DT_NEW = MIN(DT_NEW,-2._EB*ZZ_I(NS)/(DZZDT(NS)+DZZDT2(NS)))
      ENDDO
   ENDIF     

   Q_SUM = SUM(0.5_EB*(Q_NR+Q_NR2))

   IF (Q_OUT + Q_SUM*DT_NEW > Q_UPPER * DT) THEN
      DT_NEW = MAX(0._EB,(Q_UPPER * DT - Q_OUT))/Q_SUM
      Q_OUT = Q_OUT+Q_SUM*DT_NEW
      ZZ_I = ZZ_I + 0.5_EB*(DZZDT+DZZDT2)*DT_NEW
      EXIT ODE_LOOP
   ENDIF   

   ZZ_I = ZZ_I +0.5_EB*(DZZDT+DZZDT2)*DT_NEW

   Q_OUT = Q_OUT+Q_SUM*DT_NEW
 
   DT_SUM = DT_SUM + DT_NEW
   IF (DT_NEW < DT_ODE) DT_NEW = DT_ODE
   IF (DT_NEW + DT_SUM > DT) DT_NEW = DT - DT_SUM
   I_TS = I_TS + 1
ENDDO ODE_LOOP

ZZ_GET = ZZ_GET + ZZ_I - ZZ_0
Q_OUT = Q_OUT / DT

RETURN

END SUBROUTINE ODE_RUNGE_KUTTA_2

SUBROUTINE ODE_IMPLICIT_TRAPEZOID(I,J,K,ZZ_GET,Q_OUT)
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_OUT
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ZZ_0(0:N_TRACKED_SPECIES),ZZ_I(0:N_TRACKED_SPECIES),ZZ_N(0:N_TRACKED_SPECIES),DZZDT(0:N_TRACKED_SPECIES),&
            DT_ODE,DT_NEW,RATE_CONSTANT(1:N_REACTIONS),Q_NR(1:N_REACTIONS),Q_NRE(1:N_REACTIONS),Q_SUM,DT_SUM,TOL_CALC,TOL,&
            RATE_CONSTANTE(1:N_REACTIONS),DZZDTE(0:N_TRACKED_SPECIES),ZZ_1(0:N_TRACKED_SPECIES),&
            ZZ_2(0:N_TRACKED_SPECIES),DIFF_ZZ,DIFF_DT,ERR,TOL_INT_VECTOR(1:N_REACTIONS)
INTEGER :: COUNTER,ITER,I_TS,NR
INTEGER, PARAMETER :: NODETS=20,NODETSMAX=10000000
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

ITER  = 0
Q_OUT = 0._EB
ZZ_0 = MAX(0._EB,ZZ_GET)
ZZ_I = ZZ_0
DT_ODE = DT/REAL(NODETS,EB)
DT_SUM = 0._EB
I_TS = 1
TOL=1.E-7_EB
TOL_CALC=1._EB

! Setting up tolerance vector from inputs
DO NR = 1, N_REACTIONS   
   RN => REACTION(NR)
   TOL_INT_VECTOR(NR)=RN%TOL_INT
ENDDO

!integration loop
ODE_LOOP: DO WHILE (DT_SUM < DT)
   ZZ_0 = ZZ_I
   DZZDT = 0._EB
   DZZDTE = 0._EB
   RATE_CONSTANT = 0._EB
   RATE_CONSTANTE = 0._EB
   Q_NR = 0._EB
   Q_NRE = 0._EB
   COUNTER = 0
   
   TOLERANCE_LOOP: DO WHILE (TOL_CALC > TOL)
      DZZDT = 0._EB
      DZZDTE = 0._EB
      REACTION_LOOP: DO NR = 1, N_REACTIONS   
         RN => REACTION(NR)    
         CALL COMPUTE_RATE_CONSTANT(NR,RN%MODE,I_TS,Q_OUT,RATE_CONSTANT(NR),ZZ_I,I,J,K) !implicit
         CALL COMPUTE_RATE_CONSTANT(NR,RN%MODE,I_TS,Q_OUT,RATE_CONSTANTE(NR),ZZ_0,I,J,K) !explicit
         IF (RATE_CONSTANT(NR) < ZERO_P) CYCLE REACTION_LOOP
         Q_NR(NR) = RATE_CONSTANT(NR)*RN%HEAT_OF_COMBUSTION*RHO(I,J,K) !implicit
         Q_NRE(NR) = RATE_CONSTANTE(NR)*RN%HEAT_OF_COMBUSTION*RHO(I,J,K) !explicit
         DZZDT = DZZDT + RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANT(NR) !implicit
         DZZDTE = DZZDTE + RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANTE(NR) !explicit
      END DO REACTION_LOOP !Determine change in species
      IF (ALL(DZZDT < ZERO_P)) EXIT ODE_LOOP ! All species cannot decrease simultaneously
      IF (ALL(DZZDTE < ZERO_P)) EXIT ODE_LOOP ! All species cannot decrease simultaneously
      
      IF (ALL(TOL_INT_VECTOR < -998._EB)) THEN !calculates sub time step based on user inputted tolerance
         DT_NEW = DT_ODE
      ELSEIF (ABS(DT_SUM) < ZERO_P .OR. COUNTER < 1) THEN
         ZZ_1 = ZZ_0 + 0.5_EB * (DZZDT + DZZDTE) * DT
         ZZ_2 = ZZ_0 + 0.5_EB * (DZZDT + DZZDTE) * 0.5_EB * DT
         DIFF_ZZ = ABS(MAXVAL(ZZ_1 - ZZ_2))
         DIFF_DT = (DT)**2 - (0.5_EB * DT)**2
         ERR = DIFF_ZZ/ABS(DIFF_DT)
         ITER = CEILING(DT/MINVAL(SQRT(ABS(TOL_INT_VECTOR)/ERR)))
         ITER = MIN(MAX(ITER,1),NODETSMAX)
         DT_ODE = DT/REAL(ITER,EB)
         DT_NEW = DT_ODE
      ENDIF
      
      ZZ_N = ZZ_0 + 0.5_EB * (DZZDT + DZZDTE) * DT_NEW ! Updates species 
      Q_SUM = SUM(0.5_EB*(Q_NR+Q_NRE)) * DT_NEW ! Updates energy

      DO WHILE (ANY(ZZ_N < 0._EB)) !Shrinks time step if negative mass fractions
            DT_NEW = 0.95_EB*DT_NEW
            ZZ_N = ZZ_0 + 0.5_EB * (DZZDT + DZZDTE) * DT_NEW ! Updates species
      ENDDO
      
      TOL_CALC = MAXVAL(ABS(ZZ_N-ZZ_I)) ! Check tolerance
      ZZ_I = ZZ_N ! Updates guess vector for implicit iteration
      COUNTER = COUNTER + 1

      IF (COUNTER > 750) EXIT TOLERANCE_LOOP
   ENDDO TOLERANCE_LOOP
  
   IF (Q_OUT + Q_SUM > Q_UPPER * DT) THEN
      DT_NEW = MAX(0._EB,(Q_UPPER * DT - Q_OUT))/Q_SUM
      Q_OUT = Q_OUT+Q_SUM
      EXIT ODE_LOOP
   ENDIF
   Q_OUT = Q_OUT+Q_SUM
   DT_SUM = DT_SUM + DT_NEW
   TOL_CALC=1._EB 
   IF (DT_NEW < DT_ODE) DT_NEW = DT_ODE
   IF (DT_NEW + DT_SUM > DT) DT_NEW = DT - DT_SUM
   I_TS = I_TS + 1
   MAX_CHEM_SUBIT = MAX(MAX_CHEM_SUBIT,ITER)
ENDDO ODE_LOOP

ZZ_GET = ZZ_N
Q_OUT = Q_OUT / DT
RETURN

END SUBROUTINE ODE_IMPLICIT_TRAPEZOID

RECURSIVE SUBROUTINE COMPUTE_RATE_CONSTANT(NR,MODE,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)
USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL
REAL(EB), INTENT(IN) :: ZZ_GET(0:N_TRACKED_SPECIES),Q_IN
INTEGER, INTENT(IN) :: NR,I_TS,MODE,I,J,K
REAL(EB), INTENT(INOUT) :: RATE_CONSTANT
REAL(EB) :: YY_PRIMITIVE(1:N_SPECIES),Y_F_MIN=1.E-15_EB,ZZ_MIN=1.E-7_EB,YY_F_LIM,ZZ_REACTANT,ZZ_PRODUCT, &
            TAU_D,TAU_G,TAU_U,DELTA,RATE_CONSTANT_ED,RATE_CONSTANT_FR
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

RN => REACTION(NR)

SELECT CASE (MODE)
   CASE(MIXED)
      IF (Q_IN > 0._EB .AND. RN%THRESHOLD_TEMP >= TMP(I,J,K)) THEN
         CALL COMPUTE_RATE_CONSTANT(NR,EDDY_DISSIPATION,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)
      ELSE
         CALL COMPUTE_RATE_CONSTANT(NR,FINITE_RATE,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)      
      ENDIF
   CASE(EDDY_DISSIPATION)
         IF_SUPPRESSION: IF (SUPPRESSION) THEN
            ! Evaluate empirical extinction criteria
            IF (I_TS==1) THEN
                IF(EXTINCTION(I,J,K,ZZ_GET)) THEN
                   RATE_CONSTANT = 0._EB
                   RETURN
                ENDIF
            !ELSE
            !   IF (RATE_CONSTANT <= ZERO_P) RETURN
            ENDIF
         ENDIF IF_SUPPRESSION

         FIXED_TIME: IF (FIXED_MIX_TIME>0._EB) THEN
            MIX_TIME(I,J,K)=FIXED_MIX_TIME   
               
         ELSE FIXED_TIME
            IF (TWO_D) THEN
               DELTA = MAX(DX(I),DZ(K))
            ELSE
               DELTA = MAX(DX(I),DY(J),DZ(K))
            ENDIF

            LES_IF: IF (LES) THEN
            
               TAU_D = D_Z(MIN(4999,NINT(TMP(I,J,K))),RN%FUEL_SMIX_INDEX)
               TAU_D = DELTA**2/TAU_D ! diffusive time scale 
            
               IF (TURB_MODEL==DEARDORFF) THEN
                  TAU_U = 0.1_EB*SC*RHO(I,J,K)*DELTA**2/MU(I,J,K) ! turbulent mixing time scale
               ELSE
                  TAU_U = DELTA/SQRT(2._EB*KSGS(I,J,K)+1.E-10_EB) ! advective time scale
               ENDIF
               
               TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB)) ! acceleration time scale
               
               MIX_TIME(I,J,K)=MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! Eq. 7, McDermott, McGrattan, Floyd

            ELSE LES_IF

               TAU_D = D_Z(MIN(4999,NINT(TMP(I,J,K))),RN%FUEL_SMIX_INDEX)
               TAU_D = DELTA**2/TAU_D
               MIX_TIME(I,J,K)= TAU_D

            ENDIF LES_IF
         ENDIF FIXED_TIME
         
         YY_F_LIM=1.E15_EB
         IF (N_REACTIONS > 1) THEN
            DO NS=0,N_TRACKED_SPECIES
               IF(RN%NU(NS) < -ZERO_P) THEN
                  IF (ZZ_GET(NS) < ZZ_MIN) THEN
                     RATE_CONSTANT = 0._EB
                     RETURN
                  ENDIF
                  YY_F_LIM = MIN(YY_F_LIM,&
                                 ZZ_GET(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(ABS(RN%NU(NS))*SPECIES_MIXTURE(NS)%MW))
               ENDIF
            ENDDO
         ELSE
            ZZ_REACTANT = 0._EB
            ZZ_PRODUCT = 0._EB
            DO NS=0,N_TRACKED_SPECIES
               IF(RN%NU(NS) < -ZERO_P) THEN
                  IF (ZZ_GET(NS) < ZZ_MIN) THEN
                     RATE_CONSTANT = 0._EB
                     RETURN
                  ENDIF               
                  ZZ_REACTANT = ZZ_REACTANT - RN%NU(NS)*SPECIES_MIXTURE(NS)%MW
                  YY_F_LIM = MIN(YY_F_LIM,&
                                 ZZ_GET(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(ABS(RN%NU(NS))*SPECIES_MIXTURE(NS)%MW))
               ELSEIF(RN%NU(NS)>ZERO_P ) THEN
                  ZZ_PRODUCT = ZZ_PRODUCT + ZZ_GET(NS)
               ENDIF
            ENDDO
            ZZ_PRODUCT = BETA_EDC*MAX(ZZ_PRODUCT*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/ZZ_REACTANT,Y_P_MIN_EDC)
            YY_F_LIM = MIN(YY_F_LIM,ZZ_PRODUCT)
         ENDIF
         YY_F_LIM = MAX(YY_F_LIM,Y_F_MIN)
         RATE_CONSTANT = YY_F_LIM/MIX_TIME(I,J,K)      
   CASE(FINITE_RATE)
      RATE_CONSTANT = 0._EB
      CALL GET_MASS_FRACTION_ALL(ZZ_GET,YY_PRIMITIVE)    
      RATE_CONSTANT = RN%A*RHO(I,J,K)**RN%RHO_EXPONENT*EXP(-RN%E/(R0*TMP(I,J,K)))*TMP(I,J,K)**RN%N_T
      IF (ALL(RN%N_S<-998._EB)) THEN
         DO NS=0,N_TRACKED_SPECIES
            IF(RN%NU(NS)<0._EB .AND. ZZ_GET(NS) < ZZ_MIN) THEN
               RATE_CONSTANT = 0._EB
               RETURN
            ENDIF            
         ENDDO
      ELSE
         DO NS=1,N_SPECIES
            IF(ABS(RN%N_S(NS)) <= ZERO_P) CYCLE
            IF(RN%N_S(NS)>= -998._EB) THEN
               IF (YY_PRIMITIVE(NS) < ZZ_MIN) THEN
                  RATE_CONSTANT = 0._EB
               ELSE
                  RATE_CONSTANT = YY_PRIMITIVE(NS)**RN%N_S(NS)*RATE_CONSTANT 
               ENDIF
            ENDIF
         ENDDO       
      ENDIF

   CASE(NEW_MIXED_MODE)
      CALL COMPUTE_RATE_CONSTANT(NR,EDDY_DISSIPATION,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)
      RATE_CONSTANT_ED=RATE_CONSTANT
      CALL COMPUTE_RATE_CONSTANT(NR,FINITE_RATE,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)
      RATE_CONSTANT_FR=RATE_CONSTANT
      RATE_CONSTANT=MIN(RATE_CONSTANT_ED,RATE_CONSTANT_FR)
END SELECT

RETURN

CONTAINS

LOGICAL FUNCTION EXTINCTION(I,J,K,ZZ_IN)
!This routine determines if local extinction occurs for a mixing controlled reaction.
!This is determined as follows:
!1) Determine how much fuel can burn (DZ_FUEL) by finding the limiting reactant and expressing it in terms of fuel mass
!2) Remove that amount of fuel form the local mixture, everything else is "air"  
!   (i.e. if we are fuel rich, excess fuel acts as a diluent)
!3) Search to find the minimum reactant other than fuel.  
!   Using the reaction stoichiometry, determine how much "air" (DZ_AIR) is needed to burn the fuel.
!4) GET_AVERAGE_SPECIFIC_HEAT for the fuel and the "air" at the current temp and the critical flame temp
!5) Check to see if the heat released from burning DZ_FUEL can raise the current temperature of DZ_FUEL and DZ_AIR
!   above the critical flame temp.
USE PHYSICAL_FUNCTIONS,ONLY:GET_AVERAGE_SPECIFIC_HEAT
REAL(EB),INTENT(IN)::ZZ_IN(0:N_TRACKED_SPECIES)
REAL(EB):: DZ_AIR,DZ_FUEL,CPBAR_F_0,CPBAR_F_N,CPBAR_G_0,CPBAR_G_N,ZZ_GET(0:N_TRACKED_SPECIES)
INTEGER, INTENT(IN) :: I,J,K
INTEGER :: NS

EXTINCTION = .FALSE.
IF (TMP(I,J,K) < RN%AUTO_IGNITION_TEMPERATURE) THEN
   EXTINCTION = .TRUE.
ELSE
   DZ_FUEL = 1._EB
   DZ_AIR = 0._EB
   !Search reactants to find limiting reactant and express it as fuel mass.  This is the amount of fuel
   !that can burn
   DO NS = 0,N_TRACKED_SPECIES
      IF (RN%NU(NS)<-ZERO_P) &
         DZ_FUEL = MIN(DZ_FUEL,-ZZ_IN(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(RN%NU(NS)*SPECIES_MIXTURE(NS)%MW))
   ENDDO
   !Get the specific heat for the fuel at the current and critical flame temperatures
   ZZ_GET = 0._EB
   ZZ_GET(RN%FUEL_SMIX_INDEX) = 1._EB
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_0,TMP(I,J,K)) 
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_N,RN%CRIT_FLAME_TMP)
   ZZ_GET = ZZ_IN
   !Remove the burnable fuel from the local mixture and renormalize.  The remainder is "air"
   ZZ_GET(RN%FUEL_SMIX_INDEX) = ZZ_GET(RN%FUEL_SMIX_INDEX) - DZ_FUEL
   ZZ_GET = ZZ_GET/SUM(ZZ_GET)     
   !Get the specific heat for the "air"
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_0,TMP(I,J,K)) 
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_N,RN%CRIT_FLAME_TMP) 
   !Loop over non-fuel reactants and find the mininum.  Determine how much "air" is needed to provide the limting reactant
   DO NS = 0,N_TRACKED_SPECIES   
            IF (RN%NU(NS)<-ZERO_P .AND. NS/=RN%FUEL_SMIX_INDEX) &
              DZ_AIR = MAX(DZ_AIR, -DZ_FUEL*RN%NU(NS)*SPECIES_MIXTURE(NS)%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/ZZ_GET(NS))
   ENDDO
   !See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp
   IF ( (DZ_FUEL*CPBAR_F_0 + DZ_AIR*CPBAR_G_0)*TMP(I,J,K) + DZ_FUEL*RN%HEAT_OF_COMBUSTION < &
         (DZ_FUEL*CPBAR_F_N + DZ_AIR*CPBAR_G_N)*RN%CRIT_FLAME_TMP) EXTINCTION = .TRUE.
ENDIF

END FUNCTION EXTINCTION


REAL(EB) FUNCTION KSGS(I,J,K)
INTEGER, INTENT(IN) :: I,J,K
REAL(EB) :: EPSK

! ke dissipation rate, assumes production=dissipation

EPSK = MU(I,J,K)*STRAIN_RATE(I,J,K)**2/RHO(I,J,K)

KSGS = 2.25_EB*(EPSK*DELTA/PI)**TWTH  ! estimate of subgrid ke, from Kolmogorov spectrum

END FUNCTION KSGS

END SUBROUTINE COMPUTE_RATE_CONSTANT


SUBROUTINE GET_REV_fire(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') firerev(INDEX(firerev,':')+1:LEN_TRIM(firerev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') firedate

END SUBROUTINE GET_REV_fire
 
END MODULE FIRE

