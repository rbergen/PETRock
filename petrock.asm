;-----------------------------------------------------------------------------------
; PETROCK: Spectrum Analyzer Display for C64 and PET
;-----------------------------------------------------------------------------------
; (c) Plummer's Software Ltd, 02/11/2022 Initial commit
;         David Plummer
;         Rutger van Bergen
;-----------------------------------------------------------------------------------
;
; General Idea for Newcomers:
;
; Draws 16 vertical bands of the spectrum analyzer which can be up to 16 high.  The
; program first clears the screen, draws the border and text, fills in color, and the
; main draw loop calls DrawBand for each one in turn.  Each frame draws a new set of
; peaks from the PeakData table, which has 16 entries, one per band.  That data is
; replaced either by a new frame of demo data or an incoming serial packet and the
; process is repeated, running at about 40 fps.
;
; Color RAM can be filled with different patterns by stepping through the visual styles
; with the C key, but it is not drawn each and every frame.  
;
; Basic bar draw is to walk down the bar and draw a blank (when above the bar), the top
; of the bar, then the middle pieces, then the bottom.  A visual style definition is
; set that includes all of the PETSCII chars you need to draw a band, like the corners
; and sides, etc.  It can be changed with the S key.
; 
; Every frame the serial port is checked for incoming data which is then stored in the
; SerialBuf.  If that fills up without a nul it is reset, but if a nul comess in at the
; right place (right packet size) and the magic byte matches, it is used as new peakdata
; and stored in the PeakData table.  The code on the ESP32 sends it over as 16 nibbles
; packed into 8 bytes plus a VU value.
;
; The built-in serial code on the C64 is poor, and serial/c64/driver.s contains a new 
; impl that works well for receiving data up to 4800 baud.
; On the PET, built-in serial code is effectively absent. For the PET, 
; serial/c64/driver.s contains an implementation that is confirmed to receive data
; up to 2400 baud.
;
;-----------------------------------------------------------------------------------


.SETCPU "6502"

; Include the system headers and application defintions ----------------------------

.include "settings.inc"
.include "petrock.inc"                    ; Project includes and defintions

; Our BSS Data  --------------------------------------------------------------------

.org SCRATCH_START                        ; Program counter to casssette buffer so that
.bss                                      ;  we can define our BSS storage variables

; These are local BSS variables.  We're using the cassette buffer for storage.  All
; will be initlialzed to 0 bytes at application startup.

ScratchStart:
    tempDrawLine:    .res  1              ; Temp used by DrawLine
    tempOutput:      .res  1              ; Temp used by OutputSymbol
    tempX:           .res  1              ; Preserve X Pos
    tempY:           .res  1              ; Preserve Y Pos
    lineChar:        .res  1              ; Line draw char
    SquareX:         .res  1              ; Args for DrawSquare
    SquareY:         .res  1  
    Width:           .res  1  
    Height:          .res  1              ; Height of area to draw
    ClearHeight:     .res  1              ; Height of area to clear
    DataIndex:       .res  1              ; Index into fakedata for demo
    resultLo:        .res  1              ; Results from multiply operations
    resultHi:        .res  1  
    VU:              .res  1              ; VU Audio Data
    Peaks:           .res  NUM_BANDS      ; Peak Data for current frame
    NextStyle:       .res  1              ; The next style we will pick
    CharDefs:        .res  VISUALDEF_SIZE ; Storage for the visualDef currently in use
    RedrawFlag:      .res  1              ; Flag to redraw screen
    DemoMode:        .res  1              ; Demo mode enabled
.if C64         ; Color's only relevant on the C64
    CurSchemeIndex:  .res  1              ; Current band color scheme index
    BorderColor:     .res  1              ; Border color at startup
    BkgndColor:      .res  1              ; Background color at startup
    TextColor:       .res  1              ; Text color at startup
.endif
    TextTimeout:     .res  1              ; Text timeout second count (0 = disabled)
.if PET         ; Rudimentary approach for PET. The C64 uses a CIA timer
    TextCountDown:   .res  2              ; Text timeout countdown timer
.endif
.if .not (PET && SERIAL)
    DemoToggle:      .res  1              ; Update toggle to delay demo mode updates
.endif
.if SERIAL                                ; Include serial driver variables
    SerialBufPos:    .res  1              ; Current index into serial buffer
    SerialBuf:       .res  PACKET_LENGTH  ; Serial buffer for: "DP" + 1 byte vu + 8 PeakBytes
    SerialBufLen = *-SerialBuf            ; Length of Serial Buffer
  .if C64
.include "serial/c64/vars.s"
  .elseif PET
.include "serial/pet/vars.s"
  .endif
.endif

ScratchEnd: 

.assert * <= SCRATCH_END, error           ; Make sure we haven't run off the end of the buffer

.if SERIAL
.assert SerialBufLen = PACKET_LENGTH, error
.endif

; Start of Binary -------------------------------------------------------------------

.code

; BASIC program to load and execute ourselves.  Lines of tokenized BASIC that
; have a banner comment and then a SYS command to start the machine language code.

                .org 0000             ; File begins with program start address so we
                .word BASE            ;  emit that as the first two bytes
                .org  BASE

Line10:         .word Line1           ; Next line number
                .word 0               ; Line Number 10
                .byte TK_REM          ; REM token
                .literal " - SPECTRUM ANALYZER DISPLAY", 00
Line1:          .word Line2
                .word 1
                .byte TK_REM
                .literal " - C64PETROCK.COM", 00
Line2:          .word Line3
                .word 2
                .byte TK_REM
                .literal " - PETROCK - COPYRIGHT 2022", 00
Line3:          .word endOfBasic       ; PTR to next line, which is 0000
                .word 3               ; Line Number 20
                .byte TK_SYS          ;   SYS token
                .literal .sprintf(" %d", PROGRAM)

                .byte 00
endOfBasic:     .word 00


.res            PROGRAM - *

;-----------------------------------------------------------------------------------
; Start of Assembly Code
;-----------------------------------------------------------------------------------

.if PET
                lda PET_DETECT        ; Check if we're dealing with original ROMs
                cmp #PET_2000
                bne @goodpet

                ldy #>notonoldrom     ; Disappoint user
                lda #<notonoldrom
                jsr WriteLine

                rts
@goodpet:
.endif

.if SERIAL

                jmp start

  .if C64
.include "serial/c64/driver.s"
  .elseif PET
.include "serial/pet/driver.s"
  .endif

.endif

start:
                cld                   ; Turn off decimal mode

                jsr InitVariables     ; Zero (init) all of our BSS storage variables

