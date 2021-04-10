; @file
; Copyright (C) 2021, ISP RAS. All rights reserved.
;
; All rights reserved.
;
; This program and the accompanying materials
; are licensed and made available under the terms and conditions of the BSD License
; which accompanies this distribution.  The full text of the license may be found at
; http://opensource.org/licenses/bsd-license.php
;
; THE PROGRAM IS DISTRIBUTED UNDER THE BSD LICENSE ON AN "AS IS" BASIS,
; WITHOUT WARRANTIES OR REPRESENTATIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED.
;
; #######################################################################
;
;  This code is described in an Intel White-Paper:
;  "Fast SHA-512 Implementations on Intel Architecture Processors"
;
; ########################################################################
; ### Binary Data
BITS 64

section .rodata
align 16
; Mask for byte-swapping a couple of qwords in an XMM register using (v)pshufb.
XMM_QWORD_BSWAP:
	dq 0x0001020304050607,0x08090a0b0c0d0e0f

align 64
; K[t] used in SHA512 hashing
K512:
	dq 0x428a2f98d728ae22,0x7137449123ef65cd
	dq 0xb5c0fbcfec4d3b2f,0xe9b5dba58189dbbc
	dq 0x3956c25bf348b538,0x59f111f1b605d019
	dq 0x923f82a4af194f9b,0xab1c5ed5da6d8118
	dq 0xd807aa98a3030242,0x12835b0145706fbe
	dq 0x243185be4ee4b28c,0x550c7dc3d5ffb4e2
	dq 0x72be5d74f27b896f,0x80deb1fe3b1696b1
	dq 0x9bdc06a725c71235,0xc19bf174cf692694
	dq 0xe49b69c19ef14ad2,0xefbe4786384f25e3
	dq 0x0fc19dc68b8cd5b5,0x240ca1cc77ac9c65
	dq 0x2de92c6f592b0275,0x4a7484aa6ea6e483
	dq 0x5cb0a9dcbd41fbd4,0x76f988da831153b5
	dq 0x983e5152ee66dfab,0xa831c66d2db43210
	dq 0xb00327c898fb213f,0xbf597fc7beef0ee4
	dq 0xc6e00bf33da88fc2,0xd5a79147930aa725
	dq 0x06ca6351e003826f,0x142929670a0e6e70
	dq 0x27b70a8546d22ffc,0x2e1b21385c26c926
	dq 0x4d2c6dfc5ac42aed,0x53380d139d95b3df
	dq 0x650a73548baf63de,0x766a0abb3c77b2a8
	dq 0x81c2c92e47edaee6,0x92722c851482353b
	dq 0xa2bfe8a14cf10364,0xa81a664bbc423001
	dq 0xc24b8b70d0f89791,0xc76c51a30654be30
	dq 0xd192e819d6ef5218,0xd69906245565a910
	dq 0xf40e35855771202a,0x106aa07032bbd1b8
	dq 0x19a4c116b8d2d0c8,0x1e376c085141ab53
	dq 0x2748774cdf8eeb99,0x34b0bcb5e19b48a8
	dq 0x391c0cb3c5c95a63,0x4ed8aa4ae3418acb
	dq 0x5b9cca4f7763e373,0x682e6ff3d6b2b8a3
	dq 0x748f82ee5defb2fc,0x78a5636f43172f60
	dq 0x84c87814a1f0ab72,0x8cc702081a6439ec
	dq 0x90befffa23631e28,0xa4506cebde82bde9
	dq 0xbef9a3f7b2c67915,0xc67178f2e372532b
	dq 0xca273eceea26619c,0xd186b8c721c0c207
	dq 0xeada7dd6cde0eb1e,0xf57d4f7fee6ed178
	dq 0x06f067aa72176fba,0x0a637dc5a2c898a6
	dq 0x113f9804bef90dae,0x1b710b35131c471b
	dq 0x28db77f523047d84,0x32caab7b40c72493
	dq 0x3c9ebe0a15c9bebc,0x431d67c49c100d4c
	dq 0x4cc5d4becb3e42b6,0x597f299cfc657e2a
	dq 0x5fcb6fab3ad6faec,0x6c44198c4a475817

