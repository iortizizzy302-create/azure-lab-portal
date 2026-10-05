>>SOURCE FORMAT FREE
*> ---------------------------------------------------------------
*> RESULTS.cbl - Mock lab result evaluator
*> Loads a sample's test results into an in-memory table (array),
*> flags each result against its reference range, computes where
*> the value sits inside the range, and prints a pipe-delimited
*> report to stdout for the web app to read.
*>
*> Input record (29 chars, fixed width):
*>   cols  1-8   test code       X(8)
*>   cols  9-15  result value    9(5)V99  (implied decimal)
*>   cols 16-22  reference low   9(5)V99
*>   cols 23-29  reference high  9(5)V99
*>
*> Output lines:
*>   R|code|value|flag|position      one per result (flag L/H/N)
*>   S|total|normal|high|low         one summary line
*>   E|reason|detail                 on error
*> ---------------------------------------------------------------
IDENTIFICATION DIVISION.
PROGRAM-ID. RESULTS.

ENVIRONMENT DIVISION.
INPUT-OUTPUT SECTION.
FILE-CONTROL.
    SELECT RESULT-FILE ASSIGN TO WS-IN-PATH
        ORGANIZATION IS LINE SEQUENTIAL
        FILE STATUS IS WS-FILE-STATUS.

DATA DIVISION.
FILE SECTION.
FD  RESULT-FILE.
01  RESULT-REC.
    05 IN-TEST-CODE         PIC X(8).
    05 IN-VALUE             PIC 9(5)V99.
    05 IN-LOW               PIC 9(5)V99.
    05 IN-HIGH              PIC 9(5)V99.

WORKING-STORAGE SECTION.
01  WS-IN-PATH              PIC X(256).
01  WS-FILE-STATUS          PIC XX.
01  WS-EOF-SW               PIC X VALUE "N".
    88 RESULT-EOF                VALUE "Y".

01  WS-MAX-ENTRIES          PIC 9(3) VALUE 200.
01  WS-COUNT                PIC 9(3) VALUE 0.
01  WS-IDX                  PIC 9(3) VALUE 0.

*> The array: one entry per test result for this sample
01  RESULT-TABLE.
    05 RESULT-ENTRY OCCURS 200 TIMES.
       10 T-CODE            PIC X(8).
       10 T-VALUE           PIC 9(5)V99.
       10 T-LOW             PIC 9(5)V99.
       10 T-HIGH            PIC 9(5)V99.
       10 T-FLAG            PIC X.
       10 T-POS             PIC S9(5)V9.

01  WS-NORMAL-CT            PIC 9(3) VALUE 0.
01  WS-HIGH-CT              PIC 9(3) VALUE 0.
01  WS-LOW-CT               PIC 9(3) VALUE 0.
01  WS-SPAN                 PIC 9(5)V99.

01  OUT-VALUE               PIC ZZZZ9.99.
01  OUT-POS                 PIC -(5)9.9.

PROCEDURE DIVISION.
MAIN-PARA.
    ACCEPT WS-IN-PATH FROM COMMAND-LINE
    OPEN INPUT RESULT-FILE
    IF WS-FILE-STATUS NOT = "00"
        DISPLAY "E|OPEN|" WS-FILE-STATUS
        MOVE 8 TO RETURN-CODE
        STOP RUN
    END-IF

    PERFORM LOAD-TABLE
    CLOSE RESULT-FILE

    PERFORM EVALUATE-ENTRY
        VARYING WS-IDX FROM 1 BY 1
        UNTIL WS-IDX > WS-COUNT

    DISPLAY "S|" WS-COUNT "|" WS-NORMAL-CT "|" WS-HIGH-CT "|" WS-LOW-CT
    MOVE 0 TO RETURN-CODE
    STOP RUN.

LOAD-TABLE.
    PERFORM UNTIL RESULT-EOF
        READ RESULT-FILE
            AT END
                SET RESULT-EOF TO TRUE
            NOT AT END
                IF WS-COUNT < WS-MAX-ENTRIES
                    ADD 1 TO WS-COUNT
                    MOVE IN-TEST-CODE TO T-CODE  (WS-COUNT)
                    MOVE IN-VALUE     TO T-VALUE (WS-COUNT)
                    MOVE IN-LOW       TO T-LOW   (WS-COUNT)
                    MOVE IN-HIGH      TO T-HIGH  (WS-COUNT)
                END-IF
        END-READ
    END-PERFORM.

EVALUATE-ENTRY.
    EVALUATE TRUE
        WHEN T-VALUE (WS-IDX) < T-LOW (WS-IDX)
            MOVE "L" TO T-FLAG (WS-IDX)
            ADD 1 TO WS-LOW-CT
        WHEN T-VALUE (WS-IDX) > T-HIGH (WS-IDX)
            MOVE "H" TO T-FLAG (WS-IDX)
            ADD 1 TO WS-HIGH-CT
        WHEN OTHER
            MOVE "N" TO T-FLAG (WS-IDX)
            ADD 1 TO WS-NORMAL-CT
    END-EVALUATE

    *> Position inside the reference range: 0 = low limit, 100 = high limit
    COMPUTE WS-SPAN = T-HIGH (WS-IDX) - T-LOW (WS-IDX)
    IF WS-SPAN > 0
        COMPUTE T-POS (WS-IDX) ROUNDED =
            (T-VALUE (WS-IDX) - T-LOW (WS-IDX)) * 100 / WS-SPAN
            ON SIZE ERROR MOVE 9999.9 TO T-POS (WS-IDX)
        END-COMPUTE
    ELSE
        MOVE 50 TO T-POS (WS-IDX)
    END-IF

    MOVE T-VALUE (WS-IDX) TO OUT-VALUE
    MOVE T-POS (WS-IDX)   TO OUT-POS
    DISPLAY "R|" FUNCTION TRIM (T-CODE (WS-IDX))
            "|"  FUNCTION TRIM (OUT-VALUE)
            "|"  T-FLAG (WS-IDX)
            "|"  FUNCTION TRIM (OUT-POS).
