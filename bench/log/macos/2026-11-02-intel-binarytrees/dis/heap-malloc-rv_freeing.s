
bin/ab-rv_freeing:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

0000000100019a60 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)>:
100019a60:     	pushq	%rbp
100019a61:     	movq	%rsp, %rbp
100019a64:     	pushq	%r15
100019a66:     	pushq	%r14
100019a68:     	pushq	%r13
100019a6a:     	pushq	%r12
100019a6c:     	pushq	%rbx
100019a6d:     	subq	$0x98, %rsp
100019a74:     	movq	%rsi, %r14
100019a77:     	movq	%rdi, %rbx
100019a7a:     	cmpb	$0x1, 0x1509c(%rdi)
100019a81:     	jne	0x100019aa8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
100019a83:     	cmpb	$0x1, 0x15210(%rbx)
100019a8a:     	je	0x100019a9e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
100019a8c:     	cmpb	$0x0, 0x15220(%rbx)
100019a93:     	jne	0x100019a9e <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3e>
100019a95:     	cmpb	$0x0, 0x152d3(%rbx)
100019a9c:     	je	0x100019acb <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b>
100019a9e:     	leaq	0x280(%rbx), %rax
100019aa5:     	incq	(%rax)
100019aa8:     	movq	%rbx, %rdi
100019aab:     	movq	%r14, %rsi
100019aae:     	xorl	%edx, %edx
100019ab0:     	movl	$0x1, %ecx
100019ab5:     	addq	$0x98, %rsp
100019abc:     	popq	%rbx
100019abd:     	popq	%r12
100019abf:     	popq	%r13
100019ac1:     	popq	%r14
100019ac3:     	popq	%r15
100019ac5:     	popq	%rbp
100019ac6:     	jmp	0x10001ac60 <_*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
100019acb:     	cmpq	$0x8000, %r14           ## imm = 0x8000
100019ad2:     	jbe	0x100019add <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7d>
100019ad4:     	leaq	0x288(%rbx), %rax
100019adb:     	jmp	0x100019aa5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019add:     	movq	0x14f38(%rbx), %rax
100019ae4:     	testq	%rax, %rax
100019ae7:     	je	0x100019af7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x97>
100019ae9:     	decq	%rax
100019aec:     	movq	%gs:(,%rax,8), %rdx
100019af5:     	jmp	0x100019b16 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xb6>
100019af7:     	leaq	-0xc0(%rbp), %rdi
100019afe:     	callq	0x100015820 <_*Gcry::Heap::tls_cursor_cache>
100019b03:     	movq	-0xc0(%rbp), %rax
100019b0a:     	movq	0x8(%rax), %rcx
100019b0e:     	xorq	%rbx, %rcx
100019b11:     	jne	0x100019b21 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019b13:     	movq	(%rax), %rdx
100019b16:     	testq	%rdx, %rdx
100019b19:     	je	0x100019b21 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xc1>
100019b1b:     	cmpb	$0x0, 0x9(%rdx)
100019b1f:     	je	0x100019b2d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xcd>
100019b21:     	leaq	0x290(%rbx), %rax
100019b28:     	jmp	0x100019aa5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019b2d:     	cmpq	$0x801, %r14            ## imm = 0x801
100019b34:     	jae	0x100019b52 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0xf2>
100019b36:     	leaq	0x7(%r14), %rcx
100019b3a:     	shrq	$0x3, %rcx
100019b3e:     	movl	0x328c(%rbx,%rcx,4), %eax
100019b45:     	movzbl	0x3188(%rbx,%rcx), %esi
100019b4d:     	jmp	0x100019bfa <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x19a>
100019b52:     	movl	$0xc, %r15d
100019b58:     	cmpq	$0x4000, %r14           ## imm = 0x4000
100019b5f:     	ja	0x100019b81 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x121>
100019b61:     	movl	$0xb, %r15d
100019b67:     	cmpq	$0x2001, %r14           ## imm = 0x2001
100019b6e:     	jae	0x100019b81 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x121>
100019b70:     	cmpq	$0x1001, %r14           ## imm = 0x1001
100019b77:     	movl	$0x9, %r15d
100019b7d:     	sbbl	$-0x1, %r15d
100019b81:     	movabsq	$-0x8000000000000000, %r12 ## imm = 0x8000000000000000
100019b8b:     	movq	%r14, %rdi
100019b8e:     	xorq	%r12, %rdi
100019b91:     	decq	%rdi
100019b94:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019b9a:     	movq	%rdx, %r13
100019b9d:     	xorq	%r12, %rdi
100019ba0:     	movl	%r15d, %esi
100019ba3:     	callq	0x100009680 <_*UInt64@Int#>><Int32>:UInt64>
100019ba8:     	xorq	%r12, %rax
100019bab:     	incq	%rax
100019bae:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019bb4:     	movabsq	$-0x7fffffff00000000, %rcx ## imm = 0x8000000100000000
100019bbe:     	cmpq	%rcx, %rax
100019bc1:     	jge	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019bc7:     	testl	%eax, %eax
100019bc9:     	js	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019bcf:     	leal	-0xd(,%r15,4), %r12d
100019bd7:     	addl	%eax, %r12d
100019bda:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019be0:     	addl	$-0x4, %r12d
100019be4:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019bea:     	movl	%eax, %edi
100019bec:     	movl	%r15d, %esi
100019bef:     	callq	0x10000a980 <_*UInt32@Int#<<<Int32>:UInt32>
100019bf4:     	movq	%r13, %rdx
100019bf7:     	movq	%r12, %rsi
100019bfa:     	movslq	%esi, %rcx
100019bfd:     	leaq	(%rcx,%rcx,4), %rcx
100019c01:     	leaq	0x30(%rdx,%rcx,8), %r15
100019c06:     	cmpq	$0x0, 0x40(%rdx,%rcx,8)
100019c0c:     	jne	0x100019c18 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1b8>
100019c0e:     	cmpq	$0x0, (%r15)
100019c12:     	je	0x100019cae <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x24e>
100019c18:     	movq	%rsi, -0x40(%rbp)
100019c1c:     	movl	%eax, %r13d
100019c1f:     	movq	0x10(%rdx), %rsi
100019c23:     	addq	%r13, %rsi
100019c26:     	movq	%rsi, -0xa0(%rbp)
100019c2d:     	subq	0x18(%rdx), %rsi
100019c31:     	addq	0x14f80(%rbx), %rsi
100019c38:     	movq	0x3840(%rbx), %rdi
100019c3f:     	cmpq	%rdi, %rsi
100019c42:     	jb	0x100019c5f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ff>
100019c44:     	movq	%rdx, %r12
100019c47:     	callq	0x10001a260 <_*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
100019c4c:     	movq	%r12, %rdx
100019c4f:     	testb	$0x1, %al
100019c51:     	je	0x100019c5f <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x1ff>
100019c53:     	leaq	0x2a0(%rbx), %rax
100019c5a:     	jmp	0x100019aa5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019c5f:     	movq	$0x8, 0x20(%r15)
100019c67:     	movq	0x10(%r15), %rsi
100019c6b:     	testq	%rsi, %rsi
100019c6e:     	je	0x100019c89 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x229>
100019c70:     	testq	%rsi, %rsi
100019c73:     	movq	-0x40(%rbp), %rcx
100019c77:     	je	0x100019fdc <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x57c>
100019c7d:     	movq	%rsi, %rdi
100019c80:     	bsfq	%rsi, %r12
100019c84:     	jmp	0x100019fe5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x585>
100019c89:     	movq	%rdx, -0x50(%rbp)
100019c8d:     	movq	(%r15), %r11
100019c90:     	testq	%r11, %r11
100019c93:     	je	0x100019efe <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x49e>
100019c99:     	movl	0x10(%r11), %eax
100019c9d:     	testl	%eax, %eax
100019c9f:     	js	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019ca5:     	cmpl	$0x27, %eax
100019ca8:     	jbe	0x100019cba <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x25a>
100019caa:     	xorl	%eax, %eax
100019cac:     	jmp	0x100019cde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019cae:     	leaq	0x298(%rbx), %rax
100019cb5:     	jmp	0x100019aa5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019cba:     	movq	0x2120(%rbx,%rax,8), %rsi
100019cc2:     	xorl	%eax, %eax
100019cc4:     	testq	%rsi, %rsi
100019cc7:     	je	0x100019cde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019cc9:     	movq	0x8(%r11), %rcx
100019ccd:     	movl	0x18(%r11), %edx
100019cd1:     	subq	%rdx, %rcx
100019cd4:     	jbe	0x100019cde <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x27e>
100019cd6:     	movq	%rcx, %rax
100019cd9:     	xorl	%edx, %edx
100019cdb:     	divq	%rsi
100019cde:     	movabsq	$-0x8000000000000000, %rdi ## imm = 0x8000000000000000
100019ce8:     	movq	%rax, %rcx
100019ceb:     	xorq	%rdi, %rcx
100019cee:     	movq	%rcx, %rdx
100019cf1:     	addq	$0x3f, %rdx
100019cf5:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019cfb:     	movabsq	$0x200000000000000, %r12 ## imm = 0x200000000000000
100019d05:     	shrq	$0x6, %rdx
100019d09:     	movq	%rdx, %rsi
100019d0c:     	xorq	%r12, %rsi
100019d0f:     	andq	$-0x80000000, %rsi      ## imm = 0x80000000
100019d16:     	jne	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019d1c:     	movslq	0x8(%r15), %rsi
100019d20:     	cmpl	%edx, %esi
100019d22:     	jge	0x100019efe <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x49e>
100019d28:     	decq	%rcx
100019d2b:     	seto	-0x2a(%rbp)
100019d2f:     	cmpl	$0x0, 0x1c(%r11)
100019d34:     	je	0x100019efe <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x49e>
100019d3a:     	leaq	0x20(%r11), %r9
100019d3e:     	shrq	$0x6, %rcx
100019d42:     	xorq	%rcx, %r12
100019d45:     	andl	$0x3f, %eax
100019d48:     	movq	%rdi, %r10
100019d4b:     	btcq	%rax, %r10
100019d4f:     	decq	%r10
100019d52:     	setno	%r8b
100019d56:     	xorq	%rdi, %r10
100019d59:     	testq	%rax, %rax
100019d5c:     	movslq	%ecx, %rcx
100019d5f:     	movq	%rcx, -0x98(%rbp)
100019d66:     	movslq	%edx, %rcx
100019d69:     	sete	%dl
100019d6c:     	orb	%r8b, %dl
100019d6f:     	movb	%dl, -0x29(%rbp)
100019d72:     	xorl	%edx, %edx
100019d74:     	cmpq	$0x1, %rax
100019d78:     	movq	%rcx, %rax
100019d7b:     	sbbq	%rdx, %rdx
100019d7e:     	orq	%r10, %rdx
100019d81:     	movq	%rdx, -0x80(%rbp)
100019d85:     	andq	$-0x80000000, %r12      ## imm = 0x80000000
100019d8c:     	movq	%r9, -0x38(%rbp)
100019d90:     	movq	%r15, -0x78(%rbp)
100019d94:     	movq	%r13, -0x70(%rbp)
100019d98:     	movq	%r11, -0x68(%rbp)
100019d9c:     	movq	%r12, -0x60(%rbp)
100019da0:     	movq	%rcx, -0x58(%rbp)
100019da4:     	jmp	0x100019de5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x385>
100019da6:     	movq	-0x90(%rbp), %rcx
100019dad:     	andq	-0x48(%rbp), %rcx
100019db1:     	movq	-0x78(%rbp), %r15
100019db5:     	movq	-0x70(%rbp), %r13
100019db9:     	movq	-0x68(%rbp), %r11
100019dbd:     	movq	-0x38(%rbp), %r9
100019dc1:     	movq	-0x88(%rbp), %rsi
100019dc8:     	movq	-0x60(%rbp), %r12
100019dcc:     	movq	-0x58(%rbp), %rax
100019dd0:     	testq	%rcx, %rcx
100019dd3:     	jne	0x100019f12 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4b2>
100019dd9:     	incq	%rsi
100019ddc:     	cmpq	%rax, %rsi
100019ddf:     	je	0x100019efe <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x49e>
100019de5:     	cmpl	$0x0, 0x1c(%r11)
100019dea:     	je	0x100019dd9 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x379>
100019dec:     	cmpb	$0x0, -0x2a(%rbp)
100019df0:     	jne	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019df6:     	testq	%r12, %r12
100019df9:     	jne	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019dff:     	movq	(%r9,%rsi,8), %rcx
100019e03:     	notq	%rcx
100019e06:     	cmpq	-0x98(%rbp), %rsi
100019e0d:     	jne	0x100019e1d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x3bd>
100019e0f:     	cmpb	$0x0, -0x29(%rbp)
100019e13:     	je	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019e19:     	andq	-0x80(%rbp), %rcx
100019e1d:     	cmpb	$0x1, 0x42f0(%rbx)
100019e24:     	jne	0x100019dd0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x370>
100019e26:     	testq	%rcx, %rcx
100019e29:     	je	0x100019dd0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x370>
100019e2b:     	movl	0x10(%r11), %eax
100019e2f:     	testl	%eax, %eax
100019e31:     	js	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019e37:     	cmpl	$0x27, %eax
100019e3a:     	ja	0x10001a242 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e2>
100019e40:     	testq	%rsi, %rsi
100019e43:     	js	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019e49:     	movl	0x18(%r11), %edx
100019e4d:     	addq	%r11, %rdx
100019e50:     	movq	%rdx, -0xb8(%rbp)
100019e57:     	movq	0x2120(%rbx,%rax,8), %rax
100019e5f:     	movq	%rax, -0xb0(%rbp)
100019e66:     	movq	%rsi, -0x88(%rbp)
100019e6d:     	shlq	$0x6, %rsi
100019e71:     	movq	%rsi, -0xa8(%rbp)
100019e78:     	movq	%rcx, -0x48(%rbp)
100019e7c:     	movq	%rcx, -0x90(%rbp)
100019e83:     	movq	%rcx, %r15
100019e86:     	jmp	0x100019e98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x438>
100019e88:     	movq	%r13, %rdi
100019e8b:     	leaq	-0x1(%r15), %rax
100019e8f:     	andq	%rax, %r15
100019e92:     	je	0x100019da6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x346>
100019e98:     	movq	%rdi, %r13
100019e9b:     	bsfq	%r15, %r12
100019e9f:     	movq	%r12, %rsi
100019ea2:     	orq	-0xa8(%rbp), %rsi
100019ea9:     	imulq	-0xb0(%rbp), %rsi
100019eb1:     	addq	-0xb8(%rbp), %rsi
100019eb8:     	movq	%rbx, %rdi
100019ebb:     	callq	0x10001a280 <_*Gcry::Heap#blacklisted_page?<UInt64>:Bool>
100019ec0:     	testb	$0x1, %al
100019ec2:     	je	0x100019e88 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x428>
100019ec4:     	movq	0x4300(%rbx), %rax
100019ecb:     	xorq	%r13, %rax
100019ece:     	incq	%rax
100019ed1:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019ed7:     	movq	%r13, %rdi
100019eda:     	movq	-0x48(%rbp), %rcx
100019ede:     	btrq	%r12, %rcx
100019ee2:     	movq	%rcx, -0x48(%rbp)
100019ee6:     	xorq	%r13, %rax
100019ee9:     	movq	%rax, 0x4300(%rbx)
100019ef0:     	leaq	-0x1(%r15), %rax
100019ef4:     	andq	%rax, %r15
100019ef7:     	jne	0x100019e98 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x438>
100019ef9:     	jmp	0x100019da6 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x346>
100019efe:     	movq	$0x0, 0x20(%r15)
100019f06:     	leaq	0x298(%rbx), %rax
100019f0d:     	jmp	0x100019aa5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x45>
100019f12:     	movl	%esi, 0x8(%r15)
100019f16:     	testl	%esi, %esi
100019f18:     	js	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
100019f1e:     	movq	%rcx, %r9
100019f21:     	movq	%r15, %r8
100019f24:     	movq	%rsi, %r10
100019f27:     	movq	%r11, %rsi
100019f2a:     	movl	0x18(%r11), %ecx
100019f2e:     	movq	-0x40(%rbp), %rax
100019f32:     	testl	%eax, %eax
100019f34:     	js	0x100019f42 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4e2>
100019f36:     	cmpl	$0x27, %eax
100019f39:     	movl	%eax, %edx
100019f3b:     	jbe	0x100019f52 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x4f2>
100019f3d:     	jmp	0x10001a242 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e2>
100019f42:     	cmpl	$-0x29, %eax
100019f45:     	jbe	0x10001a242 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e2>
100019f4b:     	movq	-0x40(%rbp), %rax
100019f4f:     	leal	0x28(%rax), %edx
100019f52:     	movq	%rsi, %rdi
100019f55:     	addq	%rsi, %rcx
100019f58:     	movl	%r10d, %eax
100019f5b:     	movq	%rax, %rsi
100019f5e:     	shlq	$0x6, %rsi
100019f62:     	movl	%edx, %edx
100019f64:     	imulq	0x2120(%rbx,%rdx,8), %rsi
100019f6d:     	addq	%rcx, %rsi
100019f70:     	movq	%r8, %rcx
100019f73:     	movq	%rsi, 0x18(%r8)
100019f77:     	movq	%r9, %rsi
100019f7a:     	movq	%r9, 0x10(%r8)
100019f7e:     	cmpb	$0x1, 0x15210(%rbx)
100019f85:     	je	0x100019f99 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x539>
100019f87:     	cmpb	$0x0, 0x15220(%rbx)
100019f8e:     	jne	0x100019f99 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x539>
100019f90:     	cmpb	$0x0, 0x152d3(%rbx)
100019f97:     	je	0x100019fb0 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x550>
100019f99:     	movl	0x1c(%rdi), %ecx
100019f9c:     	testq	%rcx, %rcx
100019f9f:     	movq	-0x38(%rbp), %rdx
100019fa3:     	je	0x100019fba <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x55a>
100019fa5:     	leaq	(%rdx,%rcx,8), %rcx
100019fa9:     	lock
100019faa:     	orq	%rsi, (%rcx,%rax,8)
100019fae:     	jmp	0x100019fbc <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x55c>
100019fb0:     	cmpl	$0x0, 0x1c(%rdi)
100019fb4:     	movq	-0x38(%rbp), %rdx
100019fb8:     	jne	0x100019fbc <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x55c>
100019fba:     	xorl	%edx, %edx
100019fbc:     	lock
100019fbd:     	orq	%rsi, (%rdx,%rax,8)
100019fc1:     	incq	0x278(%rbx)
100019fc8:     	movq	%r8, %r15
100019fcb:     	movq	-0x50(%rbp), %rdx
100019fcf:     	testq	%rsi, %rsi
100019fd2:     	movq	-0x40(%rbp), %rcx
100019fd6:     	jne	0x100019c7d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x21d>
100019fdc:     	movq	%rsi, %rdi
100019fdf:     	movl	$0x40, %r12d
100019fe5:     	movq	0x18(%r15), %rax
100019fe9:     	testl	%ecx, %ecx
100019feb:     	js	0x100019ff7 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x597>
100019fed:     	cmpl	$0x27, %ecx
100019ff0:     	jbe	0x10001a003 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5a3>
100019ff2:     	jmp	0x10001a242 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e2>
100019ff7:     	cmpl	$-0x29, %ecx
100019ffa:     	jbe	0x10001a242 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e2>
10001a000:     	addl	$0x28, %ecx
10001a003:     	movl	%ecx, %ecx
10001a005:     	imulq	0x2120(%rbx,%rcx,8), %r12
10001a00e:     	addq	%rax, %r12
10001a011:     	movq	%r12, 0x20(%r15)
10001a015:     	leaq	-0x1(%rdi), %rax
10001a019:     	andq	%rdi, %rax
10001a01c:     	movq	%rax, 0x10(%r15)
10001a020:     	movq	-0xa0(%rbp), %rax
10001a027:     	movq	%rax, 0x10(%rdx)
10001a02b:     	incq	0x20(%rdx)
10001a02f:     	movq	0x19e0(%rbx), %rax
10001a036:     	testq	%rax, %rax
10001a039:     	je	0x10001a040 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5e0>
10001a03b:     	prefetcht0	(%rax,%r12)
10001a040:     	cmpb	$0x1, 0x15220(%rbx)
10001a047:     	je	0x10001a056 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x5f6>
10001a049:     	cmpb	$0x0, 0x15210(%rbx)
10001a050:     	je	0x10001a173 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x713>
10001a056:     	cmpb	$0x0, 0x30f0(%rbx)
10001a05d:     	je	0x10001a10d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6ad>
10001a063:     	movq	%rbx, %rdi
10001a066:     	movq	%r12, %rsi
10001a069:     	callq	0x100011d50 <_*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
10001a06e:     	testl	%eax, %eax
10001a070:     	je	0x10001a141 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6e1>
10001a076:     	cmpb	$0x1, 0x19c0(%rbx)
10001a07d:     	jne	0x10001a141 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6e1>
10001a083:     	movq	%rdx, %rsi
10001a086:     	movl	0x10(%rdx), %ecx
10001a089:     	movl	$0xffffffff, %eax       ## imm = 0xFFFFFFFF
10001a08e:     	cmpq	%rax, %rcx
10001a091:     	je	0x10001a141 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6e1>
10001a097:     	testb	$0x1, 0x14(%rsi)
10001a09b:     	jne	0x10001a141 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6e1>
10001a0a1:     	testl	%ecx, %ecx
10001a0a3:     	js	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
10001a0a9:     	movl	0x18(%rsi), %edx
10001a0ac:     	addq	%rsi, %rdx
10001a0af:     	movq	%r12, %rax
10001a0b2:     	subq	%rdx, %rax
10001a0b5:     	jb	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
10001a0bb:     	cmpl	$0x27, %ecx
10001a0be:     	ja	0x10001a242 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7e2>
10001a0c4:     	mulq	0x2260(%rbx,%rcx,8)
10001a0cc:     	jo	0x10001a23d <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7dd>
10001a0d2:     	movl	0x1c(%rsi), %edx
10001a0d5:     	testq	%rdx, %rdx
10001a0d8:     	je	0x10001a173 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x713>
10001a0de:     	leaq	(%rsi,%rdx,8), %r8
10001a0e2:     	movq	%rax, %rcx
10001a0e5:     	shrq	$0x28, %rcx
10001a0e9:     	shrq	$0x2e, %rax
10001a0ed:     	movl	$0x1, %r9d
10001a0f3:     	shlq	%cl, %r9
10001a0f6:     	movq	0x20(%r8,%rax,8), %rdi
10001a0fb:     	btq	%rcx, %rdi
10001a0ff:     	jb	0x10001a173 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x713>
10001a101:     	leaq	0x20(%rsi,%rdx,8), %rcx
10001a106:     	lock
10001a107:     	orq	%r9, (%rcx,%rax,8)
10001a10b:     	jmp	0x10001a173 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x713>
10001a10d:     	movzbl	0x207ef8(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a114:     	movl	%eax, %ecx
10001a116:     	movl	0x4(%r12), %eax
10001a11b:     	movl	%eax, %edx
10001a11d:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a123:     	movzbl	%cl, %esi
10001a126:     	shll	$0x8, %esi
10001a129:     	orl	%edx, %esi
10001a12b:     	lock
10001a12c:     	cmpxchgl	%esi, 0x4(%r12)
10001a132:     	movzbl	0x207ed3(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a139:     	jne	0x10001a114 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b4>
10001a13b:     	cmpb	%al, %cl
10001a13d:     	jne	0x10001a114 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6b4>
10001a13f:     	jmp	0x10001a173 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x713>
10001a141:     	movzbl	0x207ec4(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a148:     	movl	%eax, %ecx
10001a14a:     	movl	0x4(%r12), %eax
10001a14f:     	movl	%eax, %edx
10001a151:     	andl	$0xffff00fb, %edx       ## imm = 0xFFFF00FB
10001a157:     	movzbl	%cl, %esi
10001a15a:     	shll	$0x8, %esi
10001a15d:     	orl	%edx, %esi
10001a15f:     	lock
10001a160:     	cmpxchgl	%esi, 0x4(%r12)
10001a166:     	movzbl	0x207e9f(%rip), %eax    ## 0x10022200c <_Gcry::BlockHeader::mark_gen>
10001a16d:     	jne	0x10001a148 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6e8>
10001a16f:     	cmpb	%al, %cl
10001a171:     	jne	0x10001a148 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x6e8>
10001a173:     	leaq	-0x10(%r13), %rax
10001a177:     	rolq	$0x3c, %rax
10001a17b:     	cmpq	$0x3, %rax
10001a17f:     	ja	0x10001a220 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7c0>
10001a185:     	leaq	0xc4(%rip), %rcx        ## 0x10001a250 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7f0>
10001a18c:     	movslq	(%rcx,%rax,4), %rax
10001a190:     	addq	%rcx, %rax
10001a193:     	jmpq	*%rax
10001a195:     	movq	$0x0, 0x38(%r12)
10001a19e:     	movq	$0x0, 0x30(%r12)
10001a1a7:     	movq	$0x0, 0x28(%r12)
10001a1b0:     	movq	$0x0, 0x20(%r12)
10001a1b9:     	movq	$0x0, 0x18(%r12)
10001a1c2:     	movq	$0x0, 0x10(%r12)
10001a1cb:     	movq	$0x0, 0x8(%r12)
10001a1d4:     	movq	$0x0, (%r12)
10001a1dc:     	movq	$0x0, 0x20(%r15)
10001a1e4:     	cmpb	$0x1, 0x208085(%rip)    ## 0x100222270 <_Gcry::Invariant::enabled>
10001a1eb:     	jne	0x10001a1f5 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x795>
10001a1ed:     	movq	%rbx, %rdi
10001a1f0:     	callq	0x100017230 <_*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
10001a1f5:     	cmpb	$0x1, 0x208058(%rip)    ## 0x100222254 <_Gcry::Trace::enabled>
10001a1fc:     	jne	0x10001a20b <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7ab>
10001a1fe:     	movq	%r12, %rdi
10001a201:     	movq	%r14, %rsi
10001a204:     	xorl	%edx, %edx
10001a206:     	callq	0x10001a330 <_*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
10001a20b:     	movq	%r12, %rax
10001a20e:     	addq	$0x98, %rsp
10001a215:     	popq	%rbx
10001a216:     	popq	%r12
10001a218:     	popq	%r13
10001a21a:     	popq	%r14
10001a21c:     	popq	%r15
10001a21e:     	popq	%rbp
10001a21f:     	retq
10001a220:     	movq	%r12, %rdi
10001a223:     	movq	%r13, %rsi
10001a226:     	callq	0x1001c1c2c <_write+0x1001c1c2c>
10001a22b:     	movq	$0x0, 0x20(%r15)
10001a233:     	testq	%r12, %r12
10001a236:     	jne	0x10001a1e4 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x784>
10001a238:     	jmp	0x100019aa8 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x48>
10001a23d:     	callq	0x100005a40 <___crystal_raise_overflow>
10001a242:     	callq	0x10000a3e0 <_*IndexError::new:IndexError>
10001a247:     	movq	%rax, %rdi
10001a24a:     	callq	0x10000a430 <_*raise<IndexError>:NoReturn>
10001a24f:     	nop
10001a250:     	jnp	0x10001a251 <_*Gcry::Heap#malloc<UInt64>:Pointer(Void)+0x7f1>
10001a252:     	<unknown>
10001a254:     	imull	$0xff57ffff, %edi, %edi ## imm = 0xFF57FFFF
10001a25a:     	<unknown>
10001a25c:     	<unknown>
10001a25f:     	callq	*0x48(%rbp)