; ########################################################################
; ### Code

section .text

; Virtual Registers
; ARG1
; rcx == sha512_state *state
%define digest  rcx
; ARG2
; rdx == const u8 *data
%define msg     rdx
; ARG3
; r8  == int blocks
%define msglen  r8

%define T1    rdi
%define T2    rbx
%define a_64  rsi
%define b_64  r9
%define c_64  r10
%define d_64  r11
%define e_64  r12
%define f_64  r13
%define g_64  r14
%define h_64  r15
%define tmp0  rax

; Local variables (stack frame)

; Message Schedule
%define W_SIZE        80*8
; W[t] + K[t] | W[t+1] + K[t+1]
%define WK_SIZE       2*8
%define RSPSAVE_SIZE  1*8
%define GPRSAVE_SIZE  8*8

%define frame_W        0
%define frame_WK       frame_W + W_SIZE
%define frame_RSPSAVE  frame_WK + WK_SIZE
%define frame_GPRSAVE  frame_RSPSAVE + RSPSAVE_SIZE
%define frame_size     frame_GPRSAVE + GPRSAVE_SIZE

; Useful QWORD "arrays" for simpler memory references
; MSG, DIGEST, K_t, W_t are arrays
; WK_2(t) points to 1 of 2 qwords at frame.WK depdending on t being odd/even

; Input message (arg1)
%define MSG(i)    [msg + 8*i]

; Output Digest (arg2)
%define DIGEST(i) [digest + 8*i]

; SHA Constants (static mem)
%define K_t(i)    [rel 8*i + K512]

; Message Schedule (stack frame)
%define W_t(i)    [rsp + 8*i + frame_W]

; W[t]+K[t] (stack frame)
%define WK_2(i)   [rsp + 8*((i % 2)) + frame_WK]

%macro RotateState 0
	; Rotate symbols a..h right
  %xdefine TMP  h_64
	%xdefine h_64 g_64
	%xdefine g_64 f_64
	%xdefine f_64 e_64
	%xdefine e_64 d_64
	%xdefine d_64 c_64
	%xdefine c_64 b_64
	%xdefine b_64 a_64
	%xdefine a_64 TMP
%endmacro

%macro RORQ 2
	; shld is faster than ror on Sandybridge
	shld	%1, %1, (64-%2)
%endmacro

%macro SHA512_Round_Optimized 1
  mov     T1, f_64          ; T1 = f
  mov     tmp0, e_64        ; tmp = e
  xor     T1, g_64          ; T1 = f ^ g
  RORQ    tmp0, 23   ; 41   ; tmp = e ror 23
  and     T1, e_64          ; T1 = (f ^ g) & e
  xor     tmp0, e_64        ; tmp = (e ror 23) ^ e
  xor     T1, g_64          ; T1 = ((f ^ g) & e) ^ g = CH(e,f,g)
  %assign idx  %1
  add     T1, WK_2(idx)     ; W[t] + K[t] from message scheduler
  RORQ    tmp0, 4   ; 18    ; tmp = ((e ror 23) ^ e) ror 4
  xor     tmp0, e_64        ; tmp = (((e ror 23) ^ e) ror 4) ^ e
  mov     T2, a_64          ; T2 = a
  add     T1, h_64          ; T1 = CH(e,f,g) + W[t] + K[t] + h
  RORQ    tmp0, 14  ; 14    ; tmp = ((((e ror23)^e)ror4)^e)ror14 = S1(e)
  add     T1, tmp0          ; T1 = CH(e,f,g) + W[t] + K[t] + S1(e)
  mov     tmp0, a_64        ; tmp = a
  xor     T2, c_64          ; T2 = a ^ c
  and     tmp0, c_64        ; tmp = a & c
  and     T2, b_64          ; T2 = (a ^ c) & b
  xor     T2, tmp0          ; T2 = ((a ^ c) & b) ^ (a & c) = Maj(a,b,c)
  mov     tmp0, a_64        ; tmp = a
  RORQ    tmp0, 5  ; 39     ; tmp = a ror 5
  xor     tmp0, a_64        ; tmp = (a ror 5) ^ a
  add     d_64, T1          ; e(next_state) = d + T1
  RORQ    tmp0, 6  ; 34     ; tmp = ((a ror 5) ^ a) ror 6
  xor     tmp0, a_64        ; tmp = (((a ror 5) ^ a) ror 6) ^ a
  lea     h_64, [T1 + T2]   ; a(next_state) = T1 + Maj(a,b,c)
	RORQ    tmp0, 28  ; 28    ; tmp = ((((a ror5)^a)ror6)^a)ror28 = S0(a)
	add     h_64, tmp0        ; a(next_state) = T1 + Maj(a,b,c) S0(a)
	RotateState