.if C64         ; TOD and color only available on C64
                jsr InitTODClocks

                lda VIC_BORDERCOLOR   ; Save current colors for later
                sta BorderColor
                lda VIC_BG_COLOR0
                sta BkgndColor
                lda TEXT_COLOR
                sta TextColor

                lda #BLACK            ; Screen and border to black
                sta VIC_BG_COLOR0
                sta VIC_BORDERCOLOR
.endif
                ldy #>clrGREEN        ; Set cursor to green and clear screen, setting text
                lda #<clrGREEN        ;   color to light green on the C64
                jsr WriteLine
                
                jsr EmptyBorder       ; Draw the screen frame and decorations
                jsr SetNextStyle      ; Select the first visual style

.if C64         ; Color only supported on C64
                jsr FillBandColors    ; Do initial fill of band color RAM
.endif

.if SERIAL
                jsr OpenSerial        ; Open the serial port for data from the ESP32   
                jsr StartSerial       ; Enable Serial!  Behold the power!
.endif

drawLoop:       

.if SERIAL
                jsr GetSerialChar
                cmp #$ff              ; If byte is $ff, check if "no data" was flagged
                bne @havebyte
                cpx #<SER_ERR_NO_DATA
                bne @havebyte
                cpy #>SER_ERR_NO_DATA 
                beq @donedata

@havebyte:      jsr GotSerial
                jmp drawLoop
.endif

.if TIMING && C64                     ; If 'TIMING' is defined on the C64 we turn the border bit RASTHI
                jsr InitTimer         ; Prep the timer for this frame
                lda #$11              ; Start the timer
                sta CIA2_CRA
@waitforraster: bit RASTHI
                bmi @waitforraster
                lda #DARK_GREY        ;  Color to different colors at particular
                sta VIC_BORDERCOLOR   ;    places in the draw code to help see how
.endif

@donedata:      lda DemoMode          ; Load demo data if demo mode is on
                beq @redraw
                jsr FillPeaks
                ldx #$10
                ldy #$ff
@delay:         dey
                bne @delay
                dex
                bne @delay

@redraw:        lda RedrawFlag
                beq @afterdraw        ; We didn't get a complete packet yet, so no point in drawing anything
                lda #0 
                sta RedrawFlag        ; Acknowledge packet

                jsr DrawVU            ; Draw the VU bar at the top of the screen

.if TIMING && C64                     ; If 'TIMING' is defined we turn the border
                lda #LIGHT_GREY       ;   color to different colors at particular
                sta VIC_BORDERCOLOR   ;   places in the draw code to help see how
.endif                                ;   long various parts of it are taking.

                ldx #NUM_BANDS - 1    ; Draw each of the bands in reverse order
:
                lda Peaks, x          ; X = band numner, A = value
                jsr DrawBand
                dex
                bpl :-

.if PET         
                jsr DownTextTimer     ; On the PET, decrease the text timer to compensate 
.endif                                ;   for drawing time

.if SERIAL && (C64 || (PET && SENDSTAR))
                lda #'*'              ; Send a * back to the host
                jsr PutSerialChar
.endif

.if TIMING && C64
                ; Check to see its time to scroll the color memory

                lda #BLACK
                sta VIC_BORDERCOLOR
:               bit RASTHI
                bpl :-
                lda #0                ; Stop the clock
                sta CIA2_CRA
                lda #LIGHT_BLUE
                sta TEXT_COLOR
                ldx #24               ; Print "Current Frame" banner
                ldy #09
                clc
                jsr PlotEx
                ldy #>framestr
                lda #<framestr
                jsr WriteLine
                lda CIA2_TB           ; Display the number of ms the frame took. I realized
                eor #$FF              ;   that 65536 - time is the same as flipping the bits,
                tax                   ;   so that's why I XOR instead of subtracting
                lda CIA2_TB+1
                eor #$ff
                jsr BASIC_INTOUT
                lda #' '
                jsr CHROUT
                lda #'M'
                jsr CHROUT
                lda #'S'
                jsr CHROUT
                lda #' '
                jsr CHROUT
                jsr CHROUT
.endif          ; TIMING && C64

@afterdraw:     jsr CheckTextTimer

.if SERIAL
                jsr GetKeyboardChar   ; Get a character from the serial driver's keyboard handler
.else
                jsr GETIN             ; No serial, use regular GETIN routine
.endif

                cmp #0
                bne @notEmpty

                jmp drawLoop

@notEmpty:      cmp #$53              ; Letter "S"
                bne @notStyle
                jsr SetNextStyle
                jmp drawLoop

@notStyle:
.if C64         ; Color only available on C64
                cmp #$43              ; Letter "C"
                bne @notColor
                jsr SetNextScheme
                jmp drawLoop

@notColor:      cmp #$C3              ; Shift "C"
                bne @notShiftC
                jsr SetPrevScheme
                jmp drawLoop

@notShiftC:
.endif
                cmp #$44              ; Letter "D"
                bne @notDemo
                jsr SwitchDemoMode
                jmp drawLoop

@notDemo:       cmp #$42              ; Letter "B"
                bne @notborder
                jsr ToggleBorder
                jmp drawLoop

@notborder:     cmp #$03
                beq @exit
                
                jsr ShowHelp
                jmp drawLoop

@exit:
.if SERIAL
                jsr CloseSerial
.endif

.if C64         ; Color only available on C64
                lda BorderColor       ; Restore colors to how we found them
                sta VIC_BORDERCOLOR
                lda BkgndColor
                sta VIC_BG_COLOR0
                lda TextColor
                sta TEXT_COLOR
.endif
                jsr ClearScreen

                ldy #>exitstr         ; Output exiting text and exit
                lda #<exitstr
                jsr WriteLine

                rts

;-----------------------------------------------------------------------------------
; ToggleBorder - Toggle border around spectrum analyzer area
;-----------------------------------------------------------------------------------

ToggleBorder:   lda #<SCREEN_MEM
                sta zptmp
                lda #>SCREEN_MEM
                sta zptmp+1

                ldy #0
                lda (zptmp),y
                cmp #' '

                bne ClrBorderMem

; Note: this routine flows into the next one

;-----------------------------------------------------------------------------------
; EmptyBorder - Draw border around spectrum analyzer area
;-----------------------------------------------------------------------------------

EmptyBorder:    lda #0
                sta SquareX
                sta SquareY
                lda #XSIZE
                sta Width
                lda #YSIZE
                sta Height
                jsr DrawSquare

.if C64         ; Color only available on C64
                jsr InitVU            ; Let the VU meter paint its color mem, etc

                lda #LIGHT_BLUE
                sta TEXT_COLOR
.endif

                ldy #XSIZE/2-titlelen/2+1         ; Print title banner
                ldx #YSIZE-1
                clc
                jsr PlotEx
                ldy #>titlestr
                lda #<titlestr
                jsr WriteLine

                rts

