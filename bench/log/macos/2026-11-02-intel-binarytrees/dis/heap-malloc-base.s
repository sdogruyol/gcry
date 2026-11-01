
bin/ab-base:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

0000000100019980 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
100019980:     	pushq	%rbp
100019981:     	movq	%rsp, %rbp
100019984:     	pushq	%r15
100019986:     	pushq	%r14
100019988:     	pushq	%r13
10001998a:     	pushq	%r12
10001998c:     	pushq	%rbx
10001998d:     	subq	$0x88, %rsp
100019994:     	movq	%rsi, %r14
100019997:     	movq	%rdi, %rbx
10001999a:     	cmpb	$0x1, 0x1509c(%rdi)
1000199a1:     	jne	0x1000199c8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
1000199a3:     	cmpb	$0x1, 0x15210(%rbx)
1000199aa:     	je	0x1000199be <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
1000199ac:     	cmpb	$0x0, 0x15220(%rbx)
1000199b3:     	jne	0x1000199be <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
1000199b5:     	cmpb	$0x0, 0x152d3(%rbx)
1000199bc:     	je	0x1000199eb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b>
1000199be:     	leaq	0x280(%rbx), %rax
1000199c5:     	incq	(%rax)
1000199c8:     	movq	%rbx, %rdi
1000199cb:     	movq	%r14, %rsi
1000199ce:     	xorl	%edx, %edx
1000199d0:     	movl	$0x1, %ecx
1000199d5:     	addq	$0x88, %rsp
1000199dc:     	popq	%rbx
1000199dd:     	popq	%r12
1000199df:     	popq	%r13
1000199e1:     	popq	%r14
1000199e3:     	popq	%r15
1000199e5:     	popq	%rbp
1000199e6:     	jmp	0x10001ab70 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
1000199eb:     	cmpq	$0x8000, %r14           ## imm = 0x8000
1000199f2:     	jbe	0x1000199fd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7d>
1000199f4:     	leaq	0x288(%rbx), %rax
1000199fb:     	jmp	0x1000199c5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
1000199fd:     	movq	0x14f38(%rbx), %rax
100019a04:     	testq	%rax, %rax
100019a07:     	je	0x100019a17 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x97>
100019a09:     	decq	%rax
100019a0c:     	movq	%gs:(,%rax,8), %rdx
100019a15:     	jmp	0x100019a36 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
100019a17:     	leaq	-0xb0(%rbp), %rdi
100019a1e:     	callq	0x100015770 <_*Gcry::Heap::tls_cursor_cache>
100019a23:     	movq	-0xb0(%rbp), %rax
100019a2a:     	movq	0x8(%rax), %rcx
100019a2e:     	xorq	%rbx, %rcx
100019a31:     	jne	0x100019a41 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019a33:     	movq	(%rax), %rdx
100019a36:     	testq	%rdx, %rdx
100019a39:     	je	0x100019a41 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019a3b:     	cmpb	$0x0, 0x9(%rdx)
100019a3f:     	je	0x100019a4d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xcd>
100019a41:     	leaq	0x290(%rbx), %rax
100019a48:     	jmp	0x1000199c5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019a4d:     	cmpq	$0x801, %r14            ## imm = 0x801
100019a54:     	jae	0x100019a73 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xf3>
100019a56:     	leaq	0x7(%r14), %rcx
100019a5a:     	shrq	$0x3, %rcx
100019a5e:     	movl	0x328c(%rbx,%rcx,4), %eax
100019a65:     	movzbl	0x3188(%rbx,%rcx), %r8d
100019a6e:     	jmp	0x100019b1b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x19b>
100019a73:     	movl	$0xc, %r15d
100019a79:     	cmpq	$0x4000, %r14           ## imm = 0x4000
100019a80:     	ja	0x100019aa2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x122>
100019a82:     	movl	$0xb, %r15d
100019a88:     	cmpq	$0x2001, %r14           ## imm = 0x2001
100019a8f:     	jae	0x100019aa2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x122>
100019a91:     	cmpq	$0x1001, %r14           ## imm = 0x1001
100019a98:     	movl	$0x9, %r15d
100019a9e:     	sbbl	$-0x1, %r15d
100019aa2:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019aac:     	movq	%r14, %rdi
100019aaf:     	xorq	%r12, %rdi
100019ab2:     	decq	%rdi
100019ab5:     	jo	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019abb:     	movq	%rdx, %r13
100019abe:     	xorq	%r12, %rdi
100019ac1:     	movl	%r15d, %esi
100019ac4:     	callq	0x100009680 <_*UInt64@Int#>><Int32>:UInt64>
100019ac9:     	xorq	%r12, %rax
100019acc:     	incq	%rax
100019acf:     	jo	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019ad5:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019adf:     	cmpq	%rcx, %rax
100019ae2:     	jge	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019ae8:     	testl	%eax, %eax
100019aea:     	js	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019af0:     	leal	-0xd(,%r15,4), %r12d
100019af8:     	addl	%eax, %r12d
100019afb:     	jo	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019b01:     	addl	$-0x4, %r12d
100019b05:     	jo	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019b0b:     	movl	%eax, %edi
100019b0d:     	movl	%r15d, %esi
100019b10:     	callq	0x10000a8b0 <_*UInt32@Int#<<<Int32>:UInt32>
100019b15:     	movq	%r13, %rdx
100019b18:     	movq	%r12, %r8
100019b1b:     	movslq	%r8d, %rcx
100019b1e:     	leaq	(%rcx,%rcx,4), %rcx
100019b22:     	leaq	0x30(%rdx,%rcx,8), %r15
100019b27:     	cmpq	$0x0, 0x40(%rdx,%rcx,8)
100019b2d:     	jne	0x100019b39 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1b9>
100019b2f:     	cmpq	$0x0, (%r15)
100019b33:     	je	0x100019be6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x266>
100019b39:     	movl	%eax, %r13d
100019b3c:     	movq	0x10(%rdx), %r9
100019b40:     	addq	%r13, %r9
100019b43:     	movq	%r9, %rsi
100019b46:     	subq	0x18(%rdx), %rsi
100019b4a:     	addq	0x14f80(%rbx), %rsi
100019b51:     	movq	0x3840(%rbx), %rdi
100019b58:     	cmpq	%rdi, %rsi
100019b5b:     	jb	0x100019b94 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x214>
100019b5d:     	movq	%rdx, %r12
100019b60:     	movq	%r13, -0x40(%rbp)
100019b64:     	movq	%r8, %r13
100019b67:     	movq	%r15, -0x48(%rbp)
100019b6b:     	movq	%r9, %r15
100019b6e:     	callq	0x10001a170 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019b73:     	movq	%r15, %r9
100019b76:     	movq	-0x48(%rbp), %r15
100019b7a:     	movq	%r13, %r8
100019b7d:     	movq	-0x40(%rbp), %r13
100019b81:     	movq	%r12, %rdx
100019b84:     	testb	$0x1, %al
100019b86:     	je	0x100019b94 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x214>
100019b88:     	leaq	0x2a0(%rbx), %rax
100019b8f:     	jmp	0x1000199c5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019b94:     	movq	$0x8, 0x20(%r15)
100019b9c:     	movq	0x10(%r15), %rsi
100019ba0:     	testq	%rsi, %rsi
100019ba3:     	je	0x100019bba <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x23a>
100019ba5:     	testq	%rsi, %rsi
100019ba8:     	je	0x100019eef <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x56f>
100019bae:     	movq	%rsi, %rdi
100019bb1:     	bsfq	%rsi, %r12
100019bb5:     	jmp	0x100019ef8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x578>
100019bba:     	movq	%r9, -0x68(%rbp)
100019bbe:     	movq	%r8, -0x58(%rbp)
100019bc2:     	movq	%rdx, -0x70(%rbp)
100019bc6:     	movq	(%r15), %rsi
100019bc9:     	testq	%rsi, %rsi
100019bcc:     	je	0x100019e19 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x499>
100019bd2:     	movl	0x10(%rsi), %eax
100019bd5:     	testl	%eax, %eax
100019bd7:     	js	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019bdd:     	cmpl	$0x27, %eax
100019be0:     	jbe	0x100019bf2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x272>
100019be2:     	xorl	%eax, %eax
100019be4:     	jmp	0x100019c15 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x295>
100019be6:     	leaq	0x298(%rbx), %rax
100019bed:     	jmp	0x1000199c5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019bf2:     	movq	0x2120(%rbx,%rax,8), %rdi
100019bfa:     	xorl	%eax, %eax
100019bfc:     	testq	%rdi, %rdi
100019bff:     	je	0x100019c15 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x295>
100019c01:     	movq	0x8(%rsi), %rcx
100019c05:     	movl	0x18(%rsi), %edx
100019c08:     	subq	%rdx, %rcx
100019c0b:     	jbe	0x100019c15 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x295>
100019c0d:     	movq	%rcx, %rax
100019c10:     	xorl	%edx, %edx
100019c12:     	divq	%rdi
100019c15:     	movabsq	$-0x8000000000000000, %r11 ## imm = 0x8000000000000000
100019c1f:     	movq	%rax, %rdx
100019c22:     	xorq	%r11, %rdx
100019c25:     	movq	%rdx, %r12
100019c28:     	addq	$0x3f, %r12
100019c2c:     	jo	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019c32:     	movabsq	$0x200000000000000, %r10 ## imm = 0x200000000000000
100019c3c:     	shrq	$0x6, %r12
100019c40:     	movq	%r12, %rdi
100019c43:     	xorq	%r10, %rdi
100019c46:     	andq	$-0x80000000, %rdi      ## imm = 0x80000000
100019c4d:     	jne	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019c53:     	movslq	0x8(%r15), %rdi
100019c57:     	cmpl	%r12d, %edi
100019c5a:     	jge	0x100019e19 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x499>
100019c60:     	decq	%rdx
100019c63:     	seto	%r9b
100019c67:     	cmpl	$0x0, 0x1c(%rsi)
100019c6b:     	je	0x100019e19 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x499>
100019c71:     	andl	$0x3f, %eax
100019c74:     	btcq	%rax, %r11
100019c78:     	decq	%r11
100019c7b:     	setno	%r8b
100019c7f:     	testq	%rax, %rax
100019c82:     	sete	-0x29(%rbp)
100019c86:     	xorl	%ecx, %ecx
100019c88:     	cmpq	$0x1, %rax
100019c8c:     	sbbq	%rcx, %rcx
100019c8f:     	movq	%rcx, -0x60(%rbp)
100019c93:     	testb	%r9b, %r9b
100019c96:     	jne	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019c9c:     	shrq	$0x6, %rdx
100019ca0:     	xorq	%rdx, %r10
100019ca3:     	cmpq	$0x7fffffff, %r10       ## imm = 0x7FFFFFFF
100019caa:     	ja	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019cb0:     	leaq	0x20(%rsi), %rax
100019cb4:     	movabsq	$-0x8000000000000000, %rcx ## imm = 0x8000000000000000
100019cbe:     	xorq	%rcx, %r11
100019cc1:     	orq	%r11, -0x60(%rbp)
100019cc5:     	movslq	%edx, %r9
100019cc8:     	movslq	%r12d, %rdx
100019ccb:     	orb	%r8b, -0x29(%rbp)
100019ccf:     	movq	%rax, -0x38(%rbp)
100019cd3:     	movq	%r15, -0x48(%rbp)
100019cd7:     	movq	%r13, -0x40(%rbp)
100019cdb:     	movq	%rsi, -0x88(%rbp)
100019ce2:     	movq	%r9, -0x80(%rbp)
100019ce6:     	movq	%rdx, -0x78(%rbp)
100019cea:     	jmp	0x100019d2e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3ae>
100019cec:     	movq	-0x98(%rbp), %rcx
100019cf3:     	andq	-0x50(%rbp), %rcx
100019cf7:     	movq	-0x48(%rbp), %r15
100019cfb:     	movq	-0x40(%rbp), %r13
100019cff:     	movq	-0x88(%rbp), %rsi
100019d06:     	movq	-0x38(%rbp), %rax
100019d0a:     	movq	-0x90(%rbp), %rdi
100019d11:     	movq	-0x80(%rbp), %r9
100019d15:     	movq	-0x78(%rbp), %rdx
100019d19:     	testq	%rcx, %rcx
100019d1c:     	jne	0x100019e2d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4ad>
100019d22:     	incq	%rdi
100019d25:     	cmpq	%rdx, %rdi
100019d28:     	je	0x100019e19 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x499>
100019d2e:     	cmpl	$0x0, 0x1c(%rsi)
100019d32:     	je	0x100019d22 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3a2>
100019d34:     	movq	(%rax,%rdi,8), %rcx
100019d38:     	notq	%rcx
100019d3b:     	cmpq	%r9, %rdi
100019d3e:     	jne	0x100019d4e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3ce>
100019d40:     	cmpb	$0x0, -0x29(%rbp)
100019d44:     	je	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019d4a:     	andq	-0x60(%rbp), %rcx
100019d4e:     	cmpb	$0x1, 0x42f0(%rbx)
100019d55:     	jne	0x100019d19 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x399>
100019d57:     	testq	%rcx, %rcx
100019d5a:     	je	0x100019d19 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x399>
100019d5c:     	movl	0x10(%rsi), %eax
100019d5f:     	testl	%eax, %eax
100019d61:     	js	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019d67:     	cmpl	$0x27, %eax
100019d6a:     	ja	0x10001a14e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ce>
100019d70:     	testq	%rdi, %rdi
100019d73:     	js	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019d79:     	movl	0x18(%rsi), %edx
100019d7c:     	addq	%rsi, %rdx
100019d7f:     	movq	%rdx, -0xa8(%rbp)
100019d86:     	movq	0x2120(%rbx,%rax,8), %rax
100019d8e:     	movq	%rax, -0xa0(%rbp)
100019d95:     	movq	%rdi, -0x90(%rbp)
100019d9c:     	movq	%rdi, %r13
100019d9f:     	shlq	$0x6, %r13
100019da3:     	movq	%rcx, -0x50(%rbp)
100019da7:     	movq	%rcx, -0x98(%rbp)
100019dae:     	movq	%rcx, %r15
100019db1:     	jmp	0x100019dd6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x456>
100019db3:     	movq	-0x50(%rbp), %rdx
100019db7:     	btrq	%r12, %rdx
100019dbb:     	movq	%rdx, -0x50(%rbp)
100019dbf:     	xorq	%rcx, %rax
100019dc2:     	movq	%rax, 0x4300(%rbx)
100019dc9:     	leaq	-0x1(%r15), %rax
100019dcd:     	andq	%rax, %r15
100019dd0:     	je	0x100019cec <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x36c>
100019dd6:     	bsfq	%r15, %r12
100019dda:     	movq	%r12, %rsi
100019ddd:     	orq	%r13, %rsi
100019de0:     	imulq	-0xa0(%rbp), %rsi
100019de8:     	addq	-0xa8(%rbp), %rsi
100019def:     	movq	%rbx, %rdi
100019df2:     	callq	0x10001a190 <_*Gcry::Heap#blacklisted_page?<UInt64>:Bool>
100019df7:     	testb	$0x1, %al
100019df9:     	je	0x100019dc9 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x449>
100019dfb:     	movq	0x4300(%rbx), %rax
100019e02:     	movabsq	$-0x8000000000000000, %rcx ## imm = 0x8000000000000000
100019e0c:     	xorq	%rcx, %rax
100019e0f:     	incq	%rax
100019e12:     	jno	0x100019db3 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x433>
100019e14:     	callq	0x100005a40 <___crystal_raise_overflow>
100019e19:     	movq	$0x0, 0x20(%r15)
100019e21:     	leaq	0x298(%rbx), %rax
100019e28:     	jmp	0x1000199c5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019e2d:     	movl	%edi, 0x8(%r15)
100019e31:     	testl	%edi, %edi
100019e33:     	js	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019e35:     	movq	%rcx, %r9
100019e38:     	movq	%r15, %r8
100019e3b:     	movq	%rdi, %r10
100019e3e:     	movq	%rsi, %rdi
100019e41:     	movl	0x18(%rsi), %ecx
100019e44:     	movq	-0x58(%rbp), %rax
100019e48:     	testl	%eax, %eax
100019e4a:     	js	0x100019e58 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4d8>
100019e4c:     	cmpl	$0x27, %eax
100019e4f:     	movl	%eax, %edx
100019e51:     	jbe	0x100019e64 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4e4>
100019e53:     	jmp	0x10001a14e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ce>
100019e58:     	cmpl	$-0x29, %eax
100019e5b:     	jbe	0x10001a14e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ce>
100019e61:     	leal	0x28(%rax), %edx
100019e64:     	addq	%rdi, %rcx
100019e67:     	movl	%r10d, %eax
100019e6a:     	movq	%rax, %rsi
100019e6d:     	shlq	$0x6, %rsi
100019e71:     	movl	%edx, %edx
100019e73:     	imulq	0x2120(%rbx,%rdx,8), %rsi
100019e7c:     	addq	%rcx, %rsi
100019e7f:     	movq	%r8, %rcx
100019e82:     	movq	%rsi, 0x18(%r8)
100019e86:     	movq	%r9, %rsi
100019e89:     	movq	%r9, 0x10(%r8)
100019e8d:     	cmpb	$0x1, 0x15210(%rbx)
100019e94:     	je	0x100019ea8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x528>
100019e96:     	cmpb	$0x0, 0x15220(%rbx)
100019e9d:     	jne	0x100019ea8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x528>
100019e9f:     	cmpb	$0x0, 0x152d3(%rbx)
100019ea6:     	je	0x100019ebf <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x53f>
100019ea8:     	movl	0x1c(%rdi), %ecx
100019eab:     	testq	%rcx, %rcx
100019eae:     	movq	-0x38(%rbp), %rdx
100019eb2:     	je	0x100019ec9 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x549>
100019eb4:     	leaq	(%rdx,%rcx,8), %rcx
100019eb8:     	lock
100019eb9:     	orq	%rsi, (%rcx,%rax,8)
100019ebd:     	jmp	0x100019ecb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x54b>
100019ebf:     	cmpl	$0x0, 0x1c(%rdi)
100019ec3:     	movq	-0x38(%rbp), %rdx
100019ec7:     	jne	0x100019ecb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x54b>
100019ec9:     	xorl	%edx, %edx
100019ecb:     	lock
100019ecc:     	orq	%rsi, (%rdx,%rax,8)
100019ed0:     	incq	0x278(%rbx)
100019ed7:     	movq	%r8, %r15
100019eda:     	movq	-0x70(%rbp), %rdx
100019ede:     	movq	-0x58(%rbp), %r8
100019ee2:     	movq	-0x68(%rbp), %r9
100019ee6:     	testq	%rsi, %rsi
100019ee9:     	jne	0x100019bae <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x22e>
100019eef:     	movq	%rsi, %rdi
100019ef2:     	movl	$0x40, %r12d
100019ef8:     	movq	0x18(%r15), %rax
100019efc:     	testl	%r8d, %r8d
100019eff:     	js	0x100019f0c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x58c>
100019f01:     	cmpl	$0x27, %r8d
100019f05:     	jbe	0x100019f1a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x59a>
100019f07:     	jmp	0x10001a14e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ce>
100019f0c:     	cmpl	$-0x29, %r8d
100019f10:     	jbe	0x10001a14e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ce>
100019f16:     	addl	$0x28, %r8d
100019f1a:     	movl	%r8d, %ecx
100019f1d:     	imulq	0x2120(%rbx,%rcx,8), %r12
100019f26:     	addq	%rax, %r12
100019f29:     	movq	%r12, 0x20(%r15)
100019f2d:     	leaq	-0x1(%rdi), %rax
100019f31:     	andq	%rdi, %rax
100019f34:     	movq	%rax, 0x10(%r15)
100019f38:     	movq	%r9, 0x10(%rdx)
100019f3c:     	incq	0x20(%rdx)
100019f40:     	movq	0x19e0(%rbx), %rax
100019f47:     	testq	%rax, %rax
100019f4a:     	je	0x100019f51 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5d1>
100019f4c:     	prefetcht0	(%rax,%r12)
100019f51:     	cmpb	$0x1, 0x15220(%rbx)
100019f58:     	je	0x100019f67 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5e7>
100019f5a:     	cmpb	$0x0, 0x15210(%rbx)
100019f61:     	je	0x10001a084 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x704>
100019f67:     	cmpb	$0x0, 0x30f0(%rbx)
100019f6e:     	je	0x10001a01e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x69e>
100019f74:     	movq	%rbx, %rdi
100019f77:     	movq	%r12, %rsi
100019f7a:     	callq	0x100011d30 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
100019f7f:     	testl	%eax, %eax
100019f81:     	je	0x10001a052 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6d2>
100019f87:     	cmpb	$0x1, 0x19c0(%rbx)
100019f8e:     	jne	0x10001a052 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6d2>
100019f94:     	movq	%rdx, %rsi
100019f97:     	movl	0x10(%rdx), %ecx
100019f9a:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
100019f9f:     	cmpq	%rax, %rcx
100019fa2:     	je	0x10001a052 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6d2>
100019fa8:     	testb	$0x1, 0x14(%rsi)
100019fac:     	jne	0x10001a052 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6d2>
100019fb2:     	testl	%ecx, %ecx
100019fb4:     	js	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019fba:     	movl	0x18(%rsi), %edx
100019fbd:     	addq	%rsi, %rdx
100019fc0:     	movq	%r12, %rax
100019fc3:     	subq	%rdx, %rax
100019fc6:     	jb	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019fcc:     	cmpl	$0x27, %ecx
100019fcf:     	ja	0x10001a14e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ce>
100019fd5:     	mulq	0x2260(%rbx,%rcx,8)
100019fdd:     	jo	0x100019e14 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x494>
100019fe3:     	movl	0x1c(%rsi), %edx
100019fe6:     	testq	%rdx, %rdx
100019fe9:     	je	0x10001a084 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x704>
100019fef:     	leaq	(%rsi,%rdx,8), %r8
100019ff3:     	movq	%rax, %rcx
100019ff6:     	shrq	$0x28, %rcx
100019ffa:     	shrq	$0x2e, %rax
100019ffe:     	movl	$0x1, %r9d
10001a004:     	shlq	%cl, %r9
10001a007:     	movq	0x20(%r8,%rax,8), %rdi
10001a00c:     	btq	%rcx, %rdi
10001a010:     	jb	0x10001a084 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x704>
10001a012:     	leaq	0x20(%rsi,%rdx,8), %rcx
10001a017:     	lock
10001a018:     	orq	%r9, (%rcx,%rax,8)
10001a01c:     	jmp	0x10001a084 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x704>
10001a01e:     	movzbl	0x205fe7(%rip), %eax    ## 0x10022000c <_Gcry::BlockHeader::mark_gen>
10001a025:     	movl	%eax, %ecx
10001a027:     	movl	0x4(%r12), %eax
10001a02c:     	movl	%eax, %edx
10001a02e:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a034:     	movzbl	%cl, %esi
10001a037:     	shll	$0x8, %esi
10001a03a:     	orl	%edx, %esi
10001a03c:     	lock
10001a03d:     	cmpxchgl	%esi, 0x4(%r12)
10001a043:     	movzbl	0x205fc2(%rip), %eax    ## 0x10022000c <_Gcry::BlockHeader::mark_gen>
10001a04a:     	jne	0x10001a025 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6a5>
10001a04c:     	cmpb	%al, %cl
10001a04e:     	jne	0x10001a025 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6a5>
10001a050:     	jmp	0x10001a084 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x704>
10001a052:     	movzbl	0x205fb3(%rip), %eax    ## 0x10022000c <_Gcry::BlockHeader::mark_gen>
10001a059:     	movl	%eax, %ecx
10001a05b:     	movl	0x4(%r12), %eax
10001a060:     	movl	%eax, %edx
10001a062:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a068:     	movzbl	%cl, %esi
10001a06b:     	shll	$0x8, %esi
10001a06e:     	orl	%edx, %esi
10001a070:     	lock
10001a071:     	cmpxchgl	%esi, 0x4(%r12)
10001a077:     	movzbl	0x205f8e(%rip), %eax    ## 0x10022000c <_Gcry::BlockHeader::mark_gen>
10001a07e:     	jne	0x10001a059 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6d9>
10001a080:     	cmpb	%al, %cl
10001a082:     	jne	0x10001a059 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6d9>
10001a084:     	leaq	-0x10(%r13), %rax
10001a088:     	rolq	$0x3c, %rax
10001a08c:     	cmpq	$0x3, %rax
10001a090:     	ja	0x10001a131 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7b1>
10001a096:     	leaq	0xbf(%rip), %rcx        ## 0x10001a15c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dc>
10001a09d:     	movslq	(%rcx,%rax,4), %rax
10001a0a1:     	addq	%rcx, %rax
10001a0a4:     	jmpq	*%rax
10001a0a6:     	movq	$0x0, 0x38(%r12)
10001a0af:     	movq	$0x0, 0x30(%r12)
10001a0b8:     	movq	$0x0, 0x28(%r12)
10001a0c1:     	movq	$0x0, 0x20(%r12)
10001a0ca:     	movq	$0x0, 0x18(%r12)
10001a0d3:     	movq	$0x0, 0x10(%r12)
10001a0dc:     	movq	$0x0, 0x8(%r12)
10001a0e5:     	movq	$0x0, (%r12)
10001a0ed:     	movq	$0x0, 0x20(%r15)
10001a0f5:     	cmpb	$0x1, 0x206164(%rip)    ## 0x100220260 <_Gcry::Invariant::enabled>
10001a0fc:     	jne	0x10001a106 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x786>
10001a0fe:     	movq	%rbx, %rdi
10001a101:     	callq	0x100017180 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
10001a106:     	cmpb	$0x1, 0x206137(%rip)    ## 0x100220244 <_Gcry::Trace::enabled>
10001a10d:     	jne	0x10001a11c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x79c>
10001a10f:     	movq	%r12, %rdi
10001a112:     	movq	%r14, %rsi
10001a115:     	xorl	%edx, %edx
10001a117:     	callq	0x10001a240 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
10001a11c:     	movq	%r12, %rax
10001a11f:     	addq	$0x88, %rsp
10001a126:     	popq	%rbx
10001a127:     	popq	%r12
10001a129:     	popq	%r13
10001a12b:     	popq	%r14
10001a12d:     	popq	%r15
10001a12f:     	popq	%rbp
10001a130:     	retq
10001a131:     	movq	%r12, %rdi
10001a134:     	movq	%r13, %rsi
10001a137:     	callq	0x1001bf82c <_write+0x1001bf82c>
10001a13c:     	movq	$0x0, 0x20(%r15)
10001a144:     	testq	%r12, %r12
10001a147:     	jne	0x10001a0f5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x775>
10001a149:     	jmp	0x1000199c8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
10001a14e:     	callq	0x10000a310 <_*IndexError::new:IndexError>
10001a153:     	movq	%rax, %rdi
10001a156:     	callq	0x10000a360 <_*raise<IndexError>:NoReturn>
10001a15b:     	nop
10001a15c:     	cmpb	$-0x1, %bh
10001a15f:     	ljmpl	*-0x1(%rsi)
10001a162:     	<unknown>
10001a164:     	popq	%rsp
10001a165:     	<unknown>
10001a167:     	decl	-0x1(%rdx)
10001a16a:     	<unknown>
10001a16c:     	nopl	(%rax)