%endmacro

; Compute Round t
%macro SHA512_Round 1
  ; Ch(e,f,g) = (e & f) ^ (~e & g)
  mov T1, e_64         ; T1 = e
  and T1, f_64         ; T1 = e & f
	mov tmp0, e_64       ; tmp0 = e
  not tmp0             ; tmp0 = ~e
  and tmp0, g_64       ; tmp0 = ~e & g
  xor T1, tmp0         ; T1 = (e & f) ^ (~e & g)

  ; Sigma[1,512](e) = (e ROTR 14) ^ (e ROTR 18) ^ (e ROTR 41)
  mov  tmp0, e_64      ; tmp0 = e
	RORQ tmp0, 14        ; tmp0 = e ROTR 14
  mov  T2, e_64        ; T2 = e
	RORQ T2, 18          ; T2 = e ROTR 18
  xor  tmp0, T2        ; tmp0 = (e ROTR 14) ^ (e ROTR 18)
	RORQ T2, 23          ; T2 = e ROTR 41
  xor  tmp0, T2        ; tmp0 = (e ROTR 14) ^ (e ROTR 18) ^ (e ROTR 41)

  ; T1 = h + Sigma[1,512](e) + Ch(e,f,g) + K[t] + W[t]
  add T1, tmp0         ; T1 = Ch(e,f,g) + Sigma[1,512](e)
  %assign idx  %1
  add T1, WK_2(idx)    ; T1 = Ch(e,f,g) + Sigma[1,512](e) + W[t] + K[t]
  add T1, h_64         ; T1 = Ch(e,f,g) + Sigma[1,512](e) + W[t] + K[t] + h

  ; Maj(a,b,c) = (a & b) ^ (a & c) ^ (b & c)
  mov T2, a_64         ; T2 = a
  and T2, b_64         ; T2 = a & b
  mov tmp0, a_64       ; tmp0 = a
  and tmp0, c_64       ; tmp0 = a & c
  xor T2, tmp0         ; T2 = (a & b) ^ (a & c)
  mov tmp0, b_64       ; tmp0 = b
  and tmp0, c_64       ; tmp0 = b & c
  xor T2, tmp0         ; T2 = (a & b) ^ (a & c) ^ (b & c)

  RotateState          ; a = h, b = a, c = b, d = c, e = d, f = e, g = f, h = g
  add e_64, T1         ; e = d + T1
  mov a_64, T1         ; a = T1

  ; Sigma[0,512](a) = (a ROTR 28) ^ (a ROTR 34) ^ (a ROTR 39)
  mov  T1, b_64        ; T1 = a, because now b == a
  RORQ T1, 28          ; T1 = a ROTR 28
  mov  tmp0, b_64      ; tmp0 = a
	RORQ tmp0, 34        ; tmp0 = a ROTR 34
  xor T1, tmp0         ; T1 = (a ROTR 28) ^ (a ROTR 34)
  RORQ tmp0, 5         ; tmp0 = a ROTR 39
  xor T1, tmp0         ; T1 = (a ROTR 28) ^ (a ROTR 34) ^ (a ROTR 39)

  ; T2 = Sigma[0,512](a) + Maj(a,b,c)
  add T2, T1           ; T2 = Maj(a,b,c) + Sigma[0,512](a)

  add a_64, T2         ; a = T1 + T2
