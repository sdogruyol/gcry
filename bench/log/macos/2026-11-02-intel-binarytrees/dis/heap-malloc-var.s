
bin/ab-var:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

0000000100019a50 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
100019a50:     	pushq	%rbp
100019a51:     	movq	%rsp, %rbp
100019a54:     	pushq	%r15
100019a56:     	pushq	%r14
100019a58:     	pushq	%r13
100019a5a:     	pushq	%r12
100019a5c:     	pushq	%rbx
100019a5d:     	subq	$0x98, %rsp
100019a64:     	movq	%rsi, %r14
100019a67:     	movq	%rdi, %rbx
100019a6a:     	cmpb	$0x1, 0x150bc(%rdi)
100019a71:     	jne	0x100019a98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
100019a73:     	cmpb	$0x1, 0x15230(%rbx)
100019a7a:     	je	0x100019a8e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
100019a7c:     	cmpb	$0x0, 0x15240(%rbx)
100019a83:     	jne	0x100019a8e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
100019a85:     	cmpb	$0x0, 0x152f3(%rbx)
100019a8c:     	je	0x100019abb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b>
100019a8e:     	leaq	0x280(%rbx), %rax
100019a95:     	incq	(%rax)
100019a98:     	movq	%rbx, %rdi
100019a9b:     	movq	%r14, %rsi
100019a9e:     	xorl	%edx, %edx
100019aa0:     	movl	$0x1, %ecx
100019aa5:     	addq	$0x98, %rsp
100019aac:     	popq	%rbx
100019aad:     	popq	%r12
100019aaf:     	popq	%r13
100019ab1:     	popq	%r14
100019ab3:     	popq	%r15
100019ab5:     	popq	%rbp
100019ab6:     	jmp	0x10001ac60 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
100019abb:     	cmpq	$0x8000, %r14           ## imm = 0x8000
100019ac2:     	jbe	0x100019acd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7d>
100019ac4:     	leaq	0x288(%rbx), %rax
100019acb:     	jmp	0x100019a95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019acd:     	movq	0x14f58(%rbx), %rax
100019ad4:     	testq	%rax, %rax
100019ad7:     	je	0x100019ae7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x97>
100019ad9:     	decq	%rax
100019adc:     	movq	%gs:(,%rax,8), %rdx
100019ae5:     	jmp	0x100019b06 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
100019ae7:     	leaq	-0xc0(%rbp), %rdi
100019aee:     	callq	0x100014fb0 <_*Gcry::Heap::tls_cursor_cache>
100019af3:     	movq	-0xc0(%rbp), %rax
100019afa:     	movq	0x8(%rax), %rcx
100019afe:     	xorq	%rbx, %rcx
100019b01:     	jne	0x100019b11 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019b03:     	movq	(%rax), %rdx
100019b06:     	testq	%rdx, %rdx
100019b09:     	je	0x100019b11 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019b0b:     	cmpb	$0x0, 0x9(%rdx)
100019b0f:     	je	0x100019b1d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xcd>
100019b11:     	leaq	0x290(%rbx), %rax
100019b18:     	jmp	0x100019a95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019b1d:     	cmpq	$0x801, %r14            ## imm = 0x801
100019b24:     	jae	0x100019b42 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xf2>
100019b26:     	leaq	0x7(%r14), %rcx
100019b2a:     	shrq	$0x3, %rcx
100019b2e:     	movl	0x32ac(%rbx,%rcx,4), %eax
100019b35:     	movzbl	0x31a8(%rbx,%rcx), %esi
100019b3d:     	jmp	0x100019bea <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x19a>
100019b42:     	movl	$0xc, %r15d
100019b48:     	cmpq	$0x4000, %r14           ## imm = 0x4000
100019b4f:     	ja	0x100019b71 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x121>
100019b51:     	movl	$0xb, %r15d
100019b57:     	cmpq	$0x2001, %r14           ## imm = 0x2001
100019b5e:     	jae	0x100019b71 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x121>
100019b60:     	cmpq	$0x1001, %r14           ## imm = 0x1001
100019b67:     	movl	$0x9, %r15d
100019b6d:     	sbbl	$-0x1, %r15d
100019b71:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019b7b:     	movq	%r14, %rdi
100019b7e:     	xorq	%r12, %rdi
100019b81:     	decq	%rdi
100019b84:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019b8a:     	movq	%rdx, %r13
100019b8d:     	xorq	%r12, %rdi
100019b90:     	movl	%r15d, %esi
100019b93:     	callq	0x1000096d0 <_*UInt64@Int#>><Int32>:UInt64>
100019b98:     	xorq	%r12, %rax
100019b9b:     	incq	%rax
100019b9e:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019ba4:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019bae:     	cmpq	%rcx, %rax
100019bb1:     	jge	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019bb7:     	testl	%eax, %eax
100019bb9:     	js	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019bbf:     	leal	-0xd(,%r15,4), %r12d
100019bc7:     	addl	%eax, %r12d
100019bca:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019bd0:     	addl	$-0x4, %r12d
100019bd4:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019bda:     	movl	%eax, %edi
100019bdc:     	movl	%r15d, %esi
100019bdf:     	callq	0x10000a9d0 <_*UInt32@Int#<<<Int32>:UInt32>
100019be4:     	movq	%r13, %rdx
100019be7:     	movq	%r12, %rsi
100019bea:     	movslq	%esi, %rcx
100019bed:     	leaq	(%rcx,%rcx,4), %rcx
100019bf1:     	leaq	0x30(%rdx,%rcx,8), %r15
100019bf6:     	cmpq	$0x0, 0x40(%rdx,%rcx,8)
100019bfc:     	jne	0x100019c08 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1b8>
100019bfe:     	cmpq	$0x0, (%r15)
100019c02:     	je	0x100019c9e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x24e>
100019c08:     	movq	%rsi, -0x38(%rbp)
100019c0c:     	movl	%eax, %r13d
100019c0f:     	movq	0x10(%rdx), %rsi
100019c13:     	addq	%r13, %rsi
100019c16:     	movq	%rsi, -0xa0(%rbp)
100019c1d:     	subq	0x18(%rdx), %rsi
100019c21:     	addq	0x14fa0(%rbx), %rsi
100019c28:     	movq	0x3860(%rbx), %rdi
100019c2f:     	cmpq	%rdi, %rsi
100019c32:     	jb	0x100019c4f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ff>
100019c34:     	movq	%rdx, %r12
100019c37:     	callq	0x10001a260 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019c3c:     	movq	%r12, %rdx
100019c3f:     	testb	$0x1, %al
100019c41:     	je	0x100019c4f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ff>
100019c43:     	leaq	0x2a0(%rbx), %rax
100019c4a:     	jmp	0x100019a95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019c4f:     	movq	$0x8, 0x20(%r15)
100019c57:     	movq	0x10(%r15), %r9
100019c5b:     	testq	%r9, %r9
100019c5e:     	je	0x100019c79 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x229>
100019c60:     	testq	%r9, %r9
100019c63:     	movq	-0x38(%rbp), %rcx
100019c67:     	je	0x100019fd7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x587>
100019c6d:     	movq	%r9, %rsi
100019c70:     	bsfq	%r9, %r12
100019c74:     	jmp	0x100019fe0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x590>
100019c79:     	movq	%rdx, -0x50(%rbp)
100019c7d:     	movq	(%r15), %r8
100019c80:     	testq	%r8, %r8
100019c83:     	je	0x100019f2e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019c89:     	movl	0x10(%r8), %eax
100019c8d:     	testl	%eax, %eax
100019c8f:     	js	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c95:     	cmpl	$0x27, %eax
100019c98:     	jbe	0x100019caa <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x25a>
100019c9a:     	xorl	%eax, %eax
100019c9c:     	jmp	0x100019cce <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019c9e:     	leaq	0x298(%rbx), %rax
100019ca5:     	jmp	0x100019a95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019caa:     	movq	0x2140(%rbx,%rax,8), %rsi
100019cb2:     	xorl	%eax, %eax
100019cb4:     	testq	%rsi, %rsi
100019cb7:     	je	0x100019cce <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019cb9:     	movq	0x8(%r8), %rcx
100019cbd:     	movl	0x18(%r8), %edx
100019cc1:     	subq	%rdx, %rcx
100019cc4:     	jbe	0x100019cce <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019cc6:     	movq	%rcx, %rax
100019cc9:     	xorl	%edx, %edx
100019ccb:     	divq	%rsi
100019cce:     	movabsq	$-0x8000000000000000, %rcx ## imm = 0x8000000000000000
100019cd8:     	movq	%rax, %r11
100019cdb:     	xorq	%rcx, %r11
100019cde:     	movq	%r11, %rdx
100019ce1:     	addq	$0x3f, %rdx
100019ce5:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019ceb:     	movabsq	$0x200000000000000, %r12 ## imm = 0x200000000000000
100019cf5:     	shrq	$0x6, %rdx
100019cf9:     	movq	%rdx, %rsi
100019cfc:     	xorq	%r12, %rsi
100019cff:     	andq	$-0x80000000, %rsi      ## imm = 0x80000000
100019d06:     	jne	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019d0c:     	movslq	0x8(%r15), %rsi
100019d10:     	cmpl	%edx, %esi
100019d12:     	jge	0x100019f2e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019d18:     	decq	%r11
100019d1b:     	seto	-0x2a(%rbp)
100019d1f:     	cmpl	$0x0, 0x1c(%r8)
100019d24:     	je	0x100019f2e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019d2a:     	leaq	0x20(%r8), %r10
100019d2e:     	shrq	$0x6, %r11
100019d32:     	xorq	%r11, %r12
100019d35:     	andl	$0x3f, %eax
100019d38:     	movq	%rcx, %r9
100019d3b:     	btcq	%rax, %r9
100019d3f:     	decq	%r9
100019d42:     	setno	-0x40(%rbp)
100019d46:     	xorq	%rcx, %r9
100019d49:     	testq	%rax, %rax
100019d4c:     	movslq	%r11d, %rdi
100019d4f:     	movq	%rdi, -0x98(%rbp)
100019d56:     	movslq	%edx, %rdi
100019d59:     	sete	%dl
100019d5c:     	orb	-0x40(%rbp), %dl
100019d5f:     	movb	%dl, -0x29(%rbp)
100019d62:     	xorl	%edx, %edx
100019d64:     	cmpq	$0x1, %rax
100019d68:     	movq	%rdi, %rax
100019d6b:     	sbbq	%rdx, %rdx
100019d6e:     	orq	%r9, %rdx
100019d71:     	movq	%rdx, -0x80(%rbp)
100019d75:     	andq	$-0x80000000, %r12      ## imm = 0x80000000
100019d7c:     	movq	%r10, -0x48(%rbp)
100019d80:     	movq	%r15, -0x78(%rbp)
100019d84:     	movq	%r13, -0x70(%rbp)
100019d88:     	movq	%r8, -0x68(%rbp)
100019d8c:     	movq	%r12, -0x60(%rbp)
100019d90:     	movq	%rdi, -0x58(%rbp)
100019d94:     	jmp	0x100019dd5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x385>
100019d96:     	movq	-0x90(%rbp), %r9
100019d9d:     	andq	-0x40(%rbp), %r9
100019da1:     	movq	-0x78(%rbp), %r15
100019da5:     	movq	-0x70(%rbp), %r13
100019da9:     	movq	-0x68(%rbp), %r8
100019dad:     	movq	-0x48(%rbp), %r10
100019db1:     	movq	-0x88(%rbp), %rsi
100019db8:     	movq	-0x60(%rbp), %r12
100019dbc:     	movq	-0x58(%rbp), %rax
100019dc0:     	testq	%r9, %r9
100019dc3:     	jne	0x100019eee <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x49e>
100019dc9:     	incq	%rsi
100019dcc:     	cmpq	%rax, %rsi
100019dcf:     	je	0x100019f2e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019dd5:     	cmpl	$0x0, 0x1c(%r8)
100019dda:     	je	0x100019dc9 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x379>
100019ddc:     	movq	(%r10,%rsi,8), %r9
100019de0:     	cmpb	$0x0, -0x2a(%rbp)
100019de4:     	jne	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019dea:     	testq	%r12, %r12
100019ded:     	jne	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019df3:     	notq	%r9
100019df6:     	cmpq	-0x98(%rbp), %rsi
100019dfd:     	jne	0x100019e0d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3bd>
100019dff:     	cmpb	$0x0, -0x29(%rbp)
100019e03:     	je	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019e09:     	andq	-0x80(%rbp), %r9
100019e0d:     	cmpb	$0x1, 0x4310(%rbx)
100019e14:     	jne	0x100019dc0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x370>
100019e16:     	testq	%r9, %r9
100019e19:     	je	0x100019dc0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x370>
100019e1b:     	movl	0x10(%r8), %eax
100019e1f:     	testl	%eax, %eax
100019e21:     	js	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019e27:     	cmpl	$0x27, %eax
100019e2a:     	ja	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019e30:     	testq	%rsi, %rsi
100019e33:     	js	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019e39:     	movl	0x18(%r8), %edx
100019e3d:     	addq	%r8, %rdx
100019e40:     	movq	%rdx, -0xb8(%rbp)
100019e47:     	movq	0x2140(%rbx,%rax,8), %rax
100019e4f:     	movq	%rax, -0xb0(%rbp)
100019e56:     	movq	%rsi, -0x88(%rbp)
100019e5d:     	shlq	$0x6, %rsi
100019e61:     	movq	%rsi, -0xa8(%rbp)
100019e68:     	movq	%r9, -0x40(%rbp)
100019e6c:     	movq	%r9, -0x90(%rbp)
100019e73:     	movq	%r9, %r13
100019e76:     	jmp	0x100019e88 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x438>
100019e78:     	movq	%r15, %rcx
100019e7b:     	leaq	-0x1(%r13), %rax
100019e7f:     	andq	%rax, %r13
100019e82:     	je	0x100019d96 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x346>
100019e88:     	movq	%rcx, %r15
100019e8b:     	bsfq	%r13, %r12
100019e8f:     	movq	%r12, %rsi
100019e92:     	orq	-0xa8(%rbp), %rsi
100019e99:     	imulq	-0xb0(%rbp), %rsi
100019ea1:     	addq	-0xb8(%rbp), %rsi
100019ea8:     	movq	%rbx, %rdi
100019eab:     	callq	0x10001a280 <_*Gcry::Heap#blacklisted_page?<UInt64>:Bool>
100019eb0:     	testb	$0x1, %al
100019eb2:     	je	0x100019e78 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x428>
100019eb4:     	movq	0x4320(%rbx), %rax
100019ebb:     	xorq	%r15, %rax
100019ebe:     	incq	%rax
100019ec1:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019ec7:     	movq	%r15, %rcx
100019eca:     	movq	-0x40(%rbp), %rdx
100019ece:     	btrq	%r12, %rdx
100019ed2:     	movq	%rdx, -0x40(%rbp)
100019ed6:     	xorq	%r15, %rax
100019ed9:     	movq	%rax, 0x4320(%rbx)
100019ee0:     	leaq	-0x1(%r13), %rax
100019ee4:     	andq	%rax, %r13
100019ee7:     	jne	0x100019e88 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x438>
100019ee9:     	jmp	0x100019d96 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x346>
100019eee:     	movl	0x14(%r8), %eax
100019ef2:     	testl	$0x1000, %eax           ## imm = 0x1000
100019ef7:     	jne	0x100019f27 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4d7>
100019ef9:     	movl	%esi, 0x8(%r15)
100019efd:     	testl	%esi, %esi
100019eff:     	js	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019f05:     	movq	%r8, %rdi
100019f08:     	movq	%r15, %r10
100019f0b:     	movq	%rsi, %r8
100019f0e:     	movl	0x18(%rdi), %ecx
100019f11:     	cmpl	$0x0, -0x38(%rbp)
100019f15:     	js	0x100019f42 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4f2>
100019f17:     	movq	-0x38(%rbp), %rax
100019f1b:     	cmpl	$0x27, %eax
100019f1e:     	movl	%eax, %edx
100019f20:     	jbe	0x100019f53 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x503>
100019f22:     	jmp	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019f27:     	incq	0x2e8(%rbx)
100019f2e:     	movq	$0x0, 0x20(%r15)
100019f36:     	leaq	0x298(%rbx), %rax
100019f3d:     	jmp	0x100019a95 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019f42:     	cmpl	$-0x29, -0x38(%rbp)
100019f46:     	jbe	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019f4c:     	movq	-0x38(%rbp), %rax
100019f50:     	leal	0x28(%rax), %edx
100019f53:     	addq	%rdi, %rcx
100019f56:     	movl	%r8d, %eax
100019f59:     	movq	%rax, %rsi
100019f5c:     	shlq	$0x6, %rsi
100019f60:     	movl	%edx, %edx
100019f62:     	imulq	0x2140(%rbx,%rdx,8), %rsi
100019f6b:     	addq	%rcx, %rsi
100019f6e:     	movq	%r10, %rcx
100019f71:     	movq	%rsi, 0x18(%r10)
100019f75:     	movq	%r9, 0x10(%r10)
100019f79:     	cmpb	$0x1, 0x15230(%rbx)
100019f80:     	je	0x100019f94 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x544>
100019f82:     	cmpb	$0x0, 0x15240(%rbx)
100019f89:     	jne	0x100019f94 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x544>
100019f8b:     	cmpb	$0x0, 0x152f3(%rbx)
100019f92:     	je	0x100019fab <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x55b>
100019f94:     	movl	0x1c(%rdi), %ecx
100019f97:     	testq	%rcx, %rcx
100019f9a:     	movq	-0x48(%rbp), %rdx
100019f9e:     	je	0x100019fb5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x565>
100019fa0:     	leaq	(%rdx,%rcx,8), %rcx
100019fa4:     	lock
100019fa5:     	orq	%r9, (%rcx,%rax,8)
100019fa9:     	jmp	0x100019fb7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x567>
100019fab:     	cmpl	$0x0, 0x1c(%rdi)
100019faf:     	movq	-0x48(%rbp), %rdx
100019fb3:     	jne	0x100019fb7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x567>
100019fb5:     	xorl	%edx, %edx
100019fb7:     	lock
100019fb8:     	orq	%r9, (%rdx,%rax,8)
100019fbc:     	incq	0x278(%rbx)
100019fc3:     	movq	%r10, %r15
100019fc6:     	movq	-0x50(%rbp), %rdx
100019fca:     	testq	%r9, %r9
100019fcd:     	movq	-0x38(%rbp), %rcx
100019fd1:     	jne	0x100019c6d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x21d>
100019fd7:     	movq	%r9, %rsi
100019fda:     	movl	$0x40, %r12d
100019fe0:     	movq	0x18(%r15), %rax
100019fe4:     	testl	%ecx, %ecx
100019fe6:     	js	0x100019ff2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5a2>
100019fe8:     	cmpl	$0x27, %ecx
100019feb:     	jbe	0x100019ffe <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5ae>
100019fed:     	jmp	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019ff2:     	cmpl	$-0x29, %ecx
100019ff5:     	jbe	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019ffb:     	addl	$0x28, %ecx
100019ffe:     	movl	%ecx, %ecx
10001a000:     	imulq	0x2140(%rbx,%rcx,8), %r12
10001a009:     	addq	%rax, %r12
10001a00c:     	movq	%r12, 0x20(%r15)
10001a010:     	leaq	-0x1(%rsi), %rax
10001a014:     	andq	%rsi, %rax
10001a017:     	movq	%rax, 0x10(%r15)
10001a01b:     	movq	-0xa0(%rbp), %rax
10001a022:     	movq	%rax, 0x10(%rdx)
10001a026:     	incq	0x20(%rdx)
10001a02a:     	movq	0x1a00(%rbx), %rax
10001a031:     	testq	%rax, %rax
10001a034:     	je	0x10001a03b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5eb>
10001a036:     	prefetcht0	(%rax,%r12)
10001a03b:     	cmpb	$0x1, 0x15240(%rbx)
10001a042:     	je	0x10001a051 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x601>
10001a044:     	cmpb	$0x0, 0x15230(%rbx)
10001a04b:     	je	0x10001a16e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a051:     	cmpb	$0x0, 0x3110(%rbx)
10001a058:     	je	0x10001a108 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b8>
10001a05e:     	movq	%rbx, %rdi
10001a061:     	movq	%r12, %rsi
10001a064:     	callq	0x100011440 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
10001a069:     	testl	%eax, %eax
10001a06b:     	je	0x10001a13c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a071:     	cmpb	$0x1, 0x19e0(%rbx)
10001a078:     	jne	0x10001a13c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a07e:     	movq	%rdx, %rsi
10001a081:     	movl	0x10(%rdx), %ecx
10001a084:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
10001a089:     	cmpq	%rax, %rcx
10001a08c:     	je	0x10001a13c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a092:     	testb	$0x1, 0x14(%rsi)
10001a096:     	jne	0x10001a13c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a09c:     	testl	%ecx, %ecx
10001a09e:     	js	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
10001a0a4:     	movl	0x18(%rsi), %edx
10001a0a7:     	addq	%rsi, %rdx
10001a0aa:     	movq	%r12, %rax
10001a0ad:     	subq	%rdx, %rax
10001a0b0:     	jb	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
10001a0b6:     	cmpl	$0x27, %ecx
10001a0b9:     	ja	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
10001a0bf:     	mulq	0x2280(%rbx,%rcx,8)
10001a0c7:     	jo	0x10001a238 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
10001a0cd:     	movl	0x1c(%rsi), %edx
10001a0d0:     	testq	%rdx, %rdx
10001a0d3:     	je	0x10001a16e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a0d9:     	leaq	(%rsi,%rdx,8), %r8
10001a0dd:     	movq	%rax, %rcx
10001a0e0:     	shrq	$0x28, %rcx
10001a0e4:     	shrq	$0x2e, %rax
10001a0e8:     	movl	$0x1, %r9d
10001a0ee:     	shlq	%cl, %r9
10001a0f1:     	movq	0x20(%r8,%rax,8), %rdi
10001a0f6:     	btq	%rcx, %rdi
10001a0fa:     	jb	0x10001a16e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a0fc:     	leaq	0x20(%rsi,%rdx,8), %rcx
10001a101:     	lock
10001a102:     	orq	%r9, (%rcx,%rax,8)
10001a106:     	jmp	0x10001a16e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a108:     	movzbl	0x207efd(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a10f:     	movl	%eax, %ecx
10001a111:     	movl	0x4(%r12), %eax
10001a116:     	movl	%eax, %edx
10001a118:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a11e:     	movzbl	%cl, %esi
10001a121:     	shll	$0x8, %esi
10001a124:     	orl	%edx, %esi
10001a126:     	lock
10001a127:     	cmpxchgl	%esi, 0x4(%r12)
10001a12d:     	movzbl	0x207ed8(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a134:     	jne	0x10001a10f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6bf>
10001a136:     	cmpb	%al, %cl
10001a138:     	jne	0x10001a10f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6bf>
10001a13a:     	jmp	0x10001a16e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a13c:     	movzbl	0x207ec9(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a143:     	movl	%eax, %ecx
10001a145:     	movl	0x4(%r12), %eax
10001a14a:     	movl	%eax, %edx
10001a14c:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a152:     	movzbl	%cl, %esi
10001a155:     	shll	$0x8, %esi
10001a158:     	orl	%edx, %esi
10001a15a:     	lock
10001a15b:     	cmpxchgl	%esi, 0x4(%r12)
10001a161:     	movzbl	0x207ea4(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a168:     	jne	0x10001a143 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6f3>
10001a16a:     	cmpb	%al, %cl
10001a16c:     	jne	0x10001a143 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6f3>
10001a16e:     	leaq	-0x10(%r13), %rax
10001a172:     	rolq	$0x3c, %rax
10001a176:     	cmpq	$0x3, %rax
10001a17a:     	ja	0x10001a21b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7cb>
10001a180:     	leaq	0xc5(%rip), %rcx        ## 0x10001a24c <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7fc>
10001a187:     	movslq	(%rcx,%rax,4), %rax
10001a18b:     	addq	%rcx, %rax
10001a18e:     	jmpq	*%rax
10001a190:     	movq	$0x0, 0x38(%r12)
10001a199:     	movq	$0x0, 0x30(%r12)
10001a1a2:     	movq	$0x0, 0x28(%r12)
10001a1ab:     	movq	$0x0, 0x20(%r12)
10001a1b4:     	movq	$0x0, 0x18(%r12)
10001a1bd:     	movq	$0x0, 0x10(%r12)
10001a1c6:     	movq	$0x0, 0x8(%r12)
10001a1cf:     	movq	$0x0, (%r12)
10001a1d7:     	movq	$0x0, 0x20(%r15)
10001a1df:     	cmpb	$0x1, 0x20808a(%rip)    ## 0x100222270 <_Gcry::Invariant::enabled>
10001a1e6:     	jne	0x10001a1f0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7a0>
10001a1e8:     	movq	%rbx, %rdi
10001a1eb:     	callq	0x100016f50 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
10001a1f0:     	cmpb	$0x1, 0x20805d(%rip)    ## 0x100222254 <_Gcry::Trace::enabled>
10001a1f7:     	jne	0x10001a206 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7b6>
10001a1f9:     	movq	%r12, %rdi
10001a1fc:     	movq	%r14, %rsi
10001a1ff:     	xorl	%edx, %edx
10001a201:     	callq	0x10001a330 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
10001a206:     	movq	%r12, %rax
10001a209:     	addq	$0x98, %rsp
10001a210:     	popq	%rbx
10001a211:     	popq	%r12
10001a213:     	popq	%r13
10001a215:     	popq	%r14
10001a217:     	popq	%r15
10001a219:     	popq	%rbp
10001a21a:     	retq
10001a21b:     	movq	%r12, %rdi
10001a21e:     	movq	%r13, %rsi
10001a221:     	callq	0x1001c19ec <_write+0x1001c19ec>
10001a226:     	movq	$0x0, 0x20(%r15)
10001a22e:     	testq	%r12, %r12
10001a231:     	jne	0x10001a1df <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x78f>
10001a233:     	jmp	0x100019a98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
10001a238:     	callq	0x100005a40 <___crystal_raise_overflow>
10001a23d:     	callq	0x10000a430 <_*IndexError::new:IndexError>
10001a242:     	movq	%rax, %rdi
10001a245:     	callq	0x10000a480 <_*raise<IndexError>:NoReturn>
10001a24a:     	nop
10001a24c:     	jp	0x10001a24d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7fd>
10001a24e:     	<unknown>
10001a250:     	pushq	$0x56ffffff             ## imm = 0x56FFFFFF
10001a255:     	<unknown>
10001a257:     	incl	-0x1(%rdi,%rdi,8)
10001a25b:     	decl	(%rdi)
10001a25d:     	<unknown>
10001a25e:     	addb	%dl, 0x48(%rbp)
