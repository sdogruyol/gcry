   1b390:	push   %rbp
   1b391:	push   %r15
   1b393:	push   %r14
   1b395:	push   %r13
   1b397:	push   %r12
   1b399:	push   %rbx
   1b39a:	sub    $0x78,%rsp
   1b39e:	cmpb   $0x1,0x1a0cfc(%rip)        # 1bc0a1 <GC::after_fork_child>
   1b3a5:	je     1bb76 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e6>
   1b3ab:	cmpb   $0x1,0x1a0cf0(%rip)        # 1bc0a2 <GC::gcry_ready>
   1b3b2:	jne    1b48c <*GC::malloc_atomic<UInt64>:Pointer(Void)+0xfc>
   1b3b8:	lea    0x1a0ce9(%rip),%rbx        # 1bc0a8 <Gcry::default_heap>
   1b3bf:	mov    (%rbx),%r14
   1b3c2:	test   %r14,%r14
   1b3c5:	jne    1b3d8 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x48>
   1b3c7:	mov    %rdi,%r14
   1b3ca:	call   1bcc0 <*Gcry::Heap::new:Gcry::Heap>
   1b3cf:	mov    %r14,%rdi
   1b3d2:	mov    %rax,%r14
   1b3d5:	mov    %rax,(%rbx)
   1b3d8:	add    0x30d8(%r14),%rdi
   1b3df:	mov    $0xffffffffffffffff,%rbx
   1b3e6:	cmovae %rdi,%rbx
   1b3ea:	cmpb   $0x1,0x1501c(%r14)
   1b3f2:	jne    1b4b8 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x128>
   1b3f8:	mov    $0x278,%ecx
   1b3fd:	cmpb   $0x0,0x15190(%r14)
   1b405:	jne    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b40b:	cmpb   $0x0,0x151a0(%r14)
   1b413:	jne    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b419:	cmpb   $0x0,0x15253(%r14)
   1b421:	jne    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b427:	mov    $0x280,%ecx
   1b42c:	cmp    $0x8000,%rbx
   1b433:	ja     1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b435:	lea    0x70(%rsp),%rdi
   1b43a:	call   2ae30 <*Gcry::Heap::tls_cursor_cache>
   1b43f:	mov    0x70(%rsp),%rax
   1b444:	mov    0x8(%rax),%rcx
   1b448:	xor    %r14,%rcx
   1b44b:	jne    1b4af <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x11f>
   1b44d:	mov    (%rax),%r13
   1b450:	mov    $0x288,%ecx
   1b455:	test   %r13,%r13
   1b458:	je     1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b45a:	cmpb   $0x0,0x9(%r13)
   1b45f:	jne    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b461:	cmp    $0x801,%rbx
   1b468:	jae    1b510 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x180>
   1b46e:	lea    0x7(%rbx),%rcx
   1b472:	shr    $0x3,%rcx
   1b476:	mov    0x3254(%r14,%rcx,4),%eax
   1b47e:	movzbl 0x3150(%r14,%rcx,1),%ebp
   1b487:	jmp    1b5ad <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x21d>
   1b48c:	call   15210 <malloc@plt>
   1b491:	test   %rax,%rax
   1b494:	je     1bb7b <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7eb>
   1b49a:	mov    %rax,%r15
   1b49d:	mov    %rax,%rdi
   1b4a0:	call   153e0 <malloc_usable_size@plt>
   1b4a5:	lock add %rax,0x1a0c23(%rip)        # 1bc0d0 <GC::non_gc_bytes>
   1b4ad:	jmp    1b4fe <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x16e>
   1b4af:	mov    $0x288,%ecx
   1b4b4:	incq   (%r14,%rcx,1)
   1b4b8:	mov    %r14,%rdi
   1b4bb:	mov    %rbx,%rsi
   1b4be:	mov    $0x1,%edx
   1b4c3:	xor    %ecx,%ecx
   1b4c5:	call   308d0 <*Gcry::Heap#allocate:atomic:clear<UInt64, Bool, Bool>:Pointer(Void)>
   1b4ca:	mov    %rax,%r15
   1b4cd:	test   %rax,%rax
   1b4d0:	setne  %al
   1b4d3:	and    0x1a0c17(%rip),%al        # 1bc0f0 <Gcry::Invariant::enabled>
   1b4d9:	cmp    $0x1,%al
   1b4db:	jne    1b4e5 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x155>
   1b4dd:	mov    %r14,%rdi
   1b4e0:	call   2cc80 <*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
   1b4e5:	cmpb   $0x1,0x1a0bc5(%rip)        # 1bc0b1 <Gcry::Trace::enabled>
   1b4ec:	jne    1b4fe <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x16e>
   1b4ee:	mov    %r15,%rdi
   1b4f1:	mov    %rbx,%rsi
   1b4f4:	mov    $0x1,%edx
   1b4f9:	call   2fff0 <*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
   1b4fe:	mov    %r15,%rax
   1b501:	add    $0x78,%rsp
   1b505:	pop    %rbx
   1b506:	pop    %r12
   1b508:	pop    %r13
   1b50a:	pop    %r14
   1b50c:	pop    %r15
   1b50e:	pop    %rbp
   1b50f:	ret
   1b510:	mov    $0xc,%r15d
   1b516:	cmp    $0x4000,%rbx
   1b51d:	ja     1b53f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x1af>
   1b51f:	mov    $0xb,%r15d
   1b525:	cmp    $0x2001,%rbx
   1b52c:	jae    1b53f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x1af>
   1b52e:	cmp    $0x1001,%rbx
   1b535:	mov    $0x9,%r15d
   1b53b:	sbb    $0xffffffff,%r15d
   1b53f:	movabs $0x8000000000000000,%r12
   1b549:	mov    %rbx,%rdi
   1b54c:	or     %r12,%rdi
   1b54f:	dec    %rdi
   1b552:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b558:	xor    %r12,%rdi
   1b55b:	mov    %r15d,%esi
   1b55e:	call   1e560 <*UInt64@Int#>><Int32>:UInt64>
   1b563:	xor    %r12,%rax
   1b566:	inc    %rax
   1b569:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b56f:	movabs $0x8000000100000000,%rcx
   1b579:	cmp    %rcx,%rax
   1b57c:	jge    1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b582:	test   %eax,%eax
   1b584:	js     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b58a:	lea    -0xd(,%r15,4),%ebp
   1b592:	add    %eax,%ebp
   1b594:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b59a:	add    $0xfffffffc,%ebp
   1b59d:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b5a3:	mov    %eax,%edi
   1b5a5:	mov    %r15d,%esi
   1b5a8:	call   1fbb0 <*UInt32@Int#<<<Int32>:UInt32>
   1b5ad:	mov    %ebp,%edx
   1b5af:	add    $0x28,%edx
   1b5b2:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b5b8:	movslq %edx,%rcx
   1b5bb:	lea    (%rcx,%rcx,4),%rcx
   1b5bf:	lea    0x30(%r13,%rcx,8),%r12
   1b5c4:	cmpq   $0x0,0x40(%r13,%rcx,8)
   1b5ca:	jne    1b5d7 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x247>
   1b5cc:	cmpq   $0x0,(%r12)
   1b5d1:	je     1b680 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2f0>
   1b5d7:	mov    %eax,%r8d
   1b5da:	add    0x10(%r13),%r8
   1b5de:	mov    %r8,%rsi
   1b5e1:	sub    0x18(%r13),%rsi
   1b5e5:	add    0x14f00(%r14),%rsi
   1b5ec:	mov    0x3808(%r14),%rdi
   1b5f3:	cmp    %rdi,%rsi
   1b5f6:	jb     1b624 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x294>
   1b5f8:	mov    %edx,%r15d
   1b5fb:	mov    %ebp,0x4(%rsp)
   1b5ff:	mov    %r12,%rbp
   1b602:	mov    %r8,%r12
   1b605:	call   2ff00 <*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
   1b60a:	mov    %r12,%r8
   1b60d:	mov    %rbp,%r12
   1b610:	mov    0x4(%rsp),%ebp
   1b614:	mov    %r15d,%edx
   1b617:	mov    $0x298,%ecx
   1b61c:	test   $0x1,%al
   1b61e:	jne    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b624:	movq   $0x8,0x20(%r12)
   1b62d:	mov    0x10(%r12),%rdi
   1b632:	test   %rdi,%rdi
   1b635:	je     1b654 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2c4>
   1b637:	mov    0x18(%r12),%rax
   1b63c:	test   %ebp,%ebp
   1b63e:	js     1b9c3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x633>
   1b644:	cmp    $0x27,%ebp
   1b647:	mov    %ebp,%edx
   1b649:	jbe    1b9cc <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x63c>
   1b64f:	jmp    1bb8f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7ff>
   1b654:	mov    %r8,0x38(%rsp)
   1b659:	mov    %edx,0x1c(%rsp)
   1b65d:	mov    (%r12),%r8
   1b661:	test   %r8,%r8
   1b664:	je     1b8b6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x526>
   1b66a:	movslq 0x10(%r8),%rax
   1b66e:	test   %rax,%rax
   1b671:	js     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b677:	cmp    $0x27,%eax
   1b67a:	jbe    1b68a <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2fa>
   1b67c:	xor    %eax,%eax
   1b67e:	jmp    1b6ae <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x31e>
   1b680:	mov    $0x290,%ecx
   1b685:	jmp    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b68a:	mov    0x2118(%r14,%rax,8),%rsi
   1b692:	xor    %eax,%eax
   1b694:	test   %rsi,%rsi
   1b697:	je     1b6ae <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x31e>
   1b699:	mov    0x8(%r8),%rcx
   1b69d:	mov    0x18(%r8),%edx
   1b6a1:	sub    %rdx,%rcx
   1b6a4:	jbe    1b6ae <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x31e>
   1b6a6:	mov    %rcx,%rax
   1b6a9:	xor    %edx,%edx
   1b6ab:	div    %rsi
   1b6ae:	movabs $0x8000000000000000,%r10
   1b6b8:	mov    %rax,%rcx
   1b6bb:	xor    %r10,%rcx
   1b6be:	mov    %rcx,%rdx
   1b6c1:	add    $0x3f,%rdx
   1b6c5:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b6cb:	movabs $0x200000000000000,%rsi
   1b6d5:	shr    $0x6,%rdx
   1b6d9:	mov    %rdx,%rdi
   1b6dc:	xor    %rsi,%rdi
   1b6df:	and    $0xffffffff80000000,%rdi
   1b6e6:	jne    1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b6ec:	movslq 0x8(%r12),%r15
   1b6f1:	cmp    %edx,%r15d
   1b6f4:	jge    1b8b6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x526>
   1b6fa:	dec    %rcx
   1b6fd:	seto   %r9b
   1b701:	cmpl   $0x0,0x1c(%r8)
   1b706:	je     1b8b6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x526>
   1b70c:	mov    %r8,0x10(%rsp)
   1b711:	mov    %ebp,0x4(%rsp)
   1b715:	mov    %r13,0x30(%rsp)
   1b71a:	mov    %r12,0x20(%rsp)
   1b71f:	and    $0x3f,%eax
   1b722:	mov    %r10,%r8
   1b725:	btc    %rax,%r8
   1b729:	dec    %r8
   1b72c:	seto   %dil
   1b730:	test   %rax,%rax
   1b733:	setne  0x3(%rsp)
   1b738:	xor    %r10d,%r10d
   1b73b:	cmp    $0x1,%rax
   1b73f:	sbb    %r10,%r10
   1b742:	mov    %r10,0x28(%rsp)
   1b747:	test   %r9b,%r9b
   1b74a:	jne    1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b750:	shr    $0x6,%rcx
   1b754:	xor    %rcx,%rsi
   1b757:	cmp    $0x7fffffff,%rsi
   1b75e:	ja     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b764:	mov    0x10(%rsp),%rsi
   1b769:	lea    0x20(%rsi),%rax
   1b76d:	movabs $0x8000000000000000,%r9
   1b777:	xor    %r9,%r8
   1b77a:	or     %r8,0x28(%rsp)
   1b77f:	movslq %ecx,%r8
   1b782:	movslq %edx,%rdx
   1b785:	and    %dil,0x3(%rsp)
   1b78a:	mov    0x20(%rsp),%r12
   1b78f:	mov    %rax,0x8(%rsp)
   1b794:	mov    %r8,0x48(%rsp)
   1b799:	mov    %rdx,0x40(%rsp)
   1b79e:	jmp    1b7db <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x44b>
   1b7a0:	mov    0x58(%rsp),%rdi
   1b7a5:	and    %r13,%rdi
   1b7a8:	mov    0x20(%rsp),%r12
   1b7ad:	mov    0x10(%rsp),%rsi
   1b7b2:	mov    0x8(%rsp),%rax
   1b7b7:	mov    0x50(%rsp),%r15
   1b7bc:	mov    0x48(%rsp),%r8
   1b7c1:	mov    0x40(%rsp),%rdx
   1b7c6:	test   %rdi,%rdi
   1b7c9:	jne    1b8c9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x539>
   1b7cf:	inc    %r15
   1b7d2:	cmp    %rdx,%r15
   1b7d5:	je     1b8b6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x526>
   1b7db:	cmpl   $0x0,0x1c(%rsi)
   1b7df:	je     1b7cf <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x43f>
   1b7e1:	mov    (%rax,%r15,8),%rdi
   1b7e5:	not    %rdi
   1b7e8:	cmp    %r8,%r15
   1b7eb:	jne    1b7fd <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x46d>
   1b7ed:	cmpb   $0x0,0x3(%rsp)
   1b7f2:	jne    1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b7f8:	and    0x28(%rsp),%rdi
   1b7fd:	cmpb   $0x1,0x42a0(%r14)
   1b805:	jne    1b7c6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x436>
   1b807:	test   %rdi,%rdi
   1b80a:	je     1b7c6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x436>
   1b80c:	movslq 0x10(%rsi),%rax
   1b810:	test   %rax,%rax
   1b813:	js     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b819:	cmp    $0x28,%eax
   1b81c:	jae    1bb8f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7ff>
   1b822:	test   %r15,%r15
   1b825:	js     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b82b:	mov    0x18(%rsi),%ecx
   1b82e:	add    %rsi,%rcx
   1b831:	mov    %rcx,0x68(%rsp)
   1b836:	mov    0x2118(%r14,%rax,8),%rax
   1b83e:	mov    %rax,0x60(%rsp)
   1b843:	mov    %r15,0x50(%rsp)
   1b848:	shl    $0x6,%r15
   1b84c:	mov    %rdi,%r13
   1b84f:	mov    %rdi,0x58(%rsp)
   1b854:	mov    %rdi,%r12
   1b857:	jmp    1b867 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x4d7>
   1b859:	lea    -0x1(%r12),%rax
   1b85e:	and    %rax,%r12
   1b861:	je     1b7a0 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x410>
   1b867:	tzcnt  %r12,%rbp
   1b86c:	mov    %rbp,%rsi
   1b86f:	or     %r15,%rsi
   1b872:	imul   0x60(%rsp),%rsi
   1b878:	add    0x68(%rsp),%rsi
   1b87d:	mov    %r14,%rdi
   1b880:	call   2ff10 <*Gcry::Heap#blacklisted_page?<UInt64>:Bool>
   1b885:	test   $0x1,%al
   1b887:	je     1b859 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x4c9>
   1b889:	mov    0x42b0(%r14),%rax
   1b890:	movabs $0x8000000000000000,%rcx
   1b89a:	xor    %rcx,%rax
   1b89d:	inc    %rax
   1b8a0:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b8a6:	btr    %rbp,%r13
   1b8aa:	xor    %rcx,%rax
   1b8ad:	mov    %rax,0x42b0(%r14)
   1b8b4:	jmp    1b859 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x4c9>
   1b8b6:	movq   $0x0,0x20(%r12)
   1b8bf:	mov    $0x290,%ecx
   1b8c4:	jmp    1b4b4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x124>
   1b8c9:	mov    %r15d,0x8(%r12)
   1b8ce:	test   %r15,%r15
   1b8d1:	js     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1b8d7:	mov    %r15,%rsi
   1b8da:	mov    0x10(%rsp),%rax
   1b8df:	mov    0x18(%rax),%ecx
   1b8e2:	cmpl   $0x0,0x4(%rsp)
   1b8e7:	js     1b8f7 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x567>
   1b8e9:	mov    0x4(%rsp),%edx
   1b8ed:	cmp    $0x27,%edx
   1b8f0:	jbe    1b906 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x576>
   1b8f2:	jmp    1bb8f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7ff>
   1b8f7:	cmpl   $0xffffffd7,0x4(%rsp)
   1b8fc:	mov    0x1c(%rsp),%edx
   1b900:	jbe    1bb8f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7ff>
   1b906:	add    0x10(%rsp),%rcx
   1b90b:	mov    %esi,%eax
   1b90d:	mov    %rax,%rsi
   1b910:	shl    $0x6,%rsi
   1b914:	mov    %edx,%edx
   1b916:	imul   0x2118(%r14,%rdx,8),%rsi
   1b91f:	add    %rcx,%rsi
   1b922:	mov    0x20(%rsp),%rcx
   1b927:	mov    %rsi,0x18(%rcx)
   1b92b:	mov    %rdi,0x10(%rcx)
   1b92f:	cmpb   $0x1,0x15190(%r14)
   1b937:	je     1b94d <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5bd>
   1b939:	cmpb   $0x0,0x151a0(%r14)
   1b941:	jne    1b94d <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5bd>
   1b943:	cmpb   $0x0,0x15253(%r14)
   1b94b:	je     1b975 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5e5>
   1b94d:	mov    0x10(%rsp),%rcx
   1b952:	mov    0x1c(%rcx),%ecx
   1b955:	test   %rcx,%rcx
   1b958:	je     1b96a <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5da>
   1b95a:	mov    0x8(%rsp),%rdx
   1b95f:	lea    (%rdx,%rcx,8),%rcx
   1b963:	lock or %rdi,(%rcx,%rax,8)
   1b968:	jmp    1b98e <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5fe>
   1b96a:	movq   $0x0,0x8(%rsp)
   1b973:	jmp    1b98e <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5fe>
   1b975:	xor    %ecx,%ecx
   1b977:	mov    0x10(%rsp),%rdx
   1b97c:	cmpl   $0x0,0x1c(%rdx)
   1b980:	mov    0x8(%rsp),%rdx
   1b985:	cmove  %rcx,%rdx
   1b989:	mov    %rdx,0x8(%rsp)
   1b98e:	mov    0x8(%rsp),%rcx
   1b993:	lock or %rdi,(%rcx,%rax,8)
   1b998:	incq   0x270(%r14)
   1b99f:	mov    0x20(%rsp),%r12
   1b9a4:	mov    0x30(%rsp),%r13
   1b9a9:	mov    0x4(%rsp),%ebp
   1b9ad:	mov    0x1c(%rsp),%edx
   1b9b1:	mov    0x38(%rsp),%r8
   1b9b6:	mov    0x18(%r12),%rax
   1b9bb:	test   %ebp,%ebp
   1b9bd:	jns    1b644 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2b4>
   1b9c3:	cmp    $0xffffffd7,%ebp
   1b9c6:	jbe    1bb8f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7ff>
   1b9cc:	tzcnt  %rdi,%r15
   1b9d1:	mov    %edx,%ecx
   1b9d3:	imul   0x2118(%r14,%rcx,8),%r15
   1b9dc:	add    %rax,%r15
   1b9df:	mov    %r15,0x20(%r12)
   1b9e4:	lea    -0x1(%rdi),%rax
   1b9e8:	and    %rdi,%rax
   1b9eb:	mov    %rax,0x10(%r12)
   1b9f0:	mov    %r8,0x10(%r13)
   1b9f4:	incq   0x20(%r13)
   1b9f8:	mov    0x19d8(%r14),%rax
   1b9ff:	test   %rax,%rax
   1ba02:	je     1ba09 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x679>
   1ba04:	prefetcht0 (%rax,%r15,1)
   1ba09:	cmpb   $0x1,0x151a0(%r14)
   1ba11:	je     1ba21 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x691>
   1ba13:	cmpb   $0x0,0x15190(%r14)
   1ba1b:	je     1bad3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x743>
   1ba21:	cmpb   $0x0,0x30d0(%r14)
   1ba29:	je     1bae6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x756>
   1ba2f:	mov    %r14,%rdi
   1ba32:	mov    %r15,%rsi
   1ba35:	call   270d0 <*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
   1ba3a:	test   %eax,%eax
   1ba3c:	je     1bb1f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x78f>
   1ba42:	cmpb   $0x1,0x19b8(%r14)
   1ba4a:	jne    1bb1f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x78f>
   1ba50:	mov    0x10(%rdx),%ecx
   1ba53:	mov    $0xffffffff,%eax
   1ba58:	cmp    %rax,%rcx
   1ba5b:	je     1bb1f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x78f>
   1ba61:	testb  $0x1,0x14(%rdx)
   1ba65:	jne    1bb1f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x78f>
   1ba6b:	test   %ecx,%ecx
   1ba6d:	js     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1ba73:	mov    %rdx,%rsi
   1ba76:	mov    0x18(%rsi),%edx
   1ba79:	add    %rsi,%rdx
   1ba7c:	mov    %r15,%rax
   1ba7f:	sub    %rdx,%rax
   1ba82:	jb     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1ba88:	cmp    $0x27,%ecx
   1ba8b:	ja     1bb8f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7ff>
   1ba91:	mulq   0x2258(%r14,%rcx,8)
   1ba99:	jo     1bb71 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7e1>
   1ba9f:	mov    0x1c(%rsi),%edx
   1baa2:	test   %rdx,%rdx
   1baa5:	je     1bad3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x743>
   1baa7:	lea    (%rsi,%rdx,8),%r8
   1baab:	mov    %rax,%rcx
   1baae:	shr    $0x28,%rcx
   1bab2:	shr    $0x2e,%rax
   1bab6:	mov    $0x1,%edi
   1babb:	shl    %cl,%rdi
   1babe:	mov    0x20(%r8,%rax,8),%r8
   1bac3:	bt     %rcx,%r8
   1bac7:	jb     1bad3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x743>
   1bac9:	lea    0x20(%rsi,%rdx,8),%rcx
   1bace:	lock or %rdi,(%rcx,%rax,8)
   1bad3:	movq   $0x0,0x20(%r12)
   1badc:	test   %r15,%r15
   1badf:	jne    1bb5f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7cf>
   1bae1:	jmp    1b4b8 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x128>
   1bae6:	movzbl 0x1a052f(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1baed:	mov    0x4(%r15),%eax
   1baf1:	mov    %eax,%edx
   1baf3:	and    $0xffff00fb,%edx
   1baf9:	movzbl %cl,%esi
   1bafc:	mov    %esi,%ecx
   1bafe:	shl    $0x8,%ecx
   1bb01:	or     %edx,%ecx
   1bb03:	lock cmpxchg %ecx,0x4(%r15)
   1bb09:	sete   %al
   1bb0c:	movzbl 0x1a0509(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb13:	cmp    %cl,%sil
   1bb16:	sete   %dl
   1bb19:	test   %dl,%al
   1bb1b:	je     1baed <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x75d>
   1bb1d:	jmp    1bb56 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7c6>
   1bb1f:	movzbl 0x1a04f6(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb26:	mov    0x4(%r15),%eax
   1bb2a:	mov    %eax,%edx
   1bb2c:	and    $0xffff00fb,%edx
   1bb32:	movzbl %cl,%esi
   1bb35:	mov    %esi,%ecx
   1bb37:	shl    $0x8,%ecx
   1bb3a:	or     %edx,%ecx
   1bb3c:	lock cmpxchg %ecx,0x4(%r15)
   1bb42:	sete   %al
   1bb45:	movzbl 0x1a04d0(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb4c:	cmp    %cl,%sil
   1bb4f:	sete   %dl
   1bb52:	test   %dl,%al
   1bb54:	je     1bb26 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x796>
   1bb56:	movq   $0x0,0x20(%r12)
   1bb5f:	cmpb   $0x1,0x1a058a(%rip)        # 1bc0f0 <Gcry::Invariant::enabled>
   1bb66:	je     1b4dd <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x14d>
   1bb6c:	jmp    1b4e5 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x155>
   1bb71:	call   1a950 <__crystal_raise_overflow>
   1bb76:	call   1bba0 <*GC::fork_poison_exit:NoReturn>
   1bb7b:	lea    0x14fcae(%rip),%rdi        # 16b830 <$Slice:7+0x1ab0>
   1bb82:	call   1de60 <*Gcry::OutOfMemoryError@Exception::new<String>:Gcry::OutOfMemoryError>
   1bb87:	mov    %rax,%rdi
   1bb8a:	call   1eb40 <*raise<Gcry::OutOfMemoryError>:NoReturn>
   1bb8f:	call   1f1e0 <*IndexError::new:IndexError>
   1bb94:	mov    %rax,%rdi
   1bb97:	call   1f230 <*raise<IndexError>:NoReturn>
   1bb9c:	nopl   0x0(%rax)