%%showdigest:
%endmacro

%macro SHA512_Stitched 1
  ; Compute rounds t-2 and t-1
  ; Compute message schedule QWORDS t and t+1

  ;   Two rounds are computed based on the values for K[t-2]+W[t-2] and
  ; K[t-1]+W[t-1], which were previously stored at WK_2 by the message scheduler.
  ;   The two new schedule QWORDS are stored at [W_t(t)] and [W_t(t+1)].
  ; They are then added to their respective SHA512 constants at
  ; [K_t(t)] and [K_t(t+1)] and stored at dqword [WK_2(t)].
  ;   The computation of the message schedule and the rounds are tightly
  ; stitched to take advantage of instruction-level parallelism.

	%assign idx  (%1 - 2)
  vmovdqu	xmm4, W_t(idx)      ; xmm4 = W[t-2]|W[t-1]
  mov     T1, f_64          ; T1 = f
  mov     tmp0, e_64        ; tmp = e
  vpsrlq  xmm0, xmm4, 19      ; xmm0 = W[t-2] >> 19
  xor     T1, g_64          ; T1 = f ^ g
  RORQ    tmp0, 23   ; 41   ; tmp = e ror 23
  vpsllq  xmm1, xmm4, (64-19) ; xmm1 = W[t-2] << 64-19
  and     T1, e_64          ; T1 = (f ^ g) & e
  xor     tmp0, e_64        ; tmp = (e ror 23) ^ e
  vpor    xmm0, xmm0, xmm1    ; xmm0 = (W[t-2] >> 19) | (W[t-2] << 64-19)
  xor     T1, g_64          ; T1 = ((f ^ g) & e) ^ g = CH(e,f,g)
  %assign idxR  (%1 - 2)
  add     T1, WK_2(idxR)    ; W[t] + K[t] from message scheduler
  vpsrlq  xmm2, xmm4, 61      ; xmm2 = W[t-2] >> 61
  RORQ    tmp0, 4   ; 18    ; tmp = ((e ror 23) ^ e) ror 4
  xor     tmp0, e_64        ; tmp = (((e ror 23) ^ e) ror 4) ^ e
  vpsllq  xmm1, xmm4, (64-61) ; xmm1 = W[t-2] << 64-19
  mov     T2, a_64          ; T2 = a
  add     T1, h_64          ; T1 = CH(e,f,g) + W[t] + K[t] + h
  vpor   xmm2, xmm2, xmm1     ; xmm2 = (W[t-2] >> 61) | (W[t-2] << 64-61)
  RORQ    tmp0, 14  ; 14    ; tmp = ((((e ror23)^e)ror4)^e)ror14 = S1(e)
  add     T1, tmp0          ; T1 = CH(e,f,g) + W[t] + K[t] + S1(e)
  vpxor	 xmm0, xmm0, xmm2     ; xmm0 = (W[t-2] ROTR 19) ^ (W[t-2] ROTR 61)
  mov     tmp0, a_64        ; tmp = a
  xor     T2, c_64          ; T2 = a ^ c
  vpsrlq  xmm2, xmm4, 6       ; xmm2 = W[t-2] >> 6
  and     tmp0, c_64        ; tmp = a & c
  and     T2, b_64          ; T2 = (a ^ c) & b
  vpxor	 xmm0, xmm0, xmm2     ; xmm0 = (W[t-2] ROTR 19) ^ (W[t-2] ROTR 61) ^ (W[t-2] SHR 6)
  xor     T2, tmp0          ; T2 = ((a ^ c) & b) ^ (a & c) = Maj(a,b,c)
  mov     tmp0, a_64        ; tmp = a
  %assign idx  (%1 - 15)
  vmovdqu	xmm4, W_t(idx)      ; xmm4 = W[t-15]|W[t-14]
  RORQ    tmp0, 5  ; 39     ; tmp = a ror 5
  xor     tmp0, a_64        ; tmp = (a ror 5) ^ a
  vpsrlq  xmm1, xmm4, 1       ; xmm1 = W[t-15] >> 1
  add     d_64, T1          ; e(next_state) = d + T1
  RORQ    tmp0, 6  ; 34     ; tmp = ((a ror 5) ^ a) ror 6
  vpsllq  xmm2, xmm4, (64-1)  ; xmm2 = W[t-15] << 64-1
  xor     tmp0, a_64        ; tmp = (((a ror 5) ^ a) ror 6) ^ a
  lea     h_64, [T1 + T2]   ; a(next_state) = T1 + Maj(a,b,c)
  vpor   xmm1, xmm1, xmm2     ; xmm1 = (W[t-15] >> 1) | (W[t-15] << 64-1)
  RORQ    tmp0, 28  ; 28    ; tmp = ((((a ror5)^a)ror6)^a)ror28 = S0(a)
	add     h_64, tmp0        ; a(next_state) = T1 + Maj(a,b,c) S0(a)
	RotateState
  vpsrlq  xmm3, xmm4, 8       ; xmm3 = W[t-15] >> 8
  mov     T1, f_64          ; T1 = f
  mov     tmp0, e_64        ; tmp = e
  vpsllq  xmm2, xmm4, (64-8)  ; xmm2 = W[t-15] << 64-8
  xor     T1, g_64          ; T1 = f ^ g
  RORQ    tmp0, 23   ; 41   ; tmp = e ror 23
  vpor   xmm3, xmm3, xmm2     ; xmm3 = (W[t-15] >> 8) | (W[t-15] << 64-8)
  and     T1, e_64          ; T1 = (f ^ g) & e
  xor     tmp0, e_64        ; tmp = (e ror 23) ^ e
  vpxor	 xmm1, xmm1, xmm3     ; xmm1 = (W[t-15] ROTR 1) ^ (W[t-15] ROTR 8)
  xor     T1, g_64          ; T1 = ((f ^ g) & e) ^ g = CH(e,f,g)
  %assign idxR  (%1 - 1)
  add     T1, WK_2(idxR)    ; W[t] + K[t] from message scheduler
  vpsrlq  xmm3, xmm4, 7       ; xmm3 = W[t-15] >> 7
  RORQ    tmp0, 4   ; 18    ; tmp = ((e ror 23) ^ e) ror 4
  xor     tmp0, e_64        ; tmp = (((e ror 23) ^ e) ror 4) ^ e
  vpxor	 xmm1, xmm1, xmm3     ; xmm1 = (W[t-15] ROTR 1) ^ (W[t-15] ROTR 8) ^ (W[t-15] SHR 7)
  mov     T2, a_64          ; T2 = a
  add     T1, h_64          ; T1 = CH(e,f,g) + W[t] + K[t] + h
  %assign idx  (%1 - 7)
  vpaddq xmm0, xmm0, W_t(idx) ; xmm0 = sigma[1,512](W[t-2]) + W[t-7]
  RORQ    tmp0, 14  ; 14    ; tmp = ((((e ror23)^e)ror4)^e)ror14 = S1(e)
  add     T1, tmp0          ; T1 = CH(e,f,g) + W[t] + K[t] + S1(e)
  vpaddq xmm0, xmm0, xmm1     ; xmm0 = sigma[1,512](W[t-2]) + W[t-7] + sigma[0,512](W[t-15])
  mov     tmp0, a_64        ; tmp = a
  xor     T2, c_64          ; T2 = a ^ c
  %assign idx  (%1 - 16)
  vpaddq xmm0, xmm0, W_t(idx) ; xmm0 = sigma[1,512](W[t-2]) + W[t-7] + sigma[0,512](W[t-15]) + W[t-16]
  and     tmp0, c_64        ; tmp = a & c
  and     T2, b_64          ; T2 = (a ^ c) & b
  %assign idx  %1
  vmovdqa	W_t(idx), xmm0	    ; Store W[t]
  xor     T2, tmp0          ; T2 = ((a ^ c) & b) ^ (a & c) = Maj(a,b,c)
  mov     tmp0, a_64        ; tmp = a
  vpaddq xmm0, xmm0, K_t(idx) ; Compute W[t]+K[t]
  RORQ    tmp0, 5  ; 39     ; tmp = a ror 5
  xor     tmp0, a_64        ; tmp = (a ror 5) ^ a
  vmovdqa	WK_2(idx), xmm0     ; Store W[t]+K[t] for next rounds
  add     d_64, T1          ; e(next_state) = d + T1
  RORQ    tmp0, 6  ; 34     ; tmp = ((a ror 5) ^ a) ror 6
  xor     tmp0, a_64        ; tmp = (((a ror 5) ^ a) ror 6) ^ a
  lea     h_64, [T1 + T2]   ; a(next_state) = T1 + Maj(a,b,c)
  RORQ    tmp0, 28  ; 28    ; tmp = ((((a ror5)^a)ror6)^a)ror28 = S0(a)
	add     h_64, tmp0        ; a(next_state) = T1 + Maj(a,b,c) S0(a)
	RotateState
