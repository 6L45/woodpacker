cat woodp.s 
section .bss
	filename resq 1
	argv1_len resq 1

section .text
	global _start

open_file_and_map:
	; Prologue
	push rbx
	push rbp
	mov rbp, rsp
	; ------------------------------

	sub rsp, [argv1_len]		; Réserver argv1_len octets pour la taille de filename
	
	mov rdx, [argv1_len]		; rdx = strlen(filename) -> argv1_len
	lea rsi, [filename]		; rsi = char *filename (+ **env)
	mov rsi, [rsi]
	lea rdi, [rsp]			; rdi = rsp (haut de la stack)

	; copy filename dans l'espace libérée dans la stack a la taille de filename
	; parce dans la mémoire pas de \0 a la fin du filename
	argv1_strcpy:
		mov al, byte [rsi]	; while (argv1_len) {
		mov [rdi], al		; 	stack[i] = filename[i];
		inc rsi			; 	i++
		inc rdi			; 	argv_len--
		dec rdx			; }
		cmp rdx, 0		;
		jnz argv1_strcpy	;
	mov byte [rdi], 0		; stack[i] = 0

	; sys_open
	mov rax, 2			;	sys_open
	mov rdi, rsp			;	filename
	mov rsi, 2			;	O_RDWR
	syscall				; rax = open(filename, O_RDWR)

	cmp rax, 0			; if open() < 0
	jl outopen			; goto outopen

	push rax

	;sys_lseek
	mov rdi, rax			;	rdi = fd
	mov rax, 8			;	sys_lseek
	mov rsi, 0			;	offset = 0
	mov rdx, 2			;	origin = SEEK_end
	syscall				; lseek(fd, 0, SEEK_END)

	mov r13, rax

	; sys_mmap
	mov rsi, r13			;	size (return from lseek)
	mov rax, 9			;	sys_mmap
	xor rdi, rdi			;	0
	mov rdx, 0x3			;	PROT_READ | PROT_WRITE
	mov r10, 0x02			;	MAP_PRIVATE
	pop r8				;	r8 = fd
	push r8
	xor r9, r9			;	r9 = 0
	syscall				; mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0)
	test rax, rax
	js close_and_go

	mov r12, rax

	; sys_close
	pop rdi
	mov rax, 3
	syscall				; close(rax);

	; ------------------------------
	add rsp, [argv1_len]		; Libérer l'espace réservé variable locales 4 stack alignement

	; Épilogue
	pop rbp
	pop rbx
	ret ; return r12, r13 (char *map / size)	

	close_and_go:
	; sys_close
	pop rdi
	mov rax, 3
	syscall				; close(rax);
	jmp out2


check_elf64_header:
	; Vérifier les premiers 4 octets : 0x7f 'E' 'L' 'F'
	mov al, byte [rdi]
	cmp al, 0x7f
	jne outnotelf

	mov al, byte [rdi + 1]
	cmp al, 0x45			; E
	jne outnotelf

	mov al, byte [rdi + 2]
	cmp al, 0x4c			; L
	jne outnotelf

	mov al, byte [rdi + 3]
	cmp al, 0x46			; F
	jne outnotelf

	; Vérifier le champ de la machine (octet 4) pour ELF64
	mov al, byte [rdi + 4]
	cmp al, 0x02
	jne outnotelf

	; Vérifier la version (octet 5), doit être 1
	mov al, byte [rdi + 5]
	cmp al, 0x01
	jne outnotelf

	ret


find_note_section:
	; Prologue
	push rbx
	push rbp
	mov rbp, rsp
	; ------------------------------

	; RDI pointe vers le début du ELF Header

	mov eax, dword [rdi + 0x20]	; Start of program headers
	movzx rbx, word [rdi + 0x36]	; Size of program headers
	movzx rcx, word [rdi + 0x38]	; Number of program headers

	push rsi			; keep file size (just in case)

	mov rsi, rdi			; ptr on file
	add rsi, rax			; ptr += rax
	loop_header:
		mov edx, dword [rsi]
		cmp edx, 0x4		; Elf64_Phdr.p_type == PT_NOTE
		je eol_lheader

		add rsi, rbx
		dec rcx
		test rcx, rcx
		jz out1
		jmp loop_header
	eol_lheader:


	mov eax, dword [rdi + 0x28]	; Start of section headers
	movzx rbx, word [rdi + 0x3A]	; Size of section headers
	movzx rcx, word [rdi + 0x3C]	; Number of section headers

	mov rsi, rdi
	add rsi, rax
	loop_section:
		mov r8d, dword [rsi + 0x4]
		cmp r8d, 0x7
		je hit_lsection

		cmp r8d, 0x3
		je shrtab_section

		add rsi, rbx
		dec rcx
		test rcx, rcx
		jz eof_find_note
		jmp loop_section

	hit_lsection:
		mov r13d, dword [rsi]
		push r13

		add rsi, rbx
		dec rcx
		test rcx, rcx
		jz eof_find_note
		jmp loop_section

	shrtab_section:
		mov r15, qword [rsi + 0x18]
		mov r14, rdi
		add r14, r15

		add rsi, rbx
		dec rcx
		test rcx, rcx
		jz eof_find_note
		jmp loop_section

	eof_find_note:
	; ------------------------------
	pop rbp
	pop rbx
	ret ; return r12, r13 (char *map / size)	


; MAIN
_start:
	mov rax, [rsp]			; charge argc dans rax
	cmp rax, 2
	jne out1			; si argc != 2 -> exit(1)

	mov r15, [rsp + 16]		; gcharge dans r15 char **argv (start @ + 16)
	mov [filename], r15		; filename = r15

	lea r14, [rsp + 32]		; adresse de char **env (qui juste apres argv[1])
	mov r14, [r14]			; r14 = *r14
	sub r14, r15
	mov [argv1_len], r14		; argv1_len = diff addr(char **env) - addr(argv[1])

	call open_file_and_map		; r12 = map && r13 = size

	mov rdi, r12			; map
	mov rsi, r13			; size
	call check_elf64_header
	call find_note_section

	; TODO find NOTES .notes header
	; TODO add payload in .notes
	; TODO modify NOTES .notes with allignement on added code
	; TODO open write en execution
	; TODO dump modified file
	; TODO close

; EXITS
out:
	mov rax, 60
	mov rdi, 0
	syscall

out1:
	mov rax, 60
	mov rdi, 1
	syscall

out2:
	mov rax, 60
	mov rdi, 2
	syscall

outnotelf:
	mov rax, 60
	mov rdi, 3
	syscall

outopen:
	mov rdi, rax
	mov rax, 60
	syscall
