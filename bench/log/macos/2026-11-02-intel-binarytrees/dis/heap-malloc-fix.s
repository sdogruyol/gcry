
bin/ab-var:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

0000000100019a10 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
100019a10:     	pushq	%rbp
100019a11:     	movq	%rsp, %rbp
100019a14:     	pushq	%r15
100019a16:     	pushq	%r14
100019a18:     	pushq	%r13
100019a1a:     	pushq	%r12
100019a1c:     	pushq	%rbx
100019a1d:     	subq	$0x28, %rsp
100019a21:     	movq	%rsi, %r14
100019a24:     	movq	%rdi, %rbx
100019a27:     	cmpb	$0x1, 0x4(%rdi)
100019a2b:     	jne	0x100019a46 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x36>
100019a2d:     	cmpb	$0x1, 0x5(%rbx)
100019a31:     	je	0x100019a3f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x2f>
100019a33:     	cmpb	$0x0, 0x6(%rbx)
100019a37:     	jne	0x100019a3f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x2f>
100019a39:     	cmpb	$0x0, 0x7(%rbx)
100019a3d:     	je	0x100019a66 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x56>
100019a3f:     	leaq	0x28(%rbx), %rax
100019a43:     	incq	(%rax)
100019a46:     	movq	%rbx, %rdi
100019a49:     	movq	%r14, %rsi
100019a4c:     	xorl	%edx, %edx
100019a4e:     	movl	$0x1, %ecx
100019a53:     	addq	$0x28, %rsp
100019a57:     	popq	%rbx
100019a58:     	popq	%r12
100019a5a:     	popq	%r13
100019a5c:     	popq	%r14
100019a5e:     	popq	%r15
100019a60:     	popq	%rbp
100019a61:     	jmp	0x10001ab80 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
100019a66:     	cmpq	$0x8000, %r14           ## imm = 0x8000
100019a6d:     	jbe	0x100019a75 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x65>
100019a6f:     	leaq	0x30(%rbx), %rax
100019a73:     	jmp	0x100019a43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x33>
100019a75:     	movq	0x8(%rbx), %rax
100019a79:     	testq	%rax, %rax
100019a7c:     	je	0x100019a8c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7c>
100019a7e:     	decq	%rax
100019a81:     	movq	%gs:(,%rax,8), %r13
100019a8a:     	jmp	0x100019aa5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x95>
100019a8c:     	leaq	-0x48(%rbp), %rdi
100019a90:     	callq	0x100014c70 <_*Gcry::Heap::tls_cursor_cache>
100019a95:     	movq	-0x48(%rbp), %rax
100019a99:     	movq	0x8(%rax), %rcx
100019a9d:     	xorq	%rbx, %rcx
100019aa0:     	jne	0x100019ab1 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xa1>
100019aa2:     	movq	(%rax), %r13
100019aa5:     	testq	%r13, %r13
100019aa8:     	je	0x100019ab1 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xa1>
100019aaa:     	cmpb	$0x0, 0x9(%r13)
100019aaf:     	je	0x100019ab7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xa7>
100019ab1:     	leaq	0x38(%rbx), %rax
100019ab5:     	jmp	0x100019a43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x33>
100019ab7:     	cmpq	$0x801, %r14            ## imm = 0x801
100019abe:     	jae	0x100019add <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xcd>
100019ac0:     	leaq	0x7(%r14), %rcx
100019ac4:     	shrq	$0x3, %rcx
100019ac8:     	movl	0x294(%rbx,%rcx,4), %eax
100019acf:     	movzbl	0x190(%rbx,%rcx), %r12d
100019ad8:     	jmp	0x100019b7c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x16c>
100019add:     	movl	$0xc, %r15d
100019ae3:     	cmpq	$0x4000, %r14           ## imm = 0x4000
100019aea:     	ja	0x100019b0c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xfc>
100019aec:     	movl	$0xb, %r15d
100019af2:     	cmpq	$0x2001, %r14           ## imm = 0x2001
100019af9:     	jae	0x100019b0c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xfc>
100019afb:     	cmpq	$0x1001, %r14           ## imm = 0x1001
100019b02:     	movl	$0x9, %r15d
100019b08:     	sbbl	$-0x1, %r15d
100019b0c:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019b16:     	movq	%r14, %rdi
100019b19:     	xorq	%r12, %rdi
100019b1c:     	decq	%rdi
100019b1f:     	jo	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019b25:     	xorq	%r12, %rdi
100019b28:     	movl	%r15d, %esi
100019b2b:     	callq	0x100009050 <_*UInt64@Int#>><Int32>:UInt64>
100019b30:     	xorq	%r12, %rax
100019b33:     	incq	%rax
100019b36:     	jo	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019b3c:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019b46:     	cmpq	%rcx, %rax
100019b49:     	jge	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019b4f:     	testl	%eax, %eax
100019b51:     	js	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019b57:     	leal	-0xd(,%r15,4), %r12d
100019b5f:     	addl	%eax, %r12d
100019b62:     	jo	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019b68:     	addl	$-0x4, %r12d
100019b6c:     	jo	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019b72:     	movl	%eax, %edi
100019b74:     	movl	%r15d, %esi
100019b77:     	callq	0x10000a3c0 <_*UInt32@Int#<<<Int32>:UInt32>
100019b7c:     	movslq	%r12d, %rdx
100019b7f:     	leaq	(%rdx,%rdx,4), %rcx
100019b83:     	leaq	0x30(%r13,%rcx,8), %r10
100019b88:     	cmpq	$0x0, 0x40(%r13,%rcx,8)
100019b8e:     	jne	0x100019b9a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x18a>
100019b90:     	cmpq	$0x0, (%r10)
100019b94:     	je	0x100019e46 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x436>
100019b9a:     	movl	%eax, %eax
100019b9c:     	movq	0x10(%r13), %r15
100019ba0:     	movq	%rax, -0x40(%rbp)
100019ba4:     	addq	%rax, %r15
100019ba7:     	movq	%r15, %rsi
100019baa:     	subq	0x18(%r13), %rsi
100019bae:     	addq	0x10(%rbx), %rsi
100019bb2:     	movq	0x18(%rbx), %rdi
100019bb6:     	cmpq	%rdi, %rsi
100019bb9:     	jb	0x100019bdd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1cd>
100019bbb:     	movq	%r10, -0x38(%rbp)
100019bbf:     	movq	%rdx, -0x30(%rbp)
100019bc3:     	callq	0x100019ea0 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019bc8:     	movq	-0x30(%rbp), %rdx
100019bcc:     	movq	-0x38(%rbp), %r10
100019bd0:     	testb	$0x1, %al
100019bd2:     	je	0x100019bdd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1cd>
100019bd4:     	leaq	0x48(%rbx), %rax
100019bd8:     	jmp	0x100019a43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x33>
100019bdd:     	movq	$0x8, 0x20(%r10)
100019be5:     	movq	0x10(%r10), %rax
100019be9:     	testq	%rax, %rax
100019bec:     	jne	0x100019c15 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x205>
100019bee:     	movq	%rbx, %rdi
100019bf1:     	movq	%r10, %rsi
100019bf4:     	movq	%rdx, -0x30(%rbp)
100019bf8:     	movl	%r12d, %edx
100019bfb:     	movq	%r10, -0x38(%rbp)
100019bff:     	callq	0x100019ec0 <_*Gcry::Heap#cursor_advance_word<Pointer(Gcry::CursorSlot), Int32>:UInt64>
100019c04:     	movq	-0x30(%rbp), %rdx
100019c08:     	movq	-0x38(%rbp), %r10
100019c0c:     	testq	%rax, %rax
100019c0f:     	je	0x100019e6c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45c>
100019c15:     	cmpl	$0x28, %r12d
100019c19:     	jae	0x100019e82 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x472>
100019c1f:     	movq	0x18(%r10), %rcx
100019c23:     	testq	%rax, %rax
100019c26:     	je	0x100019c2e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x21e>
100019c28:     	bsfq	%rax, %r12
100019c2c:     	jmp	0x100019c34 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x224>
100019c2e:     	movl	$0x40, %r12d
100019c34:     	imulq	0x50(%rbx,%rdx,8), %r12
100019c3a:     	addq	%rcx, %r12
100019c3d:     	movq	%r12, 0x20(%r10)
100019c41:     	leaq	-0x1(%rax), %rcx
100019c45:     	andq	%rax, %rcx
100019c48:     	movq	%rcx, 0x10(%r10)
100019c4c:     	movq	%r15, 0x10(%r13)
100019c50:     	incq	0x20(%r13)
100019c54:     	movq	0x20(%rbx), %rax
100019c58:     	testq	%rax, %rax
100019c5b:     	je	0x100019c62 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x252>
100019c5d:     	prefetcht0	(%rax,%r12)
100019c62:     	cmpb	$0x1, 0x6(%rbx)
100019c66:     	je	0x100019c72 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x262>
100019c68:     	cmpb	$0x0, 0x5(%rbx)
100019c6c:     	je	0x100019d98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x388>
100019c72:     	cmpb	$0x0, 0x3628(%rbx)
100019c79:     	je	0x100019d2f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x31f>
100019c7f:     	movq	%r10, %r15
100019c82:     	movq	%rbx, %rdi
100019c85:     	movq	%r12, %rsi
100019c88:     	callq	0x100010b80 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
100019c8d:     	testl	%eax, %eax
100019c8f:     	je	0x100019d63 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019c95:     	cmpb	$0x1, 0x2048(%rbx)
100019c9c:     	jne	0x100019d63 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019ca2:     	movq	%rdx, %rsi
100019ca5:     	movl	0x10(%rdx), %ecx
100019ca8:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
100019cad:     	cmpq	%rax, %rcx
100019cb0:     	je	0x100019d63 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019cb6:     	testb	$0x1, 0x14(%rsi)
100019cba:     	jne	0x100019d63 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019cc0:     	testl	%ecx, %ecx
100019cc2:     	js	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019cc8:     	movl	0x18(%rsi), %edx
100019ccb:     	addq	%rsi, %rdx
100019cce:     	movq	%r12, %rax
100019cd1:     	subq	%rdx, %rax
100019cd4:     	jb	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019cda:     	cmpl	$0x27, %ecx
100019cdd:     	ja	0x100019e82 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x472>
100019ce3:     	mulq	0x2798(%rbx,%rcx,8)
100019ceb:     	jo	0x100019e7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46d>
100019cf1:     	movl	0x1c(%rsi), %edx
100019cf4:     	testq	%rdx, %rdx
100019cf7:     	movq	%r15, %r10
100019cfa:     	je	0x100019d98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x388>
100019d00:     	leaq	(%rsi,%rdx,8), %r8
100019d04:     	movq	%rax, %rcx
100019d07:     	shrq	$0x28, %rcx
100019d0b:     	shrq	$0x2e, %rax
100019d0f:     	movl	$0x1, %r9d
100019d15:     	shlq	%cl, %r9
100019d18:     	movq	0x20(%r8,%rax,8), %rdi
100019d1d:     	btq	%rcx, %rdi
100019d21:     	jb	0x100019d98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x388>
100019d23:     	leaq	0x20(%rsi,%rdx,8), %rcx
100019d28:     	lock
100019d29:     	orq	%r9, (%rcx,%rax,8)
100019d2d:     	jmp	0x100019d98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x388>
100019d2f:     	movzbl	0x20c2d6(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019d36:     	movl	%eax, %ecx
100019d38:     	movl	0x4(%r12), %eax
100019d3d:     	movl	%eax, %edx
100019d3f:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
100019d45:     	movzbl	%cl, %esi
100019d48:     	shll	$0x8, %esi
100019d4b:     	orl	%edx, %esi
100019d4d:     	lock
100019d4e:     	cmpxchgl	%esi, 0x4(%r12)
100019d54:     	movzbl	0x20c2b1(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019d5b:     	jne	0x100019d36 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x326>
100019d5d:     	cmpb	%al, %cl
100019d5f:     	jne	0x100019d36 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x326>
100019d61:     	jmp	0x100019d98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x388>
100019d63:     	movzbl	0x20c2a2(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019d6a:     	movq	%r15, %r10
100019d6d:     	movl	%eax, %ecx
100019d6f:     	movl	0x4(%r12), %eax
100019d74:     	movl	%eax, %edx
100019d76:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
100019d7c:     	movzbl	%cl, %esi
100019d7f:     	shll	$0x8, %esi
100019d82:     	orl	%edx, %esi
100019d84:     	lock
100019d85:     	cmpxchgl	%esi, 0x4(%r12)
100019d8b:     	movzbl	0x20c27a(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019d92:     	jne	0x100019d6d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x35d>
100019d94:     	cmpb	%al, %cl
100019d96:     	jne	0x100019d6d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x35d>
100019d98:     	movq	-0x40(%rbp), %rsi
100019d9c:     	leaq	-0x10(%rsi), %rax
100019da0:     	rolq	$0x3c, %rax
100019da4:     	cmpq	$0x3, %rax
100019da8:     	ja	0x100019e4f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x43f>
100019dae:     	leaq	0xdb(%rip), %rcx        ## 0x100019e90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x480>
100019db5:     	movslq	(%rcx,%rax,4), %rax
100019db9:     	addq	%rcx, %rax
100019dbc:     	jmpq	*%rax
100019dbe:     	movq	$0x0, 0x38(%r12)
100019dc7:     	movq	$0x0, 0x30(%r12)
100019dd0:     	movq	$0x0, 0x28(%r12)
100019dd9:     	movq	$0x0, 0x20(%r12)
100019de2:     	movq	$0x0, 0x18(%r12)
100019deb:     	movq	$0x0, 0x10(%r12)
100019df4:     	movq	$0x0, 0x8(%r12)
100019dfd:     	movq	$0x0, (%r12)
100019e05:     	movq	$0x0, 0x20(%r10)
100019e0d:     	cmpb	$0x1, 0x20c45c(%rip)    ## 0x100226270 <_Gcry::Invariant::enabled>
100019e14:     	jne	0x100019e1e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x40e>
100019e16:     	movq	%rbx, %rdi
100019e19:     	callq	0x100016df0 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
100019e1e:     	cmpb	$0x1, 0x20c42f(%rip)    ## 0x100226254 <_Gcry::Trace::enabled>
100019e25:     	jne	0x100019e34 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x424>
100019e27:     	movq	%r12, %rdi
100019e2a:     	movq	%r14, %rsi
100019e2d:     	xorl	%edx, %edx
100019e2f:     	callq	0x10001a330 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
100019e34:     	movq	%r12, %rax
100019e37:     	addq	$0x28, %rsp
100019e3b:     	popq	%rbx
100019e3c:     	popq	%r12
100019e3e:     	popq	%r13
100019e40:     	popq	%r14
100019e42:     	popq	%r15
100019e44:     	popq	%rbp
100019e45:     	retq
100019e46:     	leaq	0x40(%rbx), %rax
100019e4a:     	jmp	0x100019a43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x33>
100019e4f:     	movq	%r12, %rdi
100019e52:     	movq	%r10, %r15
100019e55:     	callq	0x1001c5b0c <_write+0x1001c5b0c>
100019e5a:     	movq	$0x0, 0x20(%r15)
100019e62:     	testq	%r12, %r12
100019e65:     	jne	0x100019e0d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3fd>
100019e67:     	jmp	0x100019a46 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x36>
100019e6c:     	movq	$0x0, 0x20(%r10)
100019e74:     	leaq	0x40(%rbx), %rax
100019e78:     	jmp	0x100019a43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x33>
100019e7d:     	callq	0x100005a60 <___crystal_raise_overflow>
100019e82:     	callq	0x100009f90 <_*IndexError::new:IndexError>
100019e87:     	movq	%rax, %rdi
100019e8a:     	callq	0x100009fe0 <_*raise<IndexError>:NoReturn>
100019e8f:     	nop
100019e90:     	<unknown>
100019e93:     	callq	*-0x1(%rdx)
100019e96:     	<unknown>
100019e98:     	<unknown>
100019e9b:     	ljmpl	*(%rsi)
100019e9d:     	<unknown>
100019e9f:     	callq	*0x48(%rbp)