%endmacro

; Compute message schedules t and t+1
%macro SHA512_2Sched 1
  ; x ROTR n = (x >> n) | (x << 64-n)

  ; sigma[1,512](W[t-2]) = (W[t-2] ROTR 19) ^ (W[t-2] ROTR 61) ^ (W[t-2] SHR 6)
	%assign idx  (%1 - 2)
  ; W[t-2] ROTR 19
  vmovdqu	xmm4, W_t(idx)      ; xmm4 = W[t-2]|W[t-1]
  vpsrlq  xmm0, xmm4, 19      ; xmm0 = W[t-2] >> 19
  vpsllq  xmm1, xmm4, (64-19) ; xmm1 = W[t-2] << 64-19
  vpor    xmm0, xmm0, xmm1    ; xmm0 = (W[t-2] >> 19) | (W[t-2] << 64-19)
  ; W[t-2] ROTR 61
  vpsrlq  xmm2, xmm4, 61      ; xmm2 = W[t-2] >> 61
  vpsllq  xmm1, xmm4, (64-61) ; xmm1 = W[t-2] << 64-19
  vpor   xmm2, xmm2, xmm1     ; xmm2 = (W[t-2] >> 61) | (W[t-2] << 64-61)
  vpxor	 xmm0, xmm0, xmm2     ; xmm0 = (W[t-2] ROTR 19) ^ (W[t-2] ROTR 61)
  ; W[t-2] SHR 6
  vpsrlq  xmm2, xmm4, 6       ; xmm2 = W[t-2] >> 6
  vpxor	 xmm0, xmm0, xmm2     ; xmm0 = (W[t-2] ROTR 19) ^ (W[t-2] ROTR 61) ^ (W[t-2] SHR 6)

  ; sigma[0,512](W[t-15]) = (W[t-15] ROTR 1) ^ (W[t-15] ROTR 8) ^ (W[t-15] SHR 7)
  %assign idx  (%1 - 15)
  ; W[t-15] ROTR 1
  vmovdqu	xmm4, W_t(idx)      ; xmm4 = W[t-15]|W[t-14]
	vpsrlq  xmm1, xmm4, 1       ; xmm1 = W[t-15] >> 1
  vpsllq  xmm2, xmm4, (64-1)  ; xmm2 = W[t-15] << 64-1
  vpor   xmm1, xmm1, xmm2     ; xmm1 = (W[t-15] >> 1) | (W[t-15] << 64-1)
  ; W[t-15] ROTR 8
	vpsrlq  xmm3, xmm4, 8       ; xmm3 = W[t-15] >> 8
  vpsllq  xmm2, xmm4, (64-8)  ; xmm2 = W[t-15] << 64-8
  vpor   xmm3, xmm3, xmm2     ; xmm3 = (W[t-15] >> 8) | (W[t-15] << 64-8)
  vpxor	 xmm1, xmm1, xmm3     ; xmm1 = (W[t-15] ROTR 1) ^ (W[t-15] ROTR 8)
  ; W[t-15] SHR 7
  vpsrlq  xmm3, xmm4, 7       ; xmm3 = W[t-15] >> 7
  vpxor	 xmm1, xmm1, xmm3     ; xmm1 = (W[t-15] ROTR 1) ^ (W[t-15] ROTR 8) ^ (W[t-15] SHR 7)

  ; W[t] = sigma[1,512](W[t-2]) + W[t-7] + sigma[0,512](W[t-15]) + W[t-16]
  %assign idx  (%1 - 7)
  vpaddq xmm0, xmm0, W_t(idx) ; xmm0 = sigma[1,512](W[t-2]) + W[t-7]
  vpaddq xmm0, xmm0, xmm1     ; xmm0 = sigma[1,512](W[t-2]) + W[t-7] + sigma[0,512](W[t-15])
  %assign idx  (%1 - 16)
  vpaddq xmm0, xmm0, W_t(idx) ; xmm0 = sigma[1,512](W[t-2]) + W[t-7] + sigma[0,512](W[t-15]) + W[t-16]
	%assign idx  %1
	vmovdqa	W_t(idx), xmm0	    ; Store W[t]
	vpaddq xmm0, xmm0, K_t(idx) ; Compute W[t]+K[t]
	vmovdqa	WK_2(idx), xmm0     ; Store W[t]+K[t] for next rounds