;-----------------------------------------------------------------------------------
; ClearBorder   Remove border and decorations
;-----------------------------------------------------------------------------------

ClearBorder:    
                lda #<SCREEN_MEM
                sta zptmp
                lda #>SCREEN_MEM
                sta zptmp+1

ClrBorderMem:   ldy #XSIZE-1          ; Top line
                lda #' '
:               sta (zptmp),y
                dey
                bpl :-

                ldx #YSIZE-2

@rowloop:       lda zptmp             ; Left and right lines
                clc
                adc #XSIZE
                sta zptmp
                lda zptmp+1
                adc #0
                sta zptmp+1
                
                lda #' '
                ldy #0
                sta (zptmp),y

                ldy #XSIZE-1
                sta (zptmp),y

                dex
                bne @rowloop

                lda zptmp             ; Bottom line
                clc
                adc #XSIZE
                sta zptmp
                lda zptmp+1
                adc #0
                sta zptmp+1

                ldy #XSIZE-1
                lda #' '
:               sta (zptmp),y
                dey
                bpl :-

                rts

.if SERIAL

;-----------------------------------------------------------------------------------
; GotSerial     Process incoming serial bytes from the ESP32 
;-----------------------------------------------------------------------------------
; Store character in serial buffer. Processes packet if character completes it.
;-----------------------------------------------------------------------------------

GotSerial:      ldy SerialBufPos
                cpy #SerialBufLen      
                bne @nooverflow
                ldy #0
                sty SerialBufPos
                rts
@nooverflow:                    
                sta SerialBuf, y
                iny
                sty SerialBufPos
                
                cmp #00                   ; Look for carriage return meaning end
                beq :+
                rts                       ; No CR, back to caller

:               cpy SerialBufPos          ; Are we in the right char pos for it?
                beq :+                    ;  Yep - Process packet
                ldy #0                    ;  Nope - Restart filling buffer
                sty SerialBufPos
                beq @done

:               jsr GotSerialPacket

@done:          rts

BogusData:
                ldy #0
                sty SerialBufPos
                rts

;-----------------------------------------------------------------------------------
; GotSerialPacket - Recieved a string followed by a carriage return so inspect it
;                   to see if it could be a data packet, as indicated by 'DP' as
;                   the first two bytes.  Data Packet? Dave Plummer?  You decide!
;-----------------------------------------------------------------------------------

GotSerialPacket: 
                ldy SerialBufPos          ; Get received packet length
                lda SerialBuf             ; Look for 'D'
                cmp #MAGIC_BYTE_0
                bne BogusData

                lda SerialBuf+MAGIC_LEN
                sta VU

                PeakDataNibbles = SerialBuf + MAGIC_LEN + VU_LEN
        
                ldy #0
                ldx #0
                
:               lda PeakDataNibbles, y    ; Get the next byte from the buffer
                and #%11110000            ; Get the top nibble
                lsr
                lsr
                lsr
                lsr
                clc
                adc #1                    ; Add one to values
                
                sta Peaks+1, x            ; Store it in the peaks table
                lda PeakDataNibbles, y    ; Get that SAME byte from the buffer
                and #%00001111            ; Now we want the low nibble
                clc
                adc #1
                sta Peaks, x              ; Store it in the peaks table

                inx                       ; Advance to the next peak
                inx
                iny                       ; Advance to the next byte of serial data

                cpy #8                    ; Have we done bytes 0-3 yet?
                bne :-                    ; Repeat until we have

                lda #1
                sta RedrawFlag            ; Time to redraw!
                rts

.endif          ; SERIAL

;-----------------------------------------------------------------------------------
; FillPeaks
;-----------------------------------------------------------------------------------
; Copy data from the current index of the fake data table to the current peak data
; and vu value
;-----------------------------------------------------------------------------------

FillPeaks:      
.if .not (PET && SERIAL)
                lda DemoToggle
                eor #$01
                sta DemoToggle
                beq @proceed

                rts

@proceed:       
.endif
                tya
                pha
                txa
                pha

                ldx DataIndex         ; Multiply the row number by 16 to get the offset
                ldy #16               ; into the data table
                jsr Multiply

                lda resultLo          ; Now add the offset and the table base together
                clc                   ;  and store the resultant ptr in zptmpC
                adc #<AudioData
                sta zptmpB
                lda resultHi
                adc #>AudioData
                sta zptmpB+1

                ldy #15               ; Copy the 16 bytes at the ptr address to the
:               lda (zptmpB), y       ;   PeakData table
                and #$0f              ; Normalize value between 1 and 16
                clc
                adc #1
                sta Peaks, y
                dey
                bpl :-

                lda #<PeakData        ; Copy the single VU byte from the PeakData
                sta zptmpB            ;   table into the VU variable
                lda #>PeakData
                sta zptmpB+1
                ldy DataIndex
                lda (zptmpB), y
                sta VU

                lda #1
                sta RedrawFlag        ; Time to redraw!

                inc DataIndex         ; Inc DataIndex - Assumes wrap, so if you
                                      ;   have exacly 256 bytes, you'd need to
                                      ;   check and fix that here

                pla
                tax
                pla
                tay
                rts

