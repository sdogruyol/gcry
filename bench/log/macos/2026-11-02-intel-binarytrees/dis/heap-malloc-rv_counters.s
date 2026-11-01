
bin/ab-rv_counters:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

0000000100019b00 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
100019b00:     	pushq	%rbp
100019b01:     	movq	%rsp, %rbp
100019b04:     	pushq	%r15
100019b06:     	pushq	%r14
100019b08:     	pushq	%r13
100019b0a:     	pushq	%r12
100019b0c:     	pushq	%rbx
100019b0d:     	subq	$0x98, %rsp
100019b14:     	movq	%rsi, %r14
100019b17:     	movq	%rdi, %rbx
100019b1a:     	cmpb	$0x1, 0x150bc(%rdi)
100019b21:     	jne	0x100019b48 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
100019b23:     	cmpb	$0x1, 0x15230(%rbx)
100019b2a:     	je	0x100019b3e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
100019b2c:     	cmpb	$0x0, 0x15240(%rbx)
100019b33:     	jne	0x100019b3e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
100019b35:     	cmpb	$0x0, 0x152f3(%rbx)
100019b3c:     	je	0x100019b6b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b>
100019b3e:     	leaq	0x280(%rbx), %rax
100019b45:     	incq	(%rax)
100019b48:     	movq	%rbx, %rdi
100019b4b:     	movq	%r14, %rsi
100019b4e:     	xorl	%edx, %edx
100019b50:     	movl	$0x1, %ecx
100019b55:     	addq	$0x98, %rsp
100019b5c:     	popq	%rbx
100019b5d:     	popq	%r12
100019b5f:     	popq	%r13
100019b61:     	popq	%r14
100019b63:     	popq	%r15
100019b65:     	popq	%rbp
100019b66:     	jmp	0x10001ad10 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
100019b6b:     	cmpq	$0x8000, %r14           ## imm = 0x8000
100019b72:     	jbe	0x100019b7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7d>
100019b74:     	leaq	0x288(%rbx), %rax
100019b7b:     	jmp	0x100019b45 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019b7d:     	movq	0x14f58(%rbx), %rax
100019b84:     	testq	%rax, %rax
100019b87:     	je	0x100019b97 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x97>
100019b89:     	decq	%rax
100019b8c:     	movq	%gs:(,%rax,8), %rdx
100019b95:     	jmp	0x100019bb6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
100019b97:     	leaq	-0xc0(%rbp), %rdi
100019b9e:     	callq	0x100014fc0 <_*Gcry::Heap::tls_cursor_cache>
100019ba3:     	movq	-0xc0(%rbp), %rax
100019baa:     	movq	0x8(%rax), %rcx
100019bae:     	xorq	%rbx, %rcx
100019bb1:     	jne	0x100019bc1 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019bb3:     	movq	(%rax), %rdx
100019bb6:     	testq	%rdx, %rdx
100019bb9:     	je	0x100019bc1 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019bbb:     	cmpb	$0x0, 0x9(%rdx)
100019bbf:     	je	0x100019bcd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xcd>
100019bc1:     	leaq	0x290(%rbx), %rax
100019bc8:     	jmp	0x100019b45 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019bcd:     	cmpq	$0x801, %r14            ## imm = 0x801
100019bd4:     	jae	0x100019bf2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xf2>
100019bd6:     	leaq	0x7(%r14), %rcx
100019bda:     	shrq	$0x3, %rcx
100019bde:     	movl	0x32ac(%rbx,%rcx,4), %eax
100019be5:     	movzbl	0x31a8(%rbx,%rcx), %esi
100019bed:     	jmp	0x100019c9a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x19a>
100019bf2:     	movl	$0xc, %r15d
100019bf8:     	cmpq	$0x4000, %r14           ## imm = 0x4000
100019bff:     	ja	0x100019c21 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x121>
100019c01:     	movl	$0xb, %r15d
100019c07:     	cmpq	$0x2001, %r14           ## imm = 0x2001
100019c0e:     	jae	0x100019c21 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x121>
100019c10:     	cmpq	$0x1001, %r14           ## imm = 0x1001
100019c17:     	movl	$0x9, %r15d
100019c1d:     	sbbl	$-0x1, %r15d
100019c21:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019c2b:     	movq	%r14, %rdi
100019c2e:     	xorq	%r12, %rdi
100019c31:     	decq	%rdi
100019c34:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c3a:     	movq	%rdx, %r13
100019c3d:     	xorq	%r12, %rdi
100019c40:     	movl	%r15d, %esi
100019c43:     	callq	0x1000096d0 <_*UInt64@Int#>><Int32>:UInt64>
100019c48:     	xorq	%r12, %rax
100019c4b:     	incq	%rax
100019c4e:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c54:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019c5e:     	cmpq	%rcx, %rax
100019c61:     	jge	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c67:     	testl	%eax, %eax
100019c69:     	js	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c6f:     	leal	-0xd(,%r15,4), %r12d
100019c77:     	addl	%eax, %r12d
100019c7a:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c80:     	addl	$-0x4, %r12d
100019c84:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019c8a:     	movl	%eax, %edi
100019c8c:     	movl	%r15d, %esi
100019c8f:     	callq	0x10000a9d0 <_*UInt32@Int#<<<Int32>:UInt32>
100019c94:     	movq	%r13, %rdx
100019c97:     	movq	%r12, %rsi
100019c9a:     	movslq	%esi, %rcx
100019c9d:     	leaq	(%rcx,%rcx,4), %rcx
100019ca1:     	leaq	0x30(%rdx,%rcx,8), %r15
100019ca6:     	cmpq	$0x0, 0x40(%rdx,%rcx,8)
100019cac:     	jne	0x100019cb8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1b8>
100019cae:     	cmpq	$0x0, (%r15)
100019cb2:     	je	0x100019d4e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x24e>
100019cb8:     	movq	%rsi, -0x38(%rbp)
100019cbc:     	movl	%eax, %r13d
100019cbf:     	movq	0x10(%rdx), %rsi
100019cc3:     	addq	%r13, %rsi
100019cc6:     	movq	%rsi, -0xa0(%rbp)
100019ccd:     	subq	0x18(%rdx), %rsi
100019cd1:     	addq	0x14fa0(%rbx), %rsi
100019cd8:     	movq	0x3860(%rbx), %rdi
100019cdf:     	cmpq	%rdi, %rsi
100019ce2:     	jb	0x100019cff <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ff>
100019ce4:     	movq	%rdx, %r12
100019ce7:     	callq	0x10001a310 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019cec:     	movq	%r12, %rdx
100019cef:     	testb	$0x1, %al
100019cf1:     	je	0x100019cff <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ff>
100019cf3:     	leaq	0x2a0(%rbx), %rax
100019cfa:     	jmp	0x100019b45 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019cff:     	movq	$0x8, 0x20(%r15)
100019d07:     	movq	0x10(%r15), %r9
100019d0b:     	testq	%r9, %r9
100019d0e:     	je	0x100019d29 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x229>
100019d10:     	testq	%r9, %r9
100019d13:     	movq	-0x38(%rbp), %rcx
100019d17:     	je	0x10001a087 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x587>
100019d1d:     	movq	%r9, %rsi
100019d20:     	bsfq	%r9, %r12
100019d24:     	jmp	0x10001a090 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x590>
100019d29:     	movq	%rdx, -0x50(%rbp)
100019d2d:     	movq	(%r15), %r8
100019d30:     	testq	%r8, %r8
100019d33:     	je	0x100019fde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019d39:     	movl	0x10(%r8), %eax
100019d3d:     	testl	%eax, %eax
100019d3f:     	js	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019d45:     	cmpl	$0x27, %eax
100019d48:     	jbe	0x100019d5a <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x25a>
100019d4a:     	xorl	%eax, %eax
100019d4c:     	jmp	0x100019d7e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019d4e:     	leaq	0x298(%rbx), %rax
100019d55:     	jmp	0x100019b45 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019d5a:     	movq	0x2140(%rbx,%rax,8), %rsi
100019d62:     	xorl	%eax, %eax
100019d64:     	testq	%rsi, %rsi
100019d67:     	je	0x100019d7e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019d69:     	movq	0x8(%r8), %rcx
100019d6d:     	movl	0x18(%r8), %edx
100019d71:     	subq	%rdx, %rcx
100019d74:     	jbe	0x100019d7e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019d76:     	movq	%rcx, %rax
100019d79:     	xorl	%edx, %edx
100019d7b:     	divq	%rsi
100019d7e:     	movabsq	$-0x8000000000000000, %rcx ## imm = 0x8000000000000000
100019d88:     	movq	%rax, %r11
100019d8b:     	xorq	%rcx, %r11
100019d8e:     	movq	%r11, %rdx
100019d91:     	addq	$0x3f, %rdx
100019d95:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019d9b:     	movabsq	$0x200000000000000, %r12 ## imm = 0x200000000000000
100019da5:     	shrq	$0x6, %rdx
100019da9:     	movq	%rdx, %rsi
100019dac:     	xorq	%r12, %rsi
100019daf:     	andq	$-0x80000000, %rsi      ## imm = 0x80000000
100019db6:     	jne	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019dbc:     	movslq	0x8(%r15), %rsi
100019dc0:     	cmpl	%edx, %esi
100019dc2:     	jge	0x100019fde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019dc8:     	decq	%r11
100019dcb:     	seto	-0x2a(%rbp)
100019dcf:     	cmpl	$0x0, 0x1c(%r8)
100019dd4:     	je	0x100019fde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019dda:     	leaq	0x20(%r8), %r10
100019dde:     	shrq	$0x6, %r11
100019de2:     	xorq	%r11, %r12
100019de5:     	andl	$0x3f, %eax
100019de8:     	movq	%rcx, %r9
100019deb:     	btcq	%rax, %r9
100019def:     	decq	%r9
100019df2:     	setno	-0x40(%rbp)
100019df6:     	xorq	%rcx, %r9
100019df9:     	testq	%rax, %rax
100019dfc:     	movslq	%r11d, %rdi
100019dff:     	movq	%rdi, -0x98(%rbp)
100019e06:     	movslq	%edx, %rdi
100019e09:     	sete	%dl
100019e0c:     	orb	-0x40(%rbp), %dl
100019e0f:     	movb	%dl, -0x29(%rbp)
100019e12:     	xorl	%edx, %edx
100019e14:     	cmpq	$0x1, %rax
100019e18:     	movq	%rdi, %rax
100019e1b:     	sbbq	%rdx, %rdx
100019e1e:     	orq	%r9, %rdx
100019e21:     	movq	%rdx, -0x80(%rbp)
100019e25:     	andq	$-0x80000000, %r12      ## imm = 0x80000000
100019e2c:     	movq	%r10, -0x48(%rbp)
100019e30:     	movq	%r15, -0x78(%rbp)
100019e34:     	movq	%r13, -0x70(%rbp)
100019e38:     	movq	%r8, -0x68(%rbp)
100019e3c:     	movq	%r12, -0x60(%rbp)
100019e40:     	movq	%rdi, -0x58(%rbp)
100019e44:     	jmp	0x100019e85 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x385>
100019e46:     	movq	-0x90(%rbp), %r9
100019e4d:     	andq	-0x40(%rbp), %r9
100019e51:     	movq	-0x78(%rbp), %r15
100019e55:     	movq	-0x70(%rbp), %r13
100019e59:     	movq	-0x68(%rbp), %r8
100019e5d:     	movq	-0x48(%rbp), %r10
100019e61:     	movq	-0x88(%rbp), %rsi
100019e68:     	movq	-0x60(%rbp), %r12
100019e6c:     	movq	-0x58(%rbp), %rax
100019e70:     	testq	%r9, %r9
100019e73:     	jne	0x100019f9e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x49e>
100019e79:     	incq	%rsi
100019e7c:     	cmpq	%rax, %rsi
100019e7f:     	je	0x100019fde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4de>
100019e85:     	cmpl	$0x0, 0x1c(%r8)
100019e8a:     	je	0x100019e79 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x379>
100019e8c:     	movq	(%r10,%rsi,8), %r9
100019e90:     	cmpb	$0x0, -0x2a(%rbp)
100019e94:     	jne	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019e9a:     	testq	%r12, %r12
100019e9d:     	jne	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019ea3:     	notq	%r9
100019ea6:     	cmpq	-0x98(%rbp), %rsi
100019ead:     	jne	0x100019ebd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3bd>
100019eaf:     	cmpb	$0x0, -0x29(%rbp)
100019eb3:     	je	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019eb9:     	andq	-0x80(%rbp), %r9
100019ebd:     	cmpb	$0x1, 0x4310(%rbx)
100019ec4:     	jne	0x100019e70 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x370>
100019ec6:     	testq	%r9, %r9
100019ec9:     	je	0x100019e70 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x370>
100019ecb:     	movl	0x10(%r8), %eax
100019ecf:     	testl	%eax, %eax
100019ed1:     	js	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019ed7:     	cmpl	$0x27, %eax
100019eda:     	ja	0x10001a2ed <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019ee0:     	testq	%rsi, %rsi
100019ee3:     	js	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019ee9:     	movl	0x18(%r8), %edx
100019eed:     	addq	%r8, %rdx
100019ef0:     	movq	%rdx, -0xb8(%rbp)
100019ef7:     	movq	0x2140(%rbx,%rax,8), %rax
100019eff:     	movq	%rax, -0xb0(%rbp)
100019f06:     	movq	%rsi, -0x88(%rbp)
100019f0d:     	shlq	$0x6, %rsi
100019f11:     	movq	%rsi, -0xa8(%rbp)
100019f18:     	movq	%r9, -0x40(%rbp)
100019f1c:     	movq	%r9, -0x90(%rbp)
100019f23:     	movq	%r9, %r13
100019f26:     	jmp	0x100019f38 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x438>
100019f28:     	movq	%r15, %rcx
100019f2b:     	leaq	-0x1(%r13), %rax
100019f2f:     	andq	%rax, %r13
100019f32:     	je	0x100019e46 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x346>
100019f38:     	movq	%rcx, %r15
100019f3b:     	bsfq	%r13, %r12
100019f3f:     	movq	%r12, %rsi
100019f42:     	orq	-0xa8(%rbp), %rsi
100019f49:     	imulq	-0xb0(%rbp), %rsi
100019f51:     	addq	-0xb8(%rbp), %rsi
100019f58:     	movq	%rbx, %rdi
100019f5b:     	callq	0x10001a330 <_*Gcry::Heap#blacklisted_page?<UInt64>:Bool>
100019f60:     	testb	$0x1, %al
100019f62:     	je	0x100019f28 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x428>
100019f64:     	movq	0x4320(%rbx), %rax
100019f6b:     	xorq	%r15, %rax
100019f6e:     	incq	%rax
100019f71:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019f77:     	movq	%r15, %rcx
100019f7a:     	movq	-0x40(%rbp), %rdx
100019f7e:     	btrq	%r12, %rdx
100019f82:     	movq	%rdx, -0x40(%rbp)
100019f86:     	xorq	%r15, %rax
100019f89:     	movq	%rax, 0x4320(%rbx)
100019f90:     	leaq	-0x1(%r13), %rax
100019f94:     	andq	%rax, %r13
100019f97:     	jne	0x100019f38 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x438>
100019f99:     	jmp	0x100019e46 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x346>
100019f9e:     	movl	0x14(%r8), %eax
100019fa2:     	testl	$0x1000, %eax           ## imm = 0x1000
100019fa7:     	jne	0x100019fd7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4d7>
100019fa9:     	movl	%esi, 0x8(%r15)
100019fad:     	testl	%esi, %esi
100019faf:     	js	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
100019fb5:     	movq	%r8, %rdi
100019fb8:     	movq	%r15, %r10
100019fbb:     	movq	%rsi, %r8
100019fbe:     	movl	0x18(%rdi), %ecx
100019fc1:     	cmpl	$0x0, -0x38(%rbp)
100019fc5:     	js	0x100019ff2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4f2>
100019fc7:     	movq	-0x38(%rbp), %rax
100019fcb:     	cmpl	$0x27, %eax
100019fce:     	movl	%eax, %edx
100019fd0:     	jbe	0x10001a003 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x503>
100019fd2:     	jmp	0x10001a2ed <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019fd7:     	incq	0x2e8(%rbx)
100019fde:     	movq	$0x0, 0x20(%r15)
100019fe6:     	leaq	0x298(%rbx), %rax
100019fed:     	jmp	0x100019b45 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019ff2:     	cmpl	$-0x29, -0x38(%rbp)
100019ff6:     	jbe	0x10001a2ed <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
100019ffc:     	movq	-0x38(%rbp), %rax
10001a000:     	leal	0x28(%rax), %edx
10001a003:     	addq	%rdi, %rcx
10001a006:     	movl	%r8d, %eax
10001a009:     	movq	%rax, %rsi
10001a00c:     	shlq	$0x6, %rsi
10001a010:     	movl	%edx, %edx
10001a012:     	imulq	0x2140(%rbx,%rdx,8), %rsi
10001a01b:     	addq	%rcx, %rsi
10001a01e:     	movq	%r10, %rcx
10001a021:     	movq	%rsi, 0x18(%r10)
10001a025:     	movq	%r9, 0x10(%r10)
10001a029:     	cmpb	$0x1, 0x15230(%rbx)
10001a030:     	je	0x10001a044 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x544>
10001a032:     	cmpb	$0x0, 0x15240(%rbx)
10001a039:     	jne	0x10001a044 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x544>
10001a03b:     	cmpb	$0x0, 0x152f3(%rbx)
10001a042:     	je	0x10001a05b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x55b>
10001a044:     	movl	0x1c(%rdi), %ecx
10001a047:     	testq	%rcx, %rcx
10001a04a:     	movq	-0x48(%rbp), %rdx
10001a04e:     	je	0x10001a065 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x565>
10001a050:     	leaq	(%rdx,%rcx,8), %rcx
10001a054:     	lock
10001a055:     	orq	%r9, (%rcx,%rax,8)
10001a059:     	jmp	0x10001a067 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x567>
10001a05b:     	cmpl	$0x0, 0x1c(%rdi)
10001a05f:     	movq	-0x48(%rbp), %rdx
10001a063:     	jne	0x10001a067 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x567>
10001a065:     	xorl	%edx, %edx
10001a067:     	lock
10001a068:     	orq	%r9, (%rdx,%rax,8)
10001a06c:     	incq	0x278(%rbx)
10001a073:     	movq	%r10, %r15
10001a076:     	movq	-0x50(%rbp), %rdx
10001a07a:     	testq	%r9, %r9
10001a07d:     	movq	-0x38(%rbp), %rcx
10001a081:     	jne	0x100019d1d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x21d>
10001a087:     	movq	%r9, %rsi
10001a08a:     	movl	$0x40, %r12d
10001a090:     	movq	0x18(%r15), %rax
10001a094:     	testl	%ecx, %ecx
10001a096:     	js	0x10001a0a2 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5a2>
10001a098:     	cmpl	$0x27, %ecx
10001a09b:     	jbe	0x10001a0ae <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5ae>
10001a09d:     	jmp	0x10001a2ed <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
10001a0a2:     	cmpl	$-0x29, %ecx
10001a0a5:     	jbe	0x10001a2ed <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
10001a0ab:     	addl	$0x28, %ecx
10001a0ae:     	movl	%ecx, %ecx
10001a0b0:     	imulq	0x2140(%rbx,%rcx,8), %r12
10001a0b9:     	addq	%rax, %r12
10001a0bc:     	movq	%r12, 0x20(%r15)
10001a0c0:     	leaq	-0x1(%rsi), %rax
10001a0c4:     	andq	%rsi, %rax
10001a0c7:     	movq	%rax, 0x10(%r15)
10001a0cb:     	movq	-0xa0(%rbp), %rax
10001a0d2:     	movq	%rax, 0x10(%rdx)
10001a0d6:     	incq	0x20(%rdx)
10001a0da:     	movq	0x1a00(%rbx), %rax
10001a0e1:     	testq	%rax, %rax
10001a0e4:     	je	0x10001a0eb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5eb>
10001a0e6:     	prefetcht0	(%rax,%r12)
10001a0eb:     	cmpb	$0x1, 0x15240(%rbx)
10001a0f2:     	je	0x10001a101 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x601>
10001a0f4:     	cmpb	$0x0, 0x15230(%rbx)
10001a0fb:     	je	0x10001a21e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a101:     	cmpb	$0x0, 0x3110(%rbx)
10001a108:     	je	0x10001a1b8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b8>
10001a10e:     	movq	%rbx, %rdi
10001a111:     	movq	%r12, %rsi
10001a114:     	callq	0x100011450 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
10001a119:     	testl	%eax, %eax
10001a11b:     	je	0x10001a1ec <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a121:     	cmpb	$0x1, 0x19e0(%rbx)
10001a128:     	jne	0x10001a1ec <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a12e:     	movq	%rdx, %rsi
10001a131:     	movl	0x10(%rdx), %ecx
10001a134:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
10001a139:     	cmpq	%rax, %rcx
10001a13c:     	je	0x10001a1ec <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a142:     	testb	$0x1, 0x14(%rsi)
10001a146:     	jne	0x10001a1ec <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ec>
10001a14c:     	testl	%ecx, %ecx
10001a14e:     	js	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
10001a154:     	movl	0x18(%rsi), %edx
10001a157:     	addq	%rsi, %rdx
10001a15a:     	movq	%r12, %rax
10001a15d:     	subq	%rdx, %rax
10001a160:     	jb	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
10001a166:     	cmpl	$0x27, %ecx
10001a169:     	ja	0x10001a2ed <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ed>
10001a16f:     	mulq	0x2280(%rbx,%rcx,8)
10001a177:     	jo	0x10001a2e8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e8>
10001a17d:     	movl	0x1c(%rsi), %edx
10001a180:     	testq	%rdx, %rdx
10001a183:     	je	0x10001a21e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a189:     	leaq	(%rsi,%rdx,8), %r8
10001a18d:     	movq	%rax, %rcx
10001a190:     	shrq	$0x28, %rcx
10001a194:     	shrq	$0x2e, %rax
10001a198:     	movl	$0x1, %r9d
10001a19e:     	shlq	%cl, %r9
10001a1a1:     	movq	0x20(%r8,%rax,8), %rdi
10001a1a6:     	btq	%rcx, %rdi
10001a1aa:     	jb	0x10001a21e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a1ac:     	leaq	0x20(%rsi,%rdx,8), %rcx
10001a1b1:     	lock
10001a1b2:     	orq	%r9, (%rcx,%rax,8)
10001a1b6:     	jmp	0x10001a21e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a1b8:     	movzbl	0x207e4d(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a1bf:     	movl	%eax, %ecx
10001a1c1:     	movl	0x4(%r12), %eax
10001a1c6:     	movl	%eax, %edx
10001a1c8:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a1ce:     	movzbl	%cl, %esi
10001a1d1:     	shll	$0x8, %esi
10001a1d4:     	orl	%edx, %esi
10001a1d6:     	lock
10001a1d7:     	cmpxchgl	%esi, 0x4(%r12)
10001a1dd:     	movzbl	0x207e28(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a1e4:     	jne	0x10001a1bf <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6bf>
10001a1e6:     	cmpb	%al, %cl
10001a1e8:     	jne	0x10001a1bf <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6bf>
10001a1ea:     	jmp	0x10001a21e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x71e>
10001a1ec:     	movzbl	0x207e19(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a1f3:     	movl	%eax, %ecx
10001a1f5:     	movl	0x4(%r12), %eax
10001a1fa:     	movl	%eax, %edx
10001a1fc:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a202:     	movzbl	%cl, %esi
10001a205:     	shll	$0x8, %esi
10001a208:     	orl	%edx, %esi
10001a20a:     	lock
10001a20b:     	cmpxchgl	%esi, 0x4(%r12)
10001a211:     	movzbl	0x207df4(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a218:     	jne	0x10001a1f3 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6f3>
10001a21a:     	cmpb	%al, %cl
10001a21c:     	jne	0x10001a1f3 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6f3>
10001a21e:     	leaq	-0x10(%r13), %rax
10001a222:     	rolq	$0x3c, %rax
10001a226:     	cmpq	$0x3, %rax
10001a22a:     	ja	0x10001a2cb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7cb>
10001a230:     	leaq	0xc5(%rip), %rcx        ## 0x10001a2fc <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7fc>
10001a237:     	movslq	(%rcx,%rax,4), %rax
10001a23b:     	addq	%rcx, %rax
10001a23e:     	jmpq	*%rax
10001a240:     	movq	$0x0, 0x38(%r12)
10001a249:     	movq	$0x0, 0x30(%r12)
10001a252:     	movq	$0x0, 0x28(%r12)
10001a25b:     	movq	$0x0, 0x20(%r12)
10001a264:     	movq	$0x0, 0x18(%r12)
10001a26d:     	movq	$0x0, 0x10(%r12)
10001a276:     	movq	$0x0, 0x8(%r12)
10001a27f:     	movq	$0x0, (%r12)
10001a287:     	movq	$0x0, 0x20(%r15)
10001a28f:     	cmpb	$0x1, 0x207fda(%rip)    ## 0x100222270 <_Gcry::Invariant::enabled>
10001a296:     	jne	0x10001a2a0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7a0>
10001a298:     	movq	%rbx, %rdi
10001a29b:     	callq	0x100017000 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
10001a2a0:     	cmpb	$0x1, 0x207fad(%rip)    ## 0x100222254 <_Gcry::Trace::enabled>
10001a2a7:     	jne	0x10001a2b6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7b6>
10001a2a9:     	movq	%r12, %rdi
10001a2ac:     	movq	%r14, %rsi
10001a2af:     	xorl	%edx, %edx
10001a2b1:     	callq	0x10001a3e0 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
10001a2b6:     	movq	%r12, %rax
10001a2b9:     	addq	$0x98, %rsp
10001a2c0:     	popq	%rbx
10001a2c1:     	popq	%r12
10001a2c3:     	popq	%r13
10001a2c5:     	popq	%r14
10001a2c7:     	popq	%r15
10001a2c9:     	popq	%rbp
10001a2ca:     	retq
10001a2cb:     	movq	%r12, %rdi
10001a2ce:     	movq	%r13, %rsi
10001a2d1:     	callq	0x1001c158c <_write+0x1001c158c>
10001a2d6:     	movq	$0x0, 0x20(%r15)
10001a2de:     	testq	%r12, %r12
10001a2e1:     	jne	0x10001a28f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x78f>
10001a2e3:     	jmp	0x100019b48 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
10001a2e8:     	callq	0x100005a40 <___crystal_raise_overflow>
10001a2ed:     	callq	0x10000a430 <_*IndexError::new:IndexError>
10001a2f2:     	movq	%rax, %rdi
10001a2f5:     	callq	0x10000a480 <_*raise<IndexError>:NoReturn>
10001a2fa:     	nop
10001a2fc:     	jp	0x10001a2fd <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7fd>
10001a2fe:     	<unknown>
10001a300:     	pushq	$0x56ffffff             ## imm = 0x56FFFFFF
10001a305:     	<unknown>
10001a307:     	incl	-0x1(%rdi,%rdi,8)
10001a30b:     	decl	(%rdi)
10001a30d:     	<unknown>
10001a30e:     	addb	%dl, 0x48(%rbp)