%endmacro

; #######################################################################
; BOOLEAN IsAvxSupported ()
; To run in QEMU use options: -enable-kvm -cpu Penryn,+avx,+xsave,+xsaveopt
; #######################################################################
align 8
global ASM_PFX(IsAvxSupported)
ASM_PFX(IsAvxSupported):
  ; Detect CPUID.1:ECX.XSAVE[bit 26] = 1 (CR4.OSXSAVE can be set to 1).
  ; Detect CPUID.1:ECX.AVX[bit 28] = 1 (AVX instructions supported).
  mov eax, 1          ; Feature Information
  cpuid               ; result in EAX, EBX, ECX, EDX
  and ecx, 014000000H
  cmp ecx, 014000000H ; check both XSAVE and AVX feature flags
  jne noAVX
  ; processor supports AVX instructions
  mov rax, cr4
  bts rax, 18  ; OSXSAVE: enables XGETBV and XSETBV
  mov cr4, rax

  mov ecx, 0          ; read the contents of XCR0 register
  XGETBV              ; result in EDX:EAX
  or  eax, 06H        ; enable both XMM and YMM state support
  ; XSETBV must be executed at privilege level 0 or in real-address mode.
  XSETBV
  mov rax, 1
  jmp done
noAVX:
  mov rax, 0