;-----------------------------------------------------------------------------------
; InitVariables
;-----------------------------------------------------------------------------------
; We use a bunch of storage in the system (on the C64 it's the datasette buffer) and
; it starts out in an unknown state, so we have code to zero it or set it to defaults
;-----------------------------------------------------------------------------------

InitVariables:  ldx #ScratchEnd-ScratchStart
                lda #$00              ; Init variables to #0
:               sta ScratchStart, x
                dex
                cpx #$ff
                bne :-

                lda #1
                sta RedrawFlag

                rts

;-----------------------------------------------------------------------------------
; SwitchDemoMode
;-----------------------------------------------------------------------------------
; Toggle demo mode. If we switch it off, clear peaks and VU data.
;-----------------------------------------------------------------------------------

SwitchDemoMode: lda DemoMode          ; Toggle demo mode bit
                eor #$01
                sta DemoMode
                bne @enabled          ; If we enabled demo mode, we're done

                lda #0                ; Zero out peaks and VU
                ldy #15
:               sta Peaks, y
                dey
                bpl :-

                sta VU

                lda #1
                sta RedrawFlag        ; Force redraw

                ldx #<DemoOffText     ; Tell user what just happened
                ldy #>DemoOffText

                bne @done

@enabled:       ldx #<DemoOnText
                ldy #>DemoOnText

@done:          jmp ShowTextLine

;-----------------------------------------------------------------------------------
; GetCursorAddr - Returns address of X/Y position on screen
;-----------------------------------------------------------------------------------
;           IN  X:  X pos
;           IN  Y:  Y pos
;           OUT X:  lsb of address
;           OUT Y:  msb of address
;-----------------------------------------------------------------------------------

ScreenLineAddresses:

                .word SCREEN_MEM +  0 * XSIZE, SCREEN_MEM +  1 * XSIZE
                .word SCREEN_MEM +  2 * XSIZE, SCREEN_MEM +  3 * XSIZE
                .word SCREEN_MEM +  4 * XSIZE, SCREEN_MEM +  5 * XSIZE
                .word SCREEN_MEM +  6 * XSIZE, SCREEN_MEM +  7 * XSIZE
                .word SCREEN_MEM +  8 * XSIZE, SCREEN_MEM +  9 * XSIZE
                .word SCREEN_MEM + 10 * XSIZE, SCREEN_MEM + 11 * XSIZE
                .word SCREEN_MEM + 12 * XSIZE, SCREEN_MEM + 13 * XSIZE
                .word SCREEN_MEM + 14 * XSIZE, SCREEN_MEM + 15 * XSIZE
                .word SCREEN_MEM + 16 * XSIZE, SCREEN_MEM + 17 * XSIZE
                .word SCREEN_MEM + 18 * XSIZE, SCREEN_MEM + 19 * XSIZE
                .word SCREEN_MEM + 20 * XSIZE, SCREEN_MEM + 21 * XSIZE
                .word SCREEN_MEM + 22 * XSIZE, SCREEN_MEM + 23 * XSIZE
                .word SCREEN_MEM + 24 * XSIZE
                .assert( (* - ScreenLineAddresses) = YSIZE * 2), error

GetCursorAddr:  tya
                asl
                tay
                txa
                clc
                adc ScreenLineAddresses,y
                tax
                lda ScreenLineAddresses+1,y
                adc #0
                tay
                rts

;-----------------------------------------------------------------------------------
; ClearScreen   Guess.
;-----------------------------------------------------------------------------------

ClearScreen:    jmp CLRSCR

;-----------------------------------------------------------------------------------
; WriteLine     Writes a line of text to the screen using CHROUT ($FFD2)
;-----------------------------------------------------------------------------------
;               Y:  MSB of address of null-terminated string
;               A:  LSB
;-----------------------------------------------------------------------------------

WriteLine:      sta zptmp
                sty zptmp+1
WLRaw:          ldy #0
@loop:          lda (zptmp),y
                beq @done
                jsr CHROUT
                iny
                bne @loop
@done:          rts

;-----------------------------------------------------------------------------------
; ShowHelp      Show help text
;-----------------------------------------------------------------------------------

ShowHelp:
                lda #0
                ldx #<EmptyText
                ldy #>EmptyText
                jsr PutText

                lda #1
                ldx #<HelpText1
                ldy #>HelpText1
                jsr PutText

                lda #2
                ldx #<HelpText2
                ldy #>HelpText2
                jsr PutText

                lda #3
                sta TextTimeout

                jmp StartTextTimer

;-----------------------------------------------------------------------------------
; ShowTextLine - Puts a line of text in the middle of the text block
;-----------------------------------------------------------------------------------
;               X:  LSB of address of null-terminated string
;               Y:  MSB
;-----------------------------------------------------------------------------------

ShowTextLine:
                txa
                pha
                tya
                pha

                lda #0
                ldx #<EmptyText
                ldy #>EmptyText
                jsr PutText

                lda #2
                ldx #<EmptyText
                ldy #>EmptyText
                jsr PutText

                lda #1
                sta TextTimeout

                jsr StartTextTimer

                pla
                tay
                pla
                tax

                lda #1

; Note: this routine flows into the next one

;-----------------------------------------------------------------------------------
; PutText       Put a string of characters at the center of a message line
;-----------------------------------------------------------------------------------
;               A:  Message line number within the text block
;               X:  LSB of address of null-terminated string
;               Y:  MSB
;-----------------------------------------------------------------------------------

PutText:
                stx zptmp
                sty zptmp+1

                clc                   ; Set cursor to start of desired line
                adc #TOP_MARGIN+BAND_HEIGHT
                tax
                ldy #LEFT_MARGIN
.if C64         ; Color only available on C64
                lda #WHITE
                sta TEXT_COLOR
.endif
                jsr PlotEx

                ldy #$ff              ; Determine length of string by counting until NUL
:               iny
                lda (zptmp),y
                bne :-
                dey

                tya                   ; Calculate number of spaces to center text
                clc 
                sbc #TEXT_WIDTH       ; Subtract screen width from text length and invert
                eor #$ff              ;   negative result to get total whitespaces around
                lsr                   ;   text. Divide that by 2.
                
                tax
                tay
                
                lda #' '              ; Write leading whitespace
:               jsr CHROUT
                dey
                bne :-

                jsr WLRaw             ; Write text

                txa
                tay

                lda #' '              ; Write trailing whitespace
:               jsr CHROUT
                dey
                bne :-

                rts

;-----------------------------------------------------------------------------------
; DrawVU        Draw the current VU meter at the top of the screen
;-----------------------------------------------------------------------------------

.if C64         ; Color only available on the C64
                ; Color memory bytes that will back the VU meter, and only need to be set once
VUColorTable:   .byte RED, RED, RED, YELLOW, YELLOW, YELLOW, YELLOW, YELLOW
                .byte GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN
                .byte BLACK, BLACK
                .byte GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN
                .byte YELLOW, YELLOW, YELLOW, YELLOW, YELLOW, RED, RED, RED
                VUColorTableLen = * - VUColorTable
                .assert(VUColorTableLen >= MAX_VU * 2 + 2), error   ; VU plus two spaces in the middle

                ; Copy the color memory table for the VU meter to the right place in color RAM

InitVU:         ldy #VUColorTableLen-1
:               lda VUColorTable, y
                sta VUCOLORPOS, y
                dey
                bpl :-

.endif

                ; Draw the VU meter on right, then draw its mirror on the left

DrawVU:         lda #<VUPOS1
                sta zptmp
                lda #>VUPOS1
                sta zptmp+1
                lda #<VUPOS2
                sta zptmpB
                lda #>VUPOS2
                sta zptmpB+1

                ldy #0
                ldx #MAX_VU-1
vuloop:         lda #VUSYMBOL
                cpy VU                ; If we're at or below the VU value we use the
                bcc :+                ;   VUSYMBOL to draw the current char else we use
                lda #MEDIUMSHADE      ;   the partial shade symbol
:               sta (zptmp),y         ; Store the char in screen memory
                sta tempOutput

                tya
                pha                   ; Save Y
                txa
                tay                   ; Move X into Y

                lda tempOutput
                sta (zptmpB), y

                pla
                tay
                iny
                dex
                cpy #MAX_VU
                bcc vuloop

                rts

;-----------------------------------------------------------------------------------
; Multiply      Multiplies X * Y == ResultLo/ResultHi
;-----------------------------------------------------------------------------------
;               X   8 bit value in
;               Y   8 bit value in
;
; Apparent credit to Leif Stensson for this approach!
;-----------------------------------------------------------------------------------

Multiply:
                stx resultLo
                sty resultHi
                lda  #0
                ldx  #8
                lsr  resultLo
mloop:          bcc  no_add
                clc
                adc  resultHi
no_add:         ror
                ror  resultLo
                dex
                bne  mloop
                sta  resultHi
                rts

;-----------------------------------------------------------------------------------
; DrawSquare
;-----------------------------------------------------------------------------------
; Draw a square on the screen buffer using PETSCII graphics characters.  Each corner
; get's a special PETSCII corner character and the top and bottom and left/right
; sides are specified as separate characters also.
;
; Does not draw the color chars on the 64, expects those to be filled in by someone
; or somethig else, as it slows things down if not strictly needed.
;
; SquareX      - Arg: X pos of square
; SquareY        Arg: Y pos of square
; Width          Arg: Square width      Must be 2+
; Height         Arg: Square Height     Must be 2+
;-----------------------------------------------------------------------------------

DrawSquare:     ldx SquareX
                ldy SquareY

                lda Height            ; Early out - do nothing for less than 2 height
                cmp #2
                bpl :+
                rts
:
                lda Width             ; Early out - do nothing for less than 2 width
                cmp #2
                bpl :+
                rts
:
                lda #TOPLEFTSYMBOL    ; Top Left Corner
                jsr OutputSymbolXY
                lda #HLINE1SYMBOL     ; Top Line
                sta lineChar
                lda Width
                sec
                sbc #2                ; 2 less due to start and end chars
                cmp #1
                bmi :+
                inx                   ; start one over after start char
                jsr DrawHLine
                dex                   ; put x back where it was
:
                lda #VLINE1SYMBOL     ; Otherwise draw middle vertical lines
                sta lineChar
                lda Height
                sec
                sbc #2
                cmp #1
                bmi :+
                iny
                jsr DrawVLine
               ; dey                  ; Normally post-dec Y to fix it up, but not needed here
:                                     ;   because Y is loaded explicitly below anyway
                lda SquareX
                clc
                adc Width
                sec
                sbc #1
                tax
                ldy SquareY
                lda #TOPRIGHTSYMBOL
                jsr OutputSymbolXY

                lda #VLINE2SYMBOL
                sta lineChar
                lda Height
                sec
                sbc #2
                iny
                jsr DrawVLine
bottomline:
                ldx SquareX
                lda SquareY
                clc
                adc Height
                sec
                sbc #1
                tay
                lda #BOTTOMLEFTSYMBOL
                jsr OutputSymbolXY
                lda #HLINE2SYMBOL
                sta lineChar

                lda Width
                sec
                sbc #2                ; Account for first and las chars
                inx                   ; Start one over past stat char
                jsr DrawHLine
              ; dex                   ; Put X back where it was if you need to preserve X

                lda SquareX
                clc
                adc Width
                sec
                sbc #1
                tax
                lda SquareY
                clc
                adc Height
                sec
                sbc #1
                tay
                lda #BOTTOMRIGHTSYMBOL
                jsr OutputSymbolXY
donesquare:     rts

;-----------------------------------------------------------------------------------
; OutputSymbolXY    Draws the given symbol A into the screen at pos X, Y
;-----------------------------------------------------------------------------------
;               X       X Coord [PRESERVED]
;               Y       Y Coord [PRESERVED]
;               A       Symbol
;-----------------------------------------------------------------------------------
; Unlike my original impl, this doesn't merge, so lines can't intersect, but this
; way no intermediate buffer is required and it draws right to the screen directly.
;-----------------------------------------------------------------------------------

OutputSymbolXY: sta tempOutput
                stx tempX
                sty tempY

                jsr GetCursorAddr     ; Store the screen code in
                stx zptmp             ; screen RAM
                sty zptmp+1

                ldy #0
                lda tempOutput
                sta (zptmp),y

                ldx tempX
                ldy tempY
                rts

;-----------------------------------------------------------------------------------
; DrawHLine     Draws a horizontal line in screen memory
;-----------------------------------------------------------------------------------
;               X       X Coord of Start [PRESERVED]
;               Y       Y Coord of Start [PRESERVED]
;               A       Length of line
;-----------------------------------------------------------------------------------

DrawHLine:      sta tempDrawLine      ; Start at the X/Y pos in screen mem
                cmp #1
                bpl :+
                rts
:
                tya                   ; Save X, Y
                pha
                txa
                pha

                jsr GetCursorAddr
                stx zptmp
                sty zptmp+1

                ldy tempDrawLine      ; Draw the line
                dey
                lda lineChar          ; Store the line character in screen ram
:               sta (zptmp), y
                dey                   ; Rinse and repeat
                bpl :-

                pla                   ; Restore X, Y
                tax
                pla
                tay
                rts

;-----------------------------------------------------------------------------------
; DrawVLine     Draws a vertical line in screen memory
;-----------------------------------------------------------------------------------
;               X       X Coord of Start [PRESERVED]
;               Y       Y Coord of Start [PRESERVED]
;               A       Length of line
;-----------------------------------------------------------------------------------

DrawVLine:      sta tempDrawLine      ; Start at the X/Y pos in screen mem
                cmp #1
                bpl :+
                rts
:
                jsr GetCursorAddr     ; Get the screen memory addr of the
                stx zptmp             ;   line's X/Y start position
                sty zptmp+1

vloop:          lda lineChar          ; Store the line char in screen mem

                ldy #0
                sta (zptmp), y

                lda zptmp             ; Now add 40/80 to the lsb of ptr
                clc
                adc #XSIZE
                sta zptmp
                bcc :+
                inc zptmp+1           ; On overflow in the msb as well
:
                dec tempDrawLine      ; One less line to go
                bne vloop
                rts

.if C64         ; Color only available on the C64

;-----------------------------------------------------------------------------------
; SetPrevScheme - Switch to previous color scheme
;-----------------------------------------------------------------------------------

SetPrevScheme:
                dec CurSchemeIndex
                bpl FillBandColors    ; If index >= 0, we're done

                lda #<BandSchemeTable ; Base address for color scheme table
                sta zptmpB
                lda #>BandSchemeTable
                sta zptmpB+1
                
                ldy #1                ; Prep for first scheme table entry

@loop:          iny                   ; Move on to next table entry
                
                lda (zptmpB),y        ; Check if we hit the null pointer
                iny
                ora (zptmpB),y

                bne @loop             ; No? Continue looking

                dey                   ; Back up one table entry
                dey
                tya
                clc
                lsr                   ; Divide index by two and store
                sta CurSchemeIndex

                bcs FcColorMem        ; Branch always (lsr shifted bit into carry)


;-----------------------------------------------------------------------------------
; SetNextScheme - Switch to next color scheme
;-----------------------------------------------------------------------------------

SetNextScheme:
                lda #<BandSchemeTable ; Base address for color scheme table
                sta zptmpB
                lda #>BandSchemeTable
                sta zptmpB+1

                inc CurSchemeIndex    ; Bump up color scheme index
                lda CurSchemeIndex
                asl
                tay

                lda (zptmpB),y
                iny
                ora (zptmpB),y
                bne FcColorMem
                sta CurSchemeIndex    ; Zero pointer = end of table, so start over
                beq FcColorMem


;-----------------------------------------------------------------------------------
; FillBandColors - Color bands using the current band color scheme
;
; This routine spends quite a few instructions juggling bytes around registers, the
; stack and zptmpC. The reason basically is that indirect indexed addressing can
; only be done when loading and saving A, using Y as the index register. We have two
; pointers to apply indirect indexed adressing to (color RAM and band color scheme).
;-----------------------------------------------------------------------------------

FillBandColors:
                lda #<BandSchemeTable ; Base address for color scheme table
                sta zptmpB
                lda #>BandSchemeTable
                sta zptmpB+1

FcColorMem:     lda #YSIZE-TOP_MARGIN-BOTTOM_MARGIN   ; Count of rows to paint color for
                sta tempY

                BAND_COLOR_LOC = COLOR_MEM + XSIZE * TOP_MARGIN + LEFT_MARGIN

                lda #<BAND_COLOR_LOC                  ; Base address for bar color RAM
                sta zptmp
                lda #>BAND_COLOR_LOC
                sta zptmp+1

                ; The following is the assembly version of:
                ;   colorCount = (byte**)BandSchemeTable[CurSchemeIndex][0]

                lda CurSchemeIndex    ; Load color scheme address from table...
                asl
                tay
                lda (zptmpB),y
                tax
                iny 
                lda (zptmpB),y

                stx zptmpB            ; ...and make that the new base address in zptmpB
                sta zptmpB+1

@fcrow:         ldy #0                ; Load scheme color count
                lda (zptmpB),y        ;   and save it as the scheme color index
                sta zptmpC

                lda #NUM_BANDS        ; Color in from right-hand char of right-most bar
                asl                   ; First char index = (NUM_BANDS * 2) - 1
                tay
                dey

@fcloop:        tya                   ; Push character index on stack
                pha

                ldy zptmpC            ; Load color from scheme and hold it in X
                lda (zptmpB),y
                tax
                dey                   ; Back up one color in the scheme
                bne @notzero          ; Color index zero? We've used our scheme colors
                lda (zptmpB),y        ;   so it's time to reload scheme color count
                tay
@notzero:       sty zptmpC            ; Store scheme color index

                pla                   ; Pop character index
                tay

                txa                   ; Write color to bar chars
                sta (zptmp),y
                dey
                sta (zptmp),y
                dey
                bpl @fcloop

                lda zptmp             ; Move on to next row
                clc
                adc #XSIZE
                sta zptmp
                bcc :+
                inc zptmp+1

:               dec tempY
                bne @fcrow

                rts

.endif          ; C64

;-----------------------------------------------------------------------------------
; DrawBand      Draws a single band of the spectrum analyzer
;-----------------------------------------------------------------------------------
;               X       Band Number     [PRESERVED]
;               A       Height of bar
;-----------------------------------------------------------------------------------
; Static version that makes assumptions:
;               No dynamic color memory
;               Band Width of 2
;
; Walks down the screen and depending on whether the current pos is above, equal, or 
; below the bar itself, draws blanks, the bar top, the bar middle, bar bottom or 
; "single-height" characters
;-----------------------------------------------------------------------------------

DrawBand:       sta Height            ; Height is height of bar itself
                txa
                asl
                sta SquareX           ; Bar xPos on screen

                ; Square Y will be the screen line number of the top of the bar

                lda #YSIZE - BOTTOM_MARGIN
                sec
                sbc Height
                sta SquareY

                ; tempY is the current screen line

                lda #TOP_MARGIN
                sta tempY             ; We start on the first screen line of the analyzer

                SCREEN_LOC = (SCREEN_MEM + XSIZE * TOP_MARGIN + LEFT_MARGIN)

                lda #<SCREEN_LOC      ; zptmp points to top left of first bar
                sta zptmp             ;  in screen memory
                lda #>SCREEN_LOC
                sta zptmp+1

lineSwitch:     ldy SquareX           ; Y will be the X-pos (zp addr mode not supported on X register)
                lda tempY             ; Current screen line
                cmp #YSIZE - BOTTOM_MARGIN - 1
                bne @notlastline
                lda Height            ; If 0 height, write blanks instead of band base
                beq drawLastBlanks
                cmp #1
                beq drawOneLine
                bne drawLastLine
@notlastline:   cmp SquareY           ; Compare to screen line of top of bar
                bcc drawBlanks
                beq drawFirstLine
                bcs drawMiddleLine
drawBlanks:
                lda #' '
                sta (zptmp),y
                iny
                sta (zptmp),y
                inc tempY
                bne lineLoop
drawFirstLine:
                lda CharDefs + visualDef::TOPLEFTSYMBOL
                sta (zptmp),y
                iny
                lda CharDefs + visualDef::TOPRIGHTSYMBOL
                sta (zptmp),y
                inc tempY
                bne lineLoop
drawMiddleLine:
                lda CharDefs + visualDef::VLINE1SYMBOL
                sta (zptmp),y
                iny
                lda CharDefs + visualDef::VLINE2SYMBOL
                sta (zptmp),y
                inc tempY
                cpy #YSIZE-BOTTOM_MARGIN-1
                bne lineLoop
drawLastLine:
                ldy SquareX
                lda CharDefs + visualDef::BOTTOMLEFTSYMBOL
                sta (zptmp),y
                iny
                lda CharDefs + visualDef::BOTTOMRIGHTSYMBOL
                sta (zptmp),y
                rts
drawOneLine:
                ldy SquareX
                lda CharDefs + visualDef::ONELINE1SYMBOL
                sta (zptmp),y
                iny
                lda CharDefs + visualDef::ONELINE2SYMBOL
                sta (zptmp),y
                rts
drawLastBlanks:
                lda #' '
                sta (zptmp),y
                iny
                sta (zptmp),y
                rts

lineLoop:       lda zptmp             ; Advance zptmp by one screen line down
                clc
                adc #XSIZE
                sta zptmp
                lda zptmp+1
                adc #0
                sta zptmp+1
                jmp lineSwitch

;-----------------------------------------------------------------------------------
; PlotEx        Replacement for KERNAL plot that fixes color ram update bug
;-----------------------------------------------------------------------------------
;               X       Cursor Y Pos
;               Y       Cursor X Pos
;               (NOTE Reversed)
;-----------------------------------------------------------------------------------

PlotEx:
.if C64         ; On the C64 we use, but fix, the PLOT kernal routine
                bcs     :+
                jsr     PLOT          ; Set cursor position using original ROM PLOT
                jmp     UPDCRAMPTR    ; Set pointer to color RAM to match new cursor position
:               jmp     PLOT          ; Get cursor position
.endif

.if PET         ; PET has no PLOT in kernal. This code is loaned from CC65's CLIB routines
                bcs     @fetch         ; Fetch values if carry set
                sty     CURS_X
                stx     CURS_Y
                ldy     CURS_Y
                lda     ScrLo,y
                sta     SCREEN_PTR
                lda     ScrHi,y
                ora     #$80           ; Screen at $8000
                sta     SCREEN_PTR+1
                rts

@fetch:         ldy     CURS_X
                ldx     CURS_Y
                rts
.endif          ; PET

.if C64         ; CIAs only available on C64

;----------------------------------------------------------------------------
; InitTODClocks - Initialize CIA clockS to correct external frequency (50/60Hz)
;
; This routine figures out whether the C64 is connected to a 50Hz or 60Hz
; external frequency source - that traditionally being the power grid the
; AC adapter is connected to. It needs to know this to make the CIA time of 
; day clock run at the right speed; getting it wrong makes the clock 20% off.
; This routine was effectively sourced from the following web page:
; https://codebase64.org/doku.php?id=base:efficient_tod_initialisation
; Credits for it go to Silver Dream.
;----------------------------------------------------------------------------

InitTODClocks:
                lda CIA2_CRB
                and #$7f                ; Set CIA2 TOD clock, not alarm
                sta CIA2_CRB

                sei
                lda #$00
                sta CIA2_TOD10          ; Start CIA2 TOD clock
@tickloop:      cmp CIA2_TOD10          ; Wait until tenths value changes
                beq @tickloop

                lda #$ff                ; Count down from $ffff (65535)
                sta CIA2_TA             ; Use timer A
                sta CIA2_TA+1
            
                lda #%00010001          ; Set TOD to 60Hz mode and start the
                sta CIA2_CRA            ;   timer.

                lda CIA2_TOD10
@countloop:     cmp CIA2_TOD10          ; Wait until tenths value changes
                beq @countloop

                ldx CIA2_TA+1
                cli

                lda CIA1_CRA

                cpx #$51                ; If timer HI > 51, we're at 60Hz
                bcs @pick60hz1

                ora #$80                ; Configure CIA1 TOD to run at 50Hz
                bne @setfreq1

@pick60hz1:     and #$7f                ; Configure CIA1 TOD to run at 60Hz

@setfreq1:      sta CIA1_CRA

                lda CIA2_CRA

                cpx #$51                ; If timer HI > 51, we're at 60Hz
                bcs @pick60hz2

                ora #$80                ; Configure CIA2 TOD to run at 50Hz
                bne @setfreq2

@pick60hz2:     and #$7f                ; Configure CIA2 TOD to run at 60Hz

@setfreq2:      sta CIA2_CRA

                rts

.endif          ; C64

;-----------------------------------------------------------------------------------
; StartTextTimer - Start the text TOD timer
;-----------------------------------------------------------------------------------

StartTextTimer:
.if C64         ; CIAs only available on the C64
                lda CIA1_CRB            ; Clear CRB7 to set the TOD, not an alarm
                and #$7f
                sta CIA1_CRB

                lda #$00

                sta CIA1_TODHR
                sta CIA1_TODMIN
                sta CIA1_TODSEC
                sta CIA1_TOD10          ; This write starts the clock
.endif

.if PET         ; We use a more rudimentary countdown timer on the PET
                lda #$00
                sta TextCountDown
  .if SERIAL    ; 
                lda #$20                ; Serial handling takes time, so we count
  .else                                 ;   down from a lower value than when
                lda #$40                ;   serial is disabled
  .endif
                sta TextCountDown+1
.endif
                rts

.if PET

;-----------------------------------------------------------------------------------
; DownTextTimer - Cut the PET text timer down by a chunk
;-----------------------------------------------------------------------------------

DownTextTimer:
                lda TextTimeout
                beq @done

                dec TextCountDown+1     ; We take off 384 just because that seems 
                beq @atzero             ;   to work out about right for one screen
                lda TextCountDown       ;   redraw.
                sec
                sbc #$80
                sta TextCountDown
                bcs @done
                dec TextCountDown+1
                bne @done

@atzero:        lda #1                  ; Due to how CheckTextTimer assesses if time
                sta TextCountDown       ;   has run out, set lo and hi bytes to 1 to
                sta TextCountDown+1     ;   finish counting down this sorta second.

@done:          rts

.endif

;-----------------------------------------------------------------------------------
; CheckTextTimer - Clear text if TOD timer is at "TextTimeout" seconds
;-----------------------------------------------------------------------------------

CheckTextTimer:
                lda TextTimeout
                beq @done

.if C64         ; Use the CIA timer on the C64
                cmp CIA1_TODSEC
                bcs @done

                lda #0
                sta TextTimeout
                jmp ClearTextBlock
.endif

.if PET         ; Decrease countdown timer until we reach $0000
                dec TextCountDown
                bne @done
                dec TextCountDown+1
                bne @done

                dec TextTimeout       ; Decrease timeout second count
                beq ClearTextBlock    ; If we've reached 0, clear the text block
                jmp StartTextTimer    ; Otherwise, count down another rough second
.endif

@done:          rts

; Note: ClearTextBlock must be within branch reach of CheckTextTimer!

;-----------------------------------------------------------------------------------
; ClearTextBlock - Clear text block lines
;-----------------------------------------------------------------------------------

ClearTextBlock:
                clc                   ; Prepare for start of writing
.if C64         ; Color only available on the C64
                lda #WHITE
                sta TEXT_COLOR
.endif

                ldx #TOP_MARGIN+BAND_HEIGHT
                stx tempY

@rowloop:       ldy #LEFT_MARGIN      ; Set cursor at end of left margin
                jsr PlotEx

                ldy #TEXT_WIDTH       ; Write spaces
                lda #' '
:               jsr CHROUT
                dey
                bne :-

                inc tempY             ; Move on to next line
                ldx tempY
                cpx #YSIZE-1
                bne @rowloop

                rts

.if TIMING && C64

;-----------------------------------------------------------------------------------
; InitTimer     Initlalize a CIA timer to run at 1ms so we can do timings
;-----------------------------------------------------------------------------------

InitTimer:

                lda   #$7F            ; Mask to turn off the CIA IRQ
                ldx   #<TIMERSCALE    ; Timer low value
                ldy   #>TIMERSCALE    ; Timer High value
                sta   CIA2_ICR
                stx   CIA2_TA         ; Set to 1msec (1022 cycles per IRQ)
                sty   CIA2_TA+1
                lda   #$FF            ; Set counter to FFFF
                sta   CIA2_TB
                sta   CIA2_TB+1
                ldy   #$51
                sty   CIA2_CRB        ; Enable and go
                rts

.endif          ; TIMING && C64

;-----------------------------------------------------------------------------------
; SetNextStyle - Select a visual style for the spectrum analyzer by copying a small
;               character table of PETSCII screen codes into our 'styletable' that
;               we use to draw the spectrum analyzer bars.  It defines the PETSCII
;               chars that we use to draw the corners and lines.
;-----------------------------------------------------------------------------------
; Copy the next style into the style table and increment the style table pointer
; with wraparound so that we can pick the next style next time in.
;-----------------------------------------------------------------------------------

SetNextStyle:   lda NextStyle         ; Take the style index and multiply by 2
                tax                   ;   to get the Y index into the lookup table
                asl                   ;   so we can fetch the actual address of the
                tay                   ;   char table.  Because it is a mult of 8 in
                inx                   ;   size we could do without a lookup, but why assume...
                txa                   ; Increment the NextStyle index and do a MOD 4 on it
                and #3                ;   and then put it back so that the index cycles 0-3
                sta NextStyle

                lda StyleTable, y     ; Get the entry in the styletable, which is stored as
                sta zptmp             ;   a list of word addresses, and put that address
                iny                   ;   into zptmp as the 'source' of our memcpy
                lda StyleTable, y
                sta zptmp+1
                ldy #.sizeof(visualDef) - 1  ; Y is the size we're going to copy (the size of the struct)
:               lda (zptmp),y         ; Copy from source to dest
                sta CharDefs, y
                dey
                bpl :-
                rts

; Visual style definitions.  See the 'visualDef' structure defn in petrock.inc
; Each of these small tables includes the characters needed to draw the corners
; and vertical lines needed to form a box. Finally, the characters to use for bands
; of height 1 are also specified.

SkinnyRoundStyle:                     ; PETSCII screen codes for round tube bar style
.if C64
  .byte 85, 73, 74, 75, 66, 66, 74, 75, 32, 32
.endif
.if PET
  .byte 85, 73, 74, 75, 93, 93, 74, 75, 32, 32
.endif

DrawSquareStyle:                      ; PETSCII screen codes for square linedraw style
  .byte 79, 80, 76, 122, 101, 103, 76, 122, 32, 32

BreakoutStyle:                        ; PETSCII screen codes for style that looks like breakout
.if C64
  .byte 239, 250, 239, 250, 239, 250, 239, 250, 239, 250
.endif
.if PET
  .byte 228, 250, 228, 250, 228, 250, 228, 250, 228, 250
.endif

CheckerboardStyle:                    ; PETSCII screen codes for checkerboard style
  .byte 102, 92, 102, 92, 102, 92,102, 92, 102, 92

; Lookup table - each of the above mini tables is listed in this lookup table so that
;                we can easily find items 0-3
;
; The code currently assumes that there are four entries such that is can easily
; modulus the values.  These are the four entries.

StyleTable:
  .word SkinnyRoundStyle, BreakoutStyle, CheckerboardStyle, DrawSquareStyle

.if C64         ; Color only available on the C64

;-----------------------------------------------------------------------------------
; Band color schemes
;
; Collection of band color schemes the user can cycle through:
; - The pointer table is zero-pointer terminated.
; - Each scheme is a list of colors that the background color fill routine cycles
;   through. The number of colors in a scheme are specified just before the first
;   actual color value. Note that the color schemes are applied to the bars right
;   to left.
;-----------------------------------------------------------------------------------

BandSchemeTable: 
                .word RainbowScheme
                .word WhiteScheme
                .word GreenScheme
                .word RedScheme
                .word RWBScheme
                .word 0

RainbowScheme:  .byte 16
                .byte RED, ORANGE, YELLOW, GREEN, CYAN, BLUE, PURPLE, RED
                .byte ORANGE, YELLOW, GREEN, CYAN, BLUE, PURPLE, RED, YELLOW

WhiteScheme:    .byte 1
                .byte WHITE

GreenScheme:    .byte 1
                .byte GREEN

RedScheme:      .byte 1
                .byte RED

RWBScheme:      .byte 3
                .byte RED, WHITE, BLUE


.endif          ; C64

; String literals at the end of file, as was the style at the time!

.include "fakedata.inc"

.if PET
notonoldrom:    .literal "SORRY, NO PETROCKING ON ORIGINAL ROMS.", 13, 0
.endif

startstr:       .literal "STARTING...", 13, 0
exitstr:        .literal "EXITING...", 13, 0
framestr:       .literal "  RENDER TIME: ", 0
titlestr:       .literal 12, "C64PETROCK.COM", 0
titlelen = * - titlestr

.if C64         ; Set text color to green on C64
clrGREEN:       .literal $99, $93, 0
.endif
.if PET         ; Color's not a thing on the PET
clrGREEN:       .literal $93, 0
.endif

DemoOnText:     .literal "DEMO MODE ON", 0
DemoOffText:    .literal "DEMO MODE OFF", 0

EmptyText:      .byte    ' ', 0

.if C64         ; Include help on color schemes on C64
HelpText1:      .literal "C: COLOR - S: STYLE - D: DEMO", 0
.endif
.if PET         ; Don't mention color on the PET
HelpText1:      .literal "S: STYLE - D: DEMO", 0
.endif
HelpText2:      .literal "B: BORDER - RUN/STOP: EXIT", 0

.if PET         ; This is used by the PlotEx routine for the PET

; Screen address tables - offset to real screen

.rodata

ScrLo:  .byte   $00, $28, $50, $78, $A0, $C8, $F0, $18
        .byte   $40, $68, $90, $B8, $E0, $08, $30, $58
        .byte   $80, $A8, $D0, $F8, $20, $48, $70, $98
        .byte   $C0

ScrHi:  .byte   $00, $00, $00, $00, $00, $00, $00, $01
        .byte   $01, $01, $01, $01, $01, $02, $02, $02
        .byte   $02, $02, $02, $02, $03, $03, $03, $03
        .byte   $03

.endif