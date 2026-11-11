
bin/ab-pt_f24:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

0000000100019900 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
100019900:     	pushq	%rbp
100019901:     	movq	%rsp, %rbp
100019904:     	pushq	%r15
100019906:     	pushq	%r14
100019908:     	pushq	%r13
10001990a:     	pushq	%r12
10001990c:     	pushq	%rbx
10001990d:     	subq	$0x28, %rsp
100019911:     	movq	%rsi, %r14
100019914:     	movq	%rdi, %rbx
100019917:     	cmpb	$0x1, 0x1509c(%rdi)
10001991e:     	jne	0x100019945 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019920:     	cmpb	$0x1, 0x15210(%rbx)
100019927:     	je	0x10001993b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b>
100019929:     	cmpb	$0x0, 0x15220(%rbx)
100019930:     	jne	0x10001993b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b>
100019932:     	cmpb	$0x0, 0x152d3(%rbx)
100019939:     	je	0x100019965 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x65>
10001993b:     	leaq	0x280(%rbx), %rax
100019942:     	incq	(%rax)
100019945:     	movq	%rbx, %rdi
100019948:     	movq	%r14, %rsi
10001994b:     	xorl	%edx, %edx
10001994d:     	movl	$0x1, %ecx
100019952:     	addq	$0x28, %rsp
100019956:     	popq	%rbx
100019957:     	popq	%r12
100019959:     	popq	%r13
10001995b:     	popq	%r14
10001995d:     	popq	%r15
10001995f:     	popq	%rbp
100019960:     	jmp	0x10001aac0 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
100019965:     	cmpq	$0x8000, %r14           ## imm = 0x8000
10001996c:     	jbe	0x100019977 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x77>
10001996e:     	leaq	0x288(%rbx), %rax
100019975:     	jmp	0x100019942 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019977:     	movq	0x14f38(%rbx), %rax
10001997e:     	testq	%rax, %rax
100019981:     	je	0x100019991 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x91>
100019983:     	decq	%rax
100019986:     	movq	%gs:(,%rax,8), %r13
10001998f:     	jmp	0x1000199aa <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xaa>
100019991:     	leaq	-0x48(%rbp), %rdi
100019995:     	callq	0x100014b50 <_*Gcry::Heap::tls_cursor_cache>
10001999a:     	movq	-0x48(%rbp), %rax
10001999e:     	movq	0x8(%rax), %rcx
1000199a2:     	xorq	%rbx, %rcx
1000199a5:     	jne	0x1000199b6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
1000199a7:     	movq	(%rax), %r13
1000199aa:     	testq	%r13, %r13
1000199ad:     	je	0x1000199b6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
1000199af:     	cmpb	$0x0, 0x9(%r13)
1000199b4:     	je	0x1000199bf <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xbf>
1000199b6:     	leaq	0x290(%rbx), %rax
1000199bd:     	jmp	0x100019942 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
1000199bf:     	cmpq	$0x801, %r14            ## imm = 0x801
1000199c6:     	jae	0x1000199e5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xe5>
1000199c8:     	leaq	0x7(%r14), %rcx
1000199cc:     	shrq	$0x3, %rcx
1000199d0:     	movl	0x328c(%rbx,%rcx,4), %eax
1000199d7:     	movzbl	0x3188(%rbx,%rcx), %r12d
1000199e0:     	jmp	0x100019a84 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x184>
1000199e5:     	movl	$0xc, %r15d
1000199eb:     	cmpq	$0x4000, %r14           ## imm = 0x4000
1000199f2:     	ja	0x100019a14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x114>
1000199f4:     	movl	$0xb, %r15d
1000199fa:     	cmpq	$0x2001, %r14           ## imm = 0x2001
100019a01:     	jae	0x100019a14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x114>
100019a03:     	cmpq	$0x1001, %r14           ## imm = 0x1001
100019a0a:     	movl	$0x9, %r15d
100019a10:     	sbbl	$-0x1, %r15d
100019a14:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019a1e:     	movq	%r14, %rdi
100019a21:     	xorq	%r12, %rdi
100019a24:     	decq	%rdi
100019a27:     	jo	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a2d:     	xorq	%r12, %rdi
100019a30:     	movl	%r15d, %esi
100019a33:     	callq	0x100008f60 <_*UInt64@Int#>><Int32>:UInt64>
100019a38:     	xorq	%r12, %rax
100019a3b:     	incq	%rax
100019a3e:     	jo	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a44:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019a4e:     	cmpq	%rcx, %rax
100019a51:     	jge	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a57:     	testl	%eax, %eax
100019a59:     	js	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a5f:     	leal	-0xd(,%r15,4), %r12d
100019a67:     	addl	%eax, %r12d
100019a6a:     	jo	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a70:     	addl	$-0x4, %r12d
100019a74:     	jo	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019a7a:     	movl	%eax, %edi
100019a7c:     	movl	%r15d, %esi
100019a7f:     	callq	0x10000a2b0 <_*UInt32@Int#<<<Int32>:UInt32>
100019a84:     	movslq	%r12d, %rdx
100019a87:     	leaq	(%rdx,%rdx,4), %rcx
100019a8b:     	leaq	0x30(%r13,%rcx,8), %r10
100019a90:     	cmpq	$0x0, 0x40(%r13,%rcx,8)
100019a96:     	jne	0x100019aa2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1a2>
100019a98:     	cmpq	$0x0, (%r10)
100019a9c:     	je	0x100019d63 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x463>
100019aa2:     	movl	%eax, %eax
100019aa4:     	movq	0x10(%r13), %r15
100019aa8:     	movq	%rax, -0x40(%rbp)
100019aac:     	addq	%rax, %r15
100019aaf:     	movq	%r15, %rsi
100019ab2:     	subq	0x18(%r13), %rsi
100019ab6:     	addq	0x14f80(%rbx), %rsi
100019abd:     	movq	0x3840(%rbx), %rdi
100019ac4:     	cmpq	%rdi, %rsi
100019ac7:     	jb	0x100019aee <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ee>
100019ac9:     	movq	%r10, -0x38(%rbp)
100019acd:     	movq	%rdx, -0x30(%rbp)
100019ad1:     	callq	0x100019dd0 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019ad6:     	movq	-0x30(%rbp), %rdx
100019ada:     	movq	-0x38(%rbp), %r10
100019ade:     	testb	$0x1, %al
100019ae0:     	je	0x100019aee <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ee>
100019ae2:     	leaq	0x2a0(%rbx), %rax
100019ae9:     	jmp	0x100019942 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019aee:     	movq	$0x8, 0x20(%r10)
100019af6:     	movq	0x10(%r10), %rax
100019afa:     	testq	%rax, %rax
100019afd:     	jne	0x100019b26 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x226>
100019aff:     	movq	%rbx, %rdi
100019b02:     	movq	%r10, %rsi
100019b05:     	movq	%rdx, -0x30(%rbp)
100019b09:     	movl	%r12d, %edx
100019b0c:     	movq	%r10, -0x38(%rbp)
100019b10:     	callq	0x100019df0 <_*Gcry::Heap#cursor_advance_word<Pointer(Gcry::CursorSlot), Int32>:UInt64>
100019b15:     	movq	-0x30(%rbp), %rdx
100019b19:     	movq	-0x38(%rbp), %r10
100019b1d:     	testq	%rax, %rax
100019b20:     	je	0x100019d8c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48c>
100019b26:     	cmpl	$0x28, %r12d
100019b2a:     	jae	0x100019da5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a5>
100019b30:     	movq	0x18(%r10), %rcx
100019b34:     	testq	%rax, %rax
100019b37:     	je	0x100019b3f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x23f>
100019b39:     	bsfq	%rax, %r12
100019b3d:     	jmp	0x100019b45 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x245>
100019b3f:     	movl	$0x40, %r12d
100019b45:     	imulq	0x2120(%rbx,%rdx,8), %r12
100019b4e:     	addq	%rcx, %r12
100019b51:     	movq	%r12, 0x20(%r10)
100019b55:     	leaq	-0x1(%rax), %rcx
100019b59:     	andq	%rax, %rcx
100019b5c:     	movq	%rcx, 0x10(%r10)
100019b60:     	movq	%r15, 0x10(%r13)
100019b64:     	incq	0x20(%r13)
100019b68:     	movq	0x19e0(%rbx), %rax
100019b6f:     	testq	%rax, %rax
100019b72:     	je	0x100019b79 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x279>
100019b74:     	prefetcht0	(%rax,%r12)
100019b79:     	cmpb	$0x1, 0x15220(%rbx)
100019b80:     	je	0x100019b8f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x28f>
100019b82:     	cmpb	$0x0, 0x15210(%rbx)
100019b89:     	je	0x100019cb5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019b8f:     	cmpb	$0x0, 0x30f0(%rbx)
100019b96:     	je	0x100019c4c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x34c>
100019b9c:     	movq	%r10, %r15
100019b9f:     	movq	%rbx, %rdi
100019ba2:     	movq	%r12, %rsi
100019ba5:     	callq	0x100010a90 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
100019baa:     	testl	%eax, %eax
100019bac:     	je	0x100019c80 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019bb2:     	cmpb	$0x1, 0x19c0(%rbx)
100019bb9:     	jne	0x100019c80 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019bbf:     	movq	%rdx, %rsi
100019bc2:     	movl	0x10(%rdx), %ecx
100019bc5:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
100019bca:     	cmpq	%rax, %rcx
100019bcd:     	je	0x100019c80 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019bd3:     	testb	$0x1, 0x14(%rsi)
100019bd7:     	jne	0x100019c80 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x380>
100019bdd:     	testl	%ecx, %ecx
100019bdf:     	js	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019be5:     	movl	0x18(%rsi), %edx
100019be8:     	addq	%rsi, %rdx
100019beb:     	movq	%r12, %rax
100019bee:     	subq	%rdx, %rax
100019bf1:     	jb	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019bf7:     	cmpl	$0x27, %ecx
100019bfa:     	ja	0x100019da5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a5>
100019c00:     	mulq	0x2260(%rbx,%rcx,8)
100019c08:     	jo	0x100019da0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4a0>
100019c0e:     	movl	0x1c(%rsi), %edx
100019c11:     	testq	%rdx, %rdx
100019c14:     	movq	%r15, %r10
100019c17:     	je	0x100019cb5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c1d:     	leaq	(%rsi,%rdx,8), %r8
100019c21:     	movq	%rax, %rcx
100019c24:     	shrq	$0x28, %rcx
100019c28:     	shrq	$0x2e, %rax
100019c2c:     	movl	$0x1, %r9d
100019c32:     	shlq	%cl, %r9
100019c35:     	movq	0x20(%r8,%rax,8), %rdi
100019c3a:     	btq	%rcx, %rdi
100019c3e:     	jb	0x100019cb5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c40:     	leaq	0x20(%rsi,%rdx,8), %rcx
100019c45:     	lock
100019c46:     	orq	%r9, (%rcx,%rax,8)
100019c4a:     	jmp	0x100019cb5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c4c:     	movzbl	0x20c3b9(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c53:     	movl	%eax, %ecx
100019c55:     	movl	0x4(%r12), %eax
100019c5a:     	movl	%eax, %edx
100019c5c:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
100019c62:     	movzbl	%cl, %esi
100019c65:     	shll	$0x8, %esi
100019c68:     	orl	%edx, %esi
100019c6a:     	lock
100019c6b:     	cmpxchgl	%esi, 0x4(%r12)
100019c71:     	movzbl	0x20c394(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c78:     	jne	0x100019c53 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019c7a:     	cmpb	%al, %cl
100019c7c:     	jne	0x100019c53 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x353>
100019c7e:     	jmp	0x100019cb5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3b5>
100019c80:     	movzbl	0x20c385(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019c87:     	movq	%r15, %r10
100019c8a:     	movl	%eax, %ecx
100019c8c:     	movl	0x4(%r12), %eax
100019c91:     	movl	%eax, %edx
100019c93:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
100019c99:     	movzbl	%cl, %esi
100019c9c:     	shll	$0x8, %esi
100019c9f:     	orl	%edx, %esi
100019ca1:     	lock
100019ca2:     	cmpxchgl	%esi, 0x4(%r12)
100019ca8:     	movzbl	0x20c35d(%rip), %eax    ## 0x10022600c <_Gcry::BlockHeader::mark_gen>
100019caf:     	jne	0x100019c8a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x38a>
100019cb1:     	cmpb	%al, %cl
100019cb3:     	jne	0x100019c8a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x38a>
100019cb5:     	movq	-0x40(%rbp), %rsi
100019cb9:     	leaq	-0x10(%rsi), %rax
100019cbd:     	rolq	$0x3c, %rax
100019cc1:     	cmpq	$0x3, %rax
100019cc5:     	ja	0x100019d6f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x46f>
100019ccb:     	leaq	0xe2(%rip), %rcx        ## 0x100019db4 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4b4>
100019cd2:     	movslq	(%rcx,%rax,4), %rax
100019cd6:     	addq	%rcx, %rax
100019cd9:     	jmpq	*%rax
100019cdb:     	movq	$0x0, 0x38(%r12)
100019ce4:     	movq	$0x0, 0x30(%r12)
100019ced:     	movq	$0x0, 0x28(%r12)
100019cf6:     	movq	$0x0, 0x20(%r12)
100019cff:     	movq	$0x0, 0x18(%r12)
100019d08:     	movq	$0x0, 0x10(%r12)
100019d11:     	movq	$0x0, 0x8(%r12)
100019d1a:     	movq	$0x0, (%r12)
100019d22:     	movq	$0x0, 0x20(%r10)
100019d2a:     	cmpb	$0x1, 0x20c53f(%rip)    ## 0x100226270 <_Gcry::Invariant::enabled>
100019d31:     	jne	0x100019d3b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x43b>
100019d33:     	movq	%rbx, %rdi
100019d36:     	callq	0x100016cd0 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
100019d3b:     	cmpb	$0x1, 0x20c512(%rip)    ## 0x100226254 <_Gcry::Trace::enabled>
100019d42:     	jne	0x100019d51 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x451>
100019d44:     	movq	%r12, %rdi
100019d47:     	movq	%r14, %rsi
100019d4a:     	xorl	%edx, %edx
100019d4c:     	callq	0x10001a270 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
100019d51:     	movq	%r12, %rax
100019d54:     	addq	$0x28, %rsp
100019d58:     	popq	%rbx
100019d59:     	popq	%r12
100019d5b:     	popq	%r13
100019d5d:     	popq	%r14
100019d5f:     	popq	%r15
100019d61:     	popq	%rbp
100019d62:     	retq
100019d63:     	leaq	0x298(%rbx), %rax
100019d6a:     	jmp	0x100019942 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019d6f:     	movq	%r12, %rdi
100019d72:     	movq	%r10, %r15
100019d75:     	callq	0x1001c55ac <_write+0x1001c55ac>
100019d7a:     	movq	$0x0, 0x20(%r15)
100019d82:     	testq	%r12, %r12
100019d85:     	jne	0x100019d2a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42a>
100019d87:     	jmp	0x100019945 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019d8c:     	movq	$0x0, 0x20(%r10)
100019d94:     	leaq	0x298(%rbx), %rax
100019d9b:     	jmp	0x100019942 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x42>
100019da0:     	callq	0x100005a60 <___crystal_raise_overflow>
100019da5:     	callq	0x100009e80 <_*IndexError::new:IndexError>
100019daa:     	movq	%rax, %rdi
100019dad:     	callq	0x100009ed0 <_*raise<IndexError>:NoReturn>
100019db2:     	nop
100019db4:     	popq	%rbp
100019db5:     	<unknown>
100019db7:     	decl	-0x1(%rbx)
100019dba:     	<unknown>
100019dbc:     	cmpl	%edi, %edi
100019dbe:     	<unknown>
100019dc0:     	<unknown>
100019dc1:     	<unknown>
100019dc3:     	jmpq	*0x2e(%rsi)
100019dc6:     	nopl	(%rax,%rax)
100019dce:     	nop