done:
  ret

; #######################################################################
;  void Sha512TransformAvx(sha512_state *state, const u8 *data, int blocks)
;  Purpose: Updates the SHA512 digest stored at "state" with the message
;  stored in "data".
;  The size of the message pointed to by "data" must be an integer multiple
;  of SHA512 message blocks.
;  "blocks" is the message length in SHA512 blocks
; #######################################################################
align 8
global ASM_PFX(Sha512TransformAvx)
ASM_PFX(Sha512TransformAvx):
	test msglen, msglen
	je nowork

	; Allocate Stack Space
	mov	rax, rsp
	sub rsp, frame_size
	and	rsp, ~(0x20 - 1)
	mov	[rsp + frame_RSPSAVE], rax

	; Save GPRs
  ; Registers RBX, RBP, RDI, RSI, R12, R13, R14, R15, and XMM6-XMM15 are nonvolatile,
  ; but XMM6-XMM15 are not used.
	mov     [rsp + frame_GPRSAVE], rbx
  mov     [rsp + frame_GPRSAVE + 8*1], rbp
  mov     [rsp + frame_GPRSAVE + 8*2], rdi
  mov     [rsp + frame_GPRSAVE + 8*3], rsi
	mov     [rsp + frame_GPRSAVE + 8*4], r12
	mov     [rsp + frame_GPRSAVE + 8*5], r13
	mov     [rsp + frame_GPRSAVE + 8*6], r14
	mov     [rsp + frame_GPRSAVE + 8*7], r15

