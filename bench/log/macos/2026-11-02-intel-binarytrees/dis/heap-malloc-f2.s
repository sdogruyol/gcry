
bin/ab-pt_f2:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

00000001000198f0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
1000198f0:     	pushq	%rbp
1000198f1:     	movq	%rsp, %rbp
1000198f4:     	pushq	%r15
1000198f6:     	pushq	%r14
1000198f8:     	pushq	%r13
1000198fa:     	pushq	%r12
1000198fc:     	pushq	%rbx
1000198fd:     	subq	$0x28, %rsp
100019901:     	movq	%rsi, %r14
100019904:     	movq	%rdi, %rbx
100019907:     	cmpb	$0x1, 0x150bc(%rdi)
10001990e:     	jne	0x100019935 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019910:     	cmpb	$0x1, 0x15230(%rbx)
100019917:     	je	0x10001992b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b>
100019919:     	cmpb	$0x0, 0x15240(%rbx)
100019920:     	jne	0x10001992b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b>
100019922:     	cmpb	$0x0, 0x152f3(%rbx)
100019929:     	je	0x100019955 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x65>
10001992b:     	leaq	0x280(%rbx), %rax
100019932:     	incq	(%rax)
100019935:     	movq	%rbx, %rdi
100019938:     	movq	%r14, %rsi
10001993b:     	xorl	%edx, %edx
10001993d:     	movl	$0x1, %ecx
100019942:     	addq	$0x28, %rsp
100019946:     	popq	%rbx
100019947:     	popq	%r12
100019949:     	popq	%r13
10001994b:     	popq	%r14
10001994d:     	popq	%r15
10001994f:     	popq	%rbp
100019950:     	jmp	0x10001aab0 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
100019955:     	cmpq	$0x8000, %r14           ## imm = 0x8000
10001995c:     	jbe	0x100019967 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x77>
10001995e:     	leaq	0x288(%rbx), %rax
100019965:     	jmp	0x100019932 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019967:     	movq	0x14f58(%rbx), %rax
10001996e:     	testq	%rax, %rax
100019971:     	je	0x100019981 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x91>
100019973:     	decq	%rax
100019976:     	movq	%gs:(,%rax,8), %r13
10001997f:     	jmp	0x10001999a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xaa>
100019981:     	leaq	-0x48(%rbp), %rdi
100019985:     	callq	0x100014b40 <_*Gcry::Heap::tls_cursor_cache>
10001998a:     	movq	-0x48(%rbp), %rax
10001998e:     	movq	0x8(%rax), %rcx
100019992:     	xorq	%rbx, %rcx
100019995:     	jne	0x1000199a6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
100019997:     	movq	(%rax), %r13
10001999a:     	testq	%r13, %r13
10001999d:     	je	0x1000199a6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
10001999f:     	cmpb	$0x0, 0x9(%r13)
1000199a4:     	je	0x1000199af <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xbf>
1000199a6:     	leaq	0x290(%rbx), %rax
1000199ad:     	jmp	0x100019932 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
1000199af:     	cmpq	$0x801, %r14            ## imm = 0x801
1000199b6:     	jae	0x1000199d5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xe5>
1000199b8:     	leaq	0x7(%r14), %rcx
1000199bc:     	shrq	$0x3, %rcx
1000199c0:     	movl	0x32ac(%rbx,%rcx,4), %eax
1000199c7:     	movzbl	0x31a8(%rbx,%rcx), %r12d
1000199d0:     	jmp	0x100019a74 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x184>
1000199d5:     	movl	$0xc, %r15d
1000199db:     	cmpq	$0x4000, %r14           ## imm = 0x4000
1000199e2:     	ja	0x100019a04 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x114>
1000199e4:     	movl	$0xb, %r15d
1000199ea:     	cmpq	$0x2001, %r14           ## imm = 0x2001
1000199f1:     	jae	0x100019a04 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x114>
1000199f3:     	cmpq	$0x1001, %r14           ## imm = 0x1001
1000199fa:     	movl	$0x9, %r15d
100019a00:     	sbbl	$-0x1, %r15d
100019a04:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019a0e:     	movq	%r14, %rdi
100019a11:     	xorq	%r12, %rdi
100019a14:     	decq	%rdi
100019a17:     	jo	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a1d:     	xorq	%r12, %rdi
100019a20:     	movl	%r15d, %esi
100019a23:     	callq	0x100008f50 <_*UInt64@Int#>><Int32>:UInt64>
100019a28:     	xorq	%r12, %rax
100019a2b:     	incq	%rax
100019a2e:     	jo	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a34:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019a3e:     	cmpq	%rcx, %rax
100019a41:     	jge	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a47:     	testl	%eax, %eax
100019a49:     	js	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a4f:     	leal	-0xd(,%r15,4), %r12d
100019a57:     	addl	%eax, %r12d
100019a5a:     	jo	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a60:     	addl	$-0x4, %r12d
100019a64:     	jo	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a6a:     	movl	%eax, %edi
100019a6c:     	movl	%r15d, %esi
100019a6f:     	callq	0x10000a2a0 <_*UInt32@Int#<<<Int32>:UInt32>
100019a74:     	movslq	%r12d, %rdx
100019a77:     	leaq	(%rdx,%rdx,4), %rcx
100019a7b:     	leaq	0x30(%r13,%rcx,8), %r10
100019a80:     	cmpq	$0x0, 0x40(%r13,%rcx,8)
100019a86:     	jne	0x100019a92 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1a2>
100019a88:     	cmpq	$0x0, (%r10)
100019a8c:     	je	0x100019d53 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x463>
100019a92:     	movl	%eax, %eax
100019a94:     	movq	0x10(%r13), %r15
100019a98:     	movq	%rax, -0x40(%rbp)
100019a9c:     	addq	%rax, %r15
100019a9f:     	movq	%r15, %rsi
100019aa2:     	subq	0x18(%r13), %rsi
100019aa6:     	addq	0x14fa0(%rbx), %rsi
100019aad:     	movq	0x3860(%rbx), %rdi
100019ab4:     	cmpq	%rdi, %rsi
100019ab7:     	jb	0x100019ade <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ee>
100019ab9:     	movq	%r10, -0x38(%rbp)
100019abd:     	movq	%rdx, -0x30(%rbp)
100019ac1:     	callq	0x100019dc0 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019ac6:     	movq	-0x30(%rbp), %rdx
100019aca:     	movq	-0x38(%rbp), %r10
100019ace:     	testb	$0x1, %al
100019ad0:     	je	0x100019ade <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ee>
100019ad2:     	leaq	0x2a0(%rbx), %rax
100019ad9:     	jmp	0x100019932 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019ade:     	movq	$0x8, 0x20(%r10)
100019ae6:     	movq	0x10(%r10), %rax
100019aea:     	testq	%rax, %rax
100019aed:     	jne	0x100019b16 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x226>
100019aef:     	movq	%rbx, %rdi
100019af2:     	movq	%r10, %rsi
100019af5:     	movq	%rdx, -0x30(%rbp)
100019af9:     	movl	%r12d, %edx
100019afc:     	movq	%r10, -0x38(%rbp)
100019b00:     	callq	0x100019de0 <_*Gcry::Heap#cursor_advance_word<Pointer(Gcry::CursorSlot), Int32>:UInt64>
100019b05:     	movq	-0x30(%rbp), %rdx
100019b09:     	movq	-0x38(%rbp), %r10
100019b0d:     	testq	%rax, %rax
100019b10:     	je	0x100019d7c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48c>
100019b16:     	cmpl	$0x28, %r12d
100019b1a:     	jae	0x100019d95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a5>
100019b20:     	movq	0x18(%r10), %rcx
100019b24:     	testq	%rax, %rax
100019b27:     	je	0x100019b2f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x23f>
100019b29:     	bsfq	%rax, %r12
100019b2d:     	jmp	0x100019b35 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x245>
100019b2f:     	movl	$0x40, %r12d
100019b35:     	imulq	0x2140(%rbx,%rdx,8), %r12
100019b3e:     	addq	%rcx, %r12
100019b41:     	movq	%r12, 0x20(%r10)
100019b45:     	leaq	-0x1(%rax), %rcx
100019b49:     	andq	%rax, %rcx
100019b4c:     	movq	%rcx, 0x10(%r10)
100019b50:     	movq	%r15, 0x10(%r13)
100019b54:     	incq	0x20(%r13)
100019b58:     	movq	0x1a00(%rbx), %rax
100019b5f:     	testq	%rax, %rax
100019b62:     	je	0x100019b69 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x279>
100019b64:     	prefetcht0	(%rax,%r12)
100019b69:     	cmpb	$0x1, 0x15240(%rbx)
100019b70:     	je	0x100019b7f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x28f>
100019b72:     	cmpb	$0x0, 0x15230(%rbx)
100019b79:     	je	0x100019ca5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019b7f:     	cmpb	$0x0, 0x3110(%rbx)
100019b86:     	je	0x100019c3c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x34c>
100019b8c:     	movq	%r10, %r15
100019b8f:     	movq	%rbx, %rdi
100019b92:     	movq	%r12, %rsi
100019b95:     	callq	0x100010a80 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
100019b9a:     	testl	%eax, %eax
100019b9c:     	je	0x100019c70 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019ba2:     	cmpb	$0x1, 0x19e0(%rbx)
100019ba9:     	jne	0x100019c70 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019baf:     	movq	%rdx, %rsi
100019bb2:     	movl	0x10(%rdx), %ecx
100019bb5:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
100019bba:     	cmpq	%rax, %rcx
100019bbd:     	je	0x100019c70 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019bc3:     	testb	$0x1, 0x14(%rsi)
100019bc7:     	jne	0x100019c70 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019bcd:     	testl	%ecx, %ecx
100019bcf:     	js	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019bd5:     	movl	0x18(%rsi), %edx
100019bd8:     	addq	%rsi, %rdx
100019bdb:     	movq	%r12, %rax
100019bde:     	subq	%rdx, %rax
100019be1:     	jb	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019be7:     	cmpl	$0x27, %ecx
100019bea:     	ja	0x100019d95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a5>
100019bf0:     	mulq	0x2280(%rbx,%rcx,8)
100019bf8:     	jo	0x100019d90 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019bfe:     	movl	0x1c(%rsi), %edx
100019c01:     	testq	%rdx, %rdx
100019c04:     	movq	%r15, %r10
100019c07:     	je	0x100019ca5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c0d:     	leaq	(%rsi,%rdx,8), %r8
100019c11:     	movq	%rax, %rcx
100019c14:     	shrq	$0x28, %rcx
100019c18:     	shrq	$0x2e, %rax
100019c1c:     	movl	$0x1, %r9d
100019c22:     	shlq	%cl, %r9
100019c25:     	movq	0x20(%r8,%rax,8), %rdi
100019c2a:     	btq	%rcx, %rdi
100019c2e:     	jb	0x100019ca5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c30:     	leaq	0x20(%rsi,%rdx,8), %rcx
100019c35:     	lock
100019c36:     	orq	%r9, (%rcx,%rax,8)
100019c3a:     	jmp	0x100019ca5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c3c:     	movzbl	0x20c3c9(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c43:     	movl	%eax, %ecx
100019c45:     	movl	0x4(%r12), %eax
100019c4a:     	movl	%eax, %edx
100019c4c:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
100019c52:     	movzbl	%cl, %esi
100019c55:     	shll	$0x8, %esi
100019c58:     	orl	%edx, %esi
100019c5a:     	lock
100019c5b:     	cmpxchgl	%esi, 0x4(%r12)
100019c61:     	movzbl	0x20c3a4(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c68:     	jne	0x100019c43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019c6a:     	cmpb	%al, %cl
100019c6c:     	jne	0x100019c43 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019c6e:     	jmp	0x100019ca5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c70:     	movzbl	0x20c395(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c77:     	movq	%r15, %r10
100019c7a:     	movl	%eax, %ecx
100019c7c:     	movl	0x4(%r12), %eax
100019c81:     	movl	%eax, %edx
100019c83:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
100019c89:     	movzbl	%cl, %esi
100019c8c:     	shll	$0x8, %esi
100019c8f:     	orl	%edx, %esi
100019c91:     	lock
100019c92:     	cmpxchgl	%esi, 0x4(%r12)
100019c98:     	movzbl	0x20c36d(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c9f:     	jne	0x100019c7a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x38a>
100019ca1:     	cmpb	%al, %cl
100019ca3:     	jne	0x100019c7a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x38a>
100019ca5:     	movq	-0x40(%rbp), %rsi
100019ca9:     	leaq	-0x10(%rsi), %rax
100019cad:     	rolq	$0x3c, %rax
100019cb1:     	cmpq	$0x3, %rax
100019cb5:     	ja	0x100019d5f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46f>
100019cbb:     	leaq	0xe2(%rip), %rcx        ## 0x100019da4 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4b4>
100019cc2:     	movslq	(%rcx,%rax,4), %rax
100019cc6:     	addq	%rcx, %rax
100019cc9:     	jmpq	*%rax
100019ccb:     	movq	$0x0, 0x38(%r12)
100019cd4:     	movq	$0x0, 0x30(%r12)
100019cdd:     	movq	$0x0, 0x28(%r12)
100019ce6:     	movq	$0x0, 0x20(%r12)
100019cef:     	movq	$0x0, 0x18(%r12)
100019cf8:     	movq	$0x0, 0x10(%r12)
100019d01:     	movq	$0x0, 0x8(%r12)
100019d0a:     	movq	$0x0, (%r12)
100019d12:     	movq	$0x0, 0x20(%r10)
100019d1a:     	cmpb	$0x1, 0x20c54f(%rip)    ## 0x100226270 <_Gcry::Invariant::enabled>
100019d21:     	jne	0x100019d2b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x43b>
100019d23:     	movq	%rbx, %rdi
100019d26:     	callq	0x100016cc0 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
100019d2b:     	cmpb	$0x1, 0x20c522(%rip)    ## 0x100226254 <_Gcry::Trace::enabled>
100019d32:     	jne	0x100019d41 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x451>
100019d34:     	movq	%r12, %rdi
100019d37:     	movq	%r14, %rsi
100019d3a:     	xorl	%edx, %edx
100019d3c:     	callq	0x10001a260 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
100019d41:     	movq	%r12, %rax
100019d44:     	addq	$0x28, %rsp
100019d48:     	popq	%rbx
100019d49:     	popq	%r12
100019d4b:     	popq	%r13
100019d4d:     	popq	%r14
100019d4f:     	popq	%r15
100019d51:     	popq	%rbp
100019d52:     	retq
100019d53:     	leaq	0x298(%rbx), %rax
100019d5a:     	jmp	0x100019932 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019d5f:     	movq	%r12, %rdi
100019d62:     	movq	%r10, %r15
100019d65:     	callq	0x1001c559c <_write+0x1001c559c>
100019d6a:     	movq	$0x0, 0x20(%r15)
100019d72:     	testq	%r12, %r12
100019d75:     	jne	0x100019d1a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42a>
100019d77:     	jmp	0x100019935 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019d7c:     	movq	$0x0, 0x20(%r10)
100019d84:     	leaq	0x298(%rbx), %rax
100019d8b:     	jmp	0x100019932 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019d90:     	callq	0x100005a60 <___crystal_raise_overflow>
100019d95:     	callq	0x100009e70 <_*IndexError::new:IndexError>
100019d9a:     	movq	%rax, %rdi
100019d9d:     	callq	0x100009ec0 <_*raise<IndexError>:NoReturn>
100019da2:     	nop
100019da4:     	popq	%rbp
100019da5:     	<unknown>
100019da7:     	decl	-0x1(%rbx)
100019daa:     	<unknown>
100019dac:     	cmpl	%edi, %edi
100019dae:     	<unknown>
100019db0:     	<unknown>
100019db1:     	<unknown>
100019db3:     	jmpq	*0x2e(%rsi)
100019db6:     	nopl	(%rax,%rax)
100019dbe:     	nop