updateblock:
  ; Load state variables
	mov a_64, DIGEST(0)
	mov b_64, DIGEST(1)
	mov c_64, DIGEST(2)
	mov d_64, DIGEST(3)
	mov e_64, DIGEST(4)
	mov f_64, DIGEST(5)
	mov g_64, DIGEST(6)
	mov h_64, DIGEST(7)

	%assign t  0
  %rep 80/2 + 1
  ; (80 rounds) / (2 rounds/iteration) + (1 iteration)
  ; +1 iteration because the scheduler leads hashing by 1 iteration
    %if t < 2
		  ; BSWAP 2 QWORDS
			vmovdqa  xmm1, [rel XMM_QWORD_BSWAP]
			vmovdqu  xmm0, MSG(t)
			vpshufb  xmm0, xmm0, xmm1    ; BSWAP
			vmovdqa  W_t(t), xmm0        ; Store Scheduled Pair
			vpaddq   xmm0, xmm0, K_t(t)  ; Compute W[t]+K[t]
			vmovdqa  WK_2(t), xmm0       ; Store into WK for rounds
    %elif t < 16
		  ; BSWAP 2 QWORDS ; Compute 2 Rounds
			vmovdqu  xmm0, MSG(t)
			vpshufb  xmm0, xmm0, xmm1    ; BSWAP
			SHA512_Round_Optimized t-2   ; Round t-2
			vmovdqa  W_t(t), xmm0        ; Store Scheduled Pair
			vpaddq   xmm0, xmm0, K_t(t)  ; Compute W[t]+K[t]
			SHA512_Round_Optimized t-1   ; Round t-1
			vmovdqa  WK_2(t), xmm0       ; Store W[t]+K[t] into WK
    %elif t < 79
		  ; Schedule 2 QWORDS ; Compute 2 Rounds
      ; SHA512_Round_Optimized t-2
			; SHA512_Round_Optimized t-1
      ; SHA512_2Sched t
      SHA512_Stitched t
    %else
		  ; Compute 2 Rounds
			SHA512_Round_Optimized t-2
			SHA512_Round_Optimized t-1
		%endif
		%assign t  t+2
  %endrep

  ; Update digest
	add     DIGEST(0), a_64
	add     DIGEST(1), b_64
	add     DIGEST(2), c_64
	add     DIGEST(3), d_64
	add     DIGEST(4), e_64
	add     DIGEST(5), f_64
	add     DIGEST(6), g_64
	add     DIGEST(7), h_64

  ; Advance to next message block
	add     msg, 16*8
	dec     msglen
	jnz     updateblock

  ; Restore GPRs
	mov     rbx, [rsp + frame_GPRSAVE]
  mov     rbp, [rsp + frame_GPRSAVE + 8*1]
	mov     rdi, [rsp + frame_GPRSAVE + 8*2]
	mov     rsi, [rsp + frame_GPRSAVE + 8*3]
	mov     r12, [rsp + frame_GPRSAVE + 8*4]
	mov     r13, [rsp + frame_GPRSAVE + 8*5]
	mov     r14, [rsp + frame_GPRSAVE + 8*6]
	mov     r15, [rsp + frame_GPRSAVE + 8*7]

  ; Restore Stack Pointer
	mov	rsp, [rsp + frame_RSPSAVE]

nowork:
	ret
