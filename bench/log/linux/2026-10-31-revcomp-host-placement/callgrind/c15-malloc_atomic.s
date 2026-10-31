   1b390:	push   %rbp
   1b391:	push   %r15
   1b393:	push   %r14
   1b395:	push   %r13
   1b397:	push   %r12
   1b399:	push   %rbx
   1b39a:	sub    $0x88,%rsp
   1b3a1:	cmpb   $0x1,0x1a0cf9(%rip)        # 1bc0a1 <GC::after_fork_child>
   1b3a8:	je     1bbe0 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x850>
   1b3ae:	cmpb   $0x1,0x1a0ced(%rip)        # 1bc0a2 <GC::gcry_ready>
   1b3b5:	jne    1b4a3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x113>
   1b3bb:	mov    %rdi,%rbx
   1b3be:	lea    0x1a0ce3(%rip),%r14        # 1bc0a8 <Gcry::default_heap>
   1b3c5:	mov    (%r14),%rdi
   1b3c8:	test   %rdi,%rdi
   1b3cb:	jne    1b3d8 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x48>
   1b3cd:	call   1bd30 <*Gcry::Heap::new:Gcry::Heap>
   1b3d2:	mov    %rax,%rdi
   1b3d5:	mov    %rax,(%r14)
   1b3d8:	add    0x30d8(%rdi),%rbx
   1b3df:	mov    $0xffffffffffffffff,%rsi
   1b3e6:	cmovae %rbx,%rsi
   1b3ea:	cmpb   $0x1,0x1501c(%rdi)
   1b3f1:	jne    1b4e7 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x157>
   1b3f7:	mov    $0x278,%ecx
   1b3fc:	cmpb   $0x0,0x15190(%rdi)
   1b403:	jne    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b409:	cmpb   $0x0,0x151a0(%rdi)
   1b410:	jne    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b416:	cmpb   $0x0,0x15253(%rdi)
   1b41d:	jne    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b423:	mov    $0x280,%ecx
   1b428:	cmp    $0x8000,%rsi
   1b42f:	ja     1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b435:	mov    %rsi,0x18(%rsp)
   1b43a:	lea    0x80(%rsp),%rax
   1b442:	mov    %rdi,0x10(%rsp)
   1b447:	mov    %rax,%rdi
   1b44a:	call   2ae70 <*Gcry::Heap::tls_cursor_cache>
   1b44f:	mov    0x10(%rsp),%rdi
   1b454:	mov    0x80(%rsp),%rax
   1b45c:	mov    0x8(%rax),%rcx
   1b460:	xor    %rdi,%rcx
   1b463:	jne    1b4d9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x149>
   1b465:	mov    (%rax),%r15
   1b468:	mov    $0x288,%ecx
   1b46d:	test   %r15,%r15
   1b470:	je     1b4de <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x14e>
   1b472:	cmpb   $0x0,0x9(%r15)
   1b477:	mov    0x18(%rsp),%rsi
   1b47c:	jne    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b47e:	cmp    $0x801,%rsi
   1b485:	jae    1b504 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x174>
   1b487:	lea    0x7(%rsi),%rcx
   1b48b:	shr    $0x3,%rcx
   1b48f:	mov    0x3254(%rdi,%rcx,4),%eax
   1b496:	movzbl 0x3150(%rdi,%rcx,1),%ebp
   1b49e:	jmp    1b5ab <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x21b>
   1b4a3:	call   15210 <malloc@plt>
   1b4a8:	test   %rax,%rax
   1b4ab:	je     1bbe5 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x855>
   1b4b1:	mov    %rax,%r14
   1b4b4:	mov    %rax,%rdi
   1b4b7:	call   153e0 <malloc_usable_size@plt>
   1b4bc:	lock add %rax,0x1a0c0c(%rip)        # 1bc0d0 <GC::non_gc_bytes>
   1b4c4:	mov    %r14,%rax
   1b4c7:	add    $0x88,%rsp
   1b4ce:	pop    %rbx
   1b4cf:	pop    %r12
   1b4d1:	pop    %r13
   1b4d3:	pop    %r14
   1b4d5:	pop    %r15
   1b4d7:	pop    %rbp
   1b4d8:	ret
   1b4d9:	mov    $0x288,%ecx
   1b4de:	mov    0x18(%rsp),%rsi
   1b4e3:	incq   (%rdi,%rcx,1)
   1b4e7:	mov    $0x1,%edx
   1b4ec:	xor    %ecx,%ecx
   1b4ee:	add    $0x88,%rsp
   1b4f5:	pop    %rbx
   1b4f6:	pop    %r12
   1b4f8:	pop    %r13
   1b4fa:	pop    %r14
   1b4fc:	pop    %r15
   1b4fe:	pop    %rbp
   1b4ff:	jmp    30930 <*Gcry::Heap#allocate_entry<UInt64, Bool, Bool>:Pointer(Void)>
   1b504:	mov    $0xc,%r14d
   1b50a:	cmp    $0x4000,%rsi
   1b511:	ja     1b533 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x1a3>
   1b513:	mov    $0xb,%r14d
   1b519:	cmp    $0x2001,%rsi
   1b520:	jae    1b533 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x1a3>
   1b522:	cmp    $0x1001,%rsi
   1b529:	mov    $0x9,%r14d
   1b52f:	sbb    $0xffffffff,%r14d
   1b533:	movabs $0x8000000000000000,%rbx
   1b53d:	mov    %rsi,%rdi
   1b540:	or     %rbx,%rdi
   1b543:	dec    %rdi
   1b546:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b54c:	xor    %rbx,%rdi
   1b54f:	mov    %r14d,%esi
   1b552:	call   1e5a0 <*UInt64@Int#>><Int32>:UInt64>
   1b557:	xor    %rbx,%rax
   1b55a:	inc    %rax
   1b55d:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b563:	movabs $0x8000000100000000,%rcx
   1b56d:	cmp    %rcx,%rax
   1b570:	jge    1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b576:	test   %eax,%eax
   1b578:	js     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b57e:	lea    -0xd(,%r14,4),%ebp
   1b586:	add    %eax,%ebp
   1b588:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b58e:	add    $0xfffffffc,%ebp
   1b591:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b597:	mov    %eax,%edi
   1b599:	mov    %r14d,%esi
   1b59c:	call   1fbf0 <*UInt32@Int#<<<Int32>:UInt32>
   1b5a1:	mov    0x18(%rsp),%rsi
   1b5a6:	mov    0x10(%rsp),%rdi
   1b5ab:	mov    %ebp,%r12d
   1b5ae:	add    $0x28,%r12d
   1b5b2:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b5b8:	movslq %r12d,%rcx
   1b5bb:	lea    (%rcx,%rcx,4),%rcx
   1b5bf:	lea    0x30(%r15,%rcx,8),%rbx
   1b5c4:	cmpq   $0x0,0x40(%r15,%rcx,8)
   1b5ca:	jne    1b5d6 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x246>
   1b5cc:	cmpq   $0x0,(%rbx)
   1b5d0:	je     1b669 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2d9>
   1b5d6:	mov    %eax,%r13d
   1b5d9:	add    0x10(%r15),%r13
   1b5dd:	mov    %r13,%rax
   1b5e0:	sub    0x18(%r15),%rax
   1b5e4:	add    0x14f00(%rdi),%rax
   1b5eb:	mov    0x3808(%rdi),%rcx
   1b5f2:	cmp    %rcx,%rax
   1b5f5:	jb     1b619 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x289>
   1b5f7:	mov    %rcx,%rdi
   1b5fa:	mov    %rax,%rsi
   1b5fd:	call   2ff60 <*Gcry::Heap#debt_at_threshold?<UInt64>:Bool>
   1b602:	mov    0x10(%rsp),%rdi
   1b607:	mov    0x18(%rsp),%rsi
   1b60c:	mov    $0x298,%ecx
   1b611:	test   $0x1,%al
   1b613:	jne    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b619:	movq   $0x8,0x20(%rbx)
   1b621:	mov    0x10(%rbx),%r8
   1b625:	test   %r8,%r8
   1b628:	je     1b647 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2b7>
   1b62a:	mov    0x18(%rbx),%rax
   1b62e:	test   %ebp,%ebp
   1b630:	js     1b9ee <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x65e>
   1b636:	cmp    $0x27,%ebp
   1b639:	mov    %ebp,%r12d
   1b63c:	jbe    1b9f7 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x667>
   1b642:	jmp    1bbf9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x869>
   1b647:	mov    (%rbx),%r10
   1b64a:	test   %r10,%r10
   1b64d:	je     1b8ca <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x53a>
   1b653:	movslq 0x10(%r10),%rax
   1b657:	test   %rax,%rax
   1b65a:	js     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b660:	cmp    $0x27,%eax
   1b663:	jbe    1b673 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2e3>
   1b665:	xor    %eax,%eax
   1b667:	jmp    1b697 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x307>
   1b669:	mov    $0x290,%ecx
   1b66e:	jmp    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b673:	mov    0x2118(%rdi,%rax,8),%r8
   1b67b:	xor    %eax,%eax
   1b67d:	test   %r8,%r8
   1b680:	je     1b697 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x307>
   1b682:	mov    0x8(%r10),%rcx
   1b686:	mov    0x18(%r10),%edx
   1b68a:	sub    %rdx,%rcx
   1b68d:	jbe    1b697 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x307>
   1b68f:	mov    %rcx,%rax
   1b692:	xor    %edx,%edx
   1b694:	div    %r8
   1b697:	movabs $0x8000000000000000,%rdx
   1b6a1:	mov    %rax,%rcx
   1b6a4:	xor    %rdx,%rcx
   1b6a7:	mov    %rcx,%rdx
   1b6aa:	add    $0x3f,%rdx
   1b6ae:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b6b4:	movabs $0x200000000000000,%r8
   1b6be:	shr    $0x6,%rdx
   1b6c2:	mov    %rdx,%r9
   1b6c5:	xor    %r8,%r9
   1b6c8:	and    $0xffffffff80000000,%r9
   1b6cf:	jne    1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b6d5:	movslq 0x8(%rbx),%r14
   1b6d9:	cmp    %edx,%r14d
   1b6dc:	jge    1b8ca <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x53a>
   1b6e2:	dec    %rcx
   1b6e5:	seto   %r9b
   1b6e9:	cmpl   $0x0,0x1c(%r10)
   1b6ee:	je     1b8ca <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x53a>
   1b6f4:	mov    %r10,0x30(%rsp)
   1b6f9:	mov    %r13,0x58(%rsp)
   1b6fe:	mov    %r12d,0x3c(%rsp)
   1b703:	mov    %ebp,0x24(%rsp)
   1b707:	mov    %r15,0x60(%rsp)
   1b70c:	mov    %rbx,0x40(%rsp)
   1b711:	and    $0x3f,%eax
   1b714:	movabs $0x8000000000000000,%rdi
   1b71e:	btc    %rax,%rdi
   1b722:	dec    %rdi
   1b725:	seto   %sil
   1b729:	test   %rax,%rax
   1b72c:	setne  0xf(%rsp)
   1b731:	xor    %r10d,%r10d
   1b734:	cmp    $0x1,%rax
   1b738:	sbb    %r10,%r10
   1b73b:	mov    %r10,0x48(%rsp)
   1b740:	test   %r9b,%r9b
   1b743:	jne    1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b749:	shr    $0x6,%rcx
   1b74d:	xor    %rcx,%r8
   1b750:	cmp    $0x7fffffff,%r8
   1b757:	ja     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b75d:	mov    0x30(%rsp),%r8
   1b762:	lea    0x20(%r8),%rax
   1b766:	movabs $0x8000000000000000,%r9
   1b770:	xor    %r9,%rdi
   1b773:	or     %rdi,0x48(%rsp)
   1b778:	movslq %ecx,%r9
   1b77b:	movslq %edx,%rdx
   1b77e:	and    %sil,0xf(%rsp)
   1b783:	mov    0x18(%rsp),%rsi
   1b788:	mov    0x10(%rsp),%rdi
   1b78d:	mov    0x40(%rsp),%rbx
   1b792:	mov    %rax,0x28(%rsp)
   1b797:	mov    %r9,0x70(%rsp)
   1b79c:	mov    %rdx,0x68(%rsp)
   1b7a1:	jmp    1b7de <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x44e>
   1b7a3:	mov    0x50(%rsp),%rcx
   1b7a8:	and    %r13,%rcx
   1b7ab:	mov    0x40(%rsp),%rbx
   1b7b0:	mov    0x30(%rsp),%r8
   1b7b5:	mov    0x28(%rsp),%rax
   1b7ba:	mov    0x78(%rsp),%r14
   1b7bf:	mov    0x70(%rsp),%r9
   1b7c4:	mov    0x68(%rsp),%rdx
   1b7c9:	test   %rcx,%rcx
   1b7cc:	jne    1b8dc <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x54c>
   1b7d2:	inc    %r14
   1b7d5:	cmp    %rdx,%r14
   1b7d8:	je     1b8ca <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x53a>
   1b7de:	cmpl   $0x0,0x1c(%r8)
   1b7e3:	je     1b7d2 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x442>
   1b7e5:	mov    (%rax,%r14,8),%rcx
   1b7e9:	not    %rcx
   1b7ec:	cmp    %r9,%r14
   1b7ef:	jne    1b801 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x471>
   1b7f1:	cmpb   $0x0,0xf(%rsp)
   1b7f6:	jne    1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b7fc:	and    0x48(%rsp),%rcx
   1b801:	cmpb   $0x1,0x42a0(%rdi)
   1b808:	jne    1b7c9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x439>
   1b80a:	test   %rcx,%rcx
   1b80d:	je     1b7c9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x439>
   1b80f:	movslq 0x10(%r8),%rax
   1b813:	test   %rax,%rax
   1b816:	js     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b81c:	cmp    $0x28,%eax
   1b81f:	jae    1bbf9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x869>
   1b825:	mov    %rcx,0x50(%rsp)
   1b82a:	test   %r14,%r14
   1b82d:	js     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b833:	mov    0x18(%r8),%ebp
   1b837:	add    %r8,%rbp
   1b83a:	mov    0x2118(%rdi,%rax,8),%r12
   1b842:	mov    %r14,0x78(%rsp)
   1b847:	shl    $0x6,%r14
   1b84b:	mov    0x50(%rsp),%r15
   1b850:	mov    %r15,%r13
   1b853:	jmp    1b86c <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x4dc>
   1b855:	mov    0x18(%rsp),%rsi
   1b85a:	mov    0x10(%rsp),%rdi
   1b85f:	lea    -0x1(%r15),%rax
   1b863:	and    %rax,%r15
   1b866:	je     1b7a3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x413>
   1b86c:	tzcnt  %r15,%rbx
   1b871:	mov    %rbx,%rsi
   1b874:	or     %r14,%rsi
   1b877:	imul   %r12,%rsi
   1b87b:	add    %rbp,%rsi
   1b87e:	call   2ff70 <*Gcry::Heap#blacklisted_page?<UInt64>:Bool>
   1b883:	test   $0x1,%al
   1b885:	je     1b855 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x4c5>
   1b887:	mov    0x10(%rsp),%rdi
   1b88c:	mov    0x42b0(%rdi),%rax
   1b893:	movabs $0x8000000000000000,%rcx
   1b89d:	xor    %rcx,%rax
   1b8a0:	inc    %rax
   1b8a3:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b8a9:	btr    %rbx,%r13
   1b8ad:	xor    %rcx,%rax
   1b8b0:	mov    %rax,0x42b0(%rdi)
   1b8b7:	mov    0x18(%rsp),%rsi
   1b8bc:	lea    -0x1(%r15),%rax
   1b8c0:	and    %rax,%r15
   1b8c3:	jne    1b86c <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x4dc>
   1b8c5:	jmp    1b7a3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x413>
   1b8ca:	movq   $0x0,0x20(%rbx)
   1b8d2:	mov    $0x290,%ecx
   1b8d7:	jmp    1b4e3 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x153>
   1b8dc:	mov    %r14d,0x8(%rbx)
   1b8e0:	test   %r14,%r14
   1b8e3:	js     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1b8e9:	mov    %rcx,%r8
   1b8ec:	mov    %r14,%rsi
   1b8ef:	mov    0x30(%rsp),%rax
   1b8f4:	mov    0x18(%rax),%ecx
   1b8f7:	cmpl   $0x0,0x24(%rsp)
   1b8fc:	js     1b90c <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x57c>
   1b8fe:	mov    0x24(%rsp),%edx
   1b902:	cmp    $0x27,%edx
   1b905:	jbe    1b91b <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x58b>
   1b907:	jmp    1bbf9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x869>
   1b90c:	cmpl   $0xffffffd7,0x24(%rsp)
   1b911:	mov    0x3c(%rsp),%edx
   1b915:	jbe    1bbf9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x869>
   1b91b:	add    0x30(%rsp),%rcx
   1b920:	mov    %esi,%eax
   1b922:	mov    %rax,%rsi
   1b925:	shl    $0x6,%rsi
   1b929:	mov    %edx,%edx
   1b92b:	mov    0x10(%rsp),%rdi
   1b930:	imul   0x2118(%rdi,%rdx,8),%rsi
   1b939:	add    %rcx,%rsi
   1b93c:	mov    0x40(%rsp),%rcx
   1b941:	mov    %rsi,0x18(%rcx)
   1b945:	mov    %r8,0x10(%rcx)
   1b949:	cmpb   $0x1,0x15190(%rdi)
   1b950:	je     1b96e <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5de>
   1b952:	mov    0x10(%rsp),%rcx
   1b957:	cmpb   $0x0,0x151a0(%rcx)
   1b95e:	jne    1b96e <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5de>
   1b960:	mov    0x10(%rsp),%rcx
   1b965:	cmpb   $0x0,0x15253(%rcx)
   1b96c:	je     1b996 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x606>
   1b96e:	mov    0x30(%rsp),%rcx
   1b973:	mov    0x1c(%rcx),%ecx
   1b976:	test   %rcx,%rcx
   1b979:	je     1b98b <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x5fb>
   1b97b:	mov    0x28(%rsp),%rdx
   1b980:	lea    (%rdx,%rcx,8),%rcx
   1b984:	lock or %r8,(%rcx,%rax,8)
   1b989:	jmp    1b9af <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x61f>
   1b98b:	movq   $0x0,0x28(%rsp)
   1b994:	jmp    1b9af <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x61f>
   1b996:	xor    %ecx,%ecx
   1b998:	mov    0x30(%rsp),%rdx
   1b99d:	cmpl   $0x0,0x1c(%rdx)
   1b9a1:	mov    0x28(%rsp),%rdx
   1b9a6:	cmove  %rcx,%rdx
   1b9aa:	mov    %rdx,0x28(%rsp)
   1b9af:	mov    0x28(%rsp),%rcx
   1b9b4:	lock or %r8,(%rcx,%rax,8)
   1b9b9:	mov    0x10(%rsp),%rdi
   1b9be:	incq   0x270(%rdi)
   1b9c5:	mov    0x18(%rsp),%rsi
   1b9ca:	mov    0x40(%rsp),%rbx
   1b9cf:	mov    0x60(%rsp),%r15
   1b9d4:	mov    0x24(%rsp),%ebp
   1b9d8:	mov    0x3c(%rsp),%r12d
   1b9dd:	mov    0x58(%rsp),%r13
   1b9e2:	mov    0x18(%rbx),%rax
   1b9e6:	test   %ebp,%ebp
   1b9e8:	jns    1b636 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x2a6>
   1b9ee:	cmp    $0xffffffd7,%ebp
   1b9f1:	jbe    1bbf9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x869>
   1b9f7:	tzcnt  %r8,%r14
   1b9fc:	mov    %r12d,%ecx
   1b9ff:	imul   0x2118(%rdi,%rcx,8),%r14
   1ba08:	add    %rax,%r14
   1ba0b:	mov    %r14,0x20(%rbx)
   1ba0f:	lea    -0x1(%r8),%rax
   1ba13:	and    %r8,%rax
   1ba16:	mov    %rax,0x10(%rbx)
   1ba1a:	mov    %r13,0x10(%r15)
   1ba1e:	incq   0x20(%r15)
   1ba22:	mov    0x19d8(%rdi),%rax
   1ba29:	test   %rax,%rax
   1ba2c:	je     1ba33 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x6a3>
   1ba2e:	prefetcht0 (%rax,%r14,1)
   1ba33:	cmpb   $0x1,0x151a0(%rdi)
   1ba3a:	je     1ba49 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x6b9>
   1ba3c:	cmpb   $0x0,0x15190(%rdi)
   1ba43:	je     1bb12 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x782>
   1ba49:	cmpb   $0x0,0x30d0(%rdi)
   1ba50:	je     1bb28 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x798>
   1ba56:	mov    0x10(%rsp),%rdi
   1ba5b:	mov    %r14,%rsi
   1ba5e:	call   27110 <*Gcry::Heap#chunk_containing<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)>
   1ba63:	mov    0x10(%rsp),%rdi
   1ba68:	test   %eax,%eax
   1ba6a:	je     1bb63 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7d3>
   1ba70:	cmpb   $0x1,0x19b8(%rdi)
   1ba77:	jne    1bb63 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7d3>
   1ba7d:	mov    0x10(%rdx),%ecx
   1ba80:	mov    $0xffffffff,%eax
   1ba85:	cmp    %rax,%rcx
   1ba88:	je     1bb63 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7d3>
   1ba8e:	testb  $0x1,0x14(%rdx)
   1ba92:	jne    1bb63 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7d3>
   1ba98:	test   %ecx,%ecx
   1ba9a:	js     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1baa0:	mov    %rdx,%r8
   1baa3:	mov    0x18(%r8),%edx
   1baa7:	add    %r8,%rdx
   1baaa:	mov    %r14,%rax
   1baad:	sub    %rdx,%rax
   1bab0:	jb     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1bab6:	cmp    $0x27,%ecx
   1bab9:	ja     1bbf9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x869>
   1babf:	mov    0x10(%rsp),%rdx
   1bac4:	mulq   0x2258(%rdx,%rcx,8)
   1bacc:	jo     1bbdb <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x84b>
   1bad2:	mov    0x1c(%r8),%edx
   1bad6:	test   %rdx,%rdx
   1bad9:	mov    0x18(%rsp),%rsi
   1bade:	mov    0x10(%rsp),%rdi
   1bae3:	je     1bb12 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x782>
   1bae5:	lea    (%r8,%rdx,8),%r10
   1bae9:	mov    %rax,%rcx
   1baec:	shr    $0x28,%rcx
   1baf0:	shr    $0x2e,%rax
   1baf4:	mov    $0x1,%r9d
   1bafa:	shl    %cl,%r9
   1bafd:	mov    0x20(%r10,%rax,8),%r10
   1bb02:	bt     %rcx,%r10
   1bb06:	jb     1bb12 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x782>
   1bb08:	lea    0x20(%r8,%rdx,8),%rcx
   1bb0d:	lock or %r9,(%rcx,%rax,8)
   1bb12:	movq   $0x0,0x20(%rbx)
   1bb1a:	test   %r14,%r14
   1bb1d:	jne    1bba9 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x819>
   1bb23:	jmp    1b4e7 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x157>
   1bb28:	movzbl 0x1a04ed(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb2f:	mov    0x4(%r14),%eax
   1bb33:	mov    %eax,%edx
   1bb35:	and    $0xffff00fb,%edx
   1bb3b:	movzbl %cl,%r8d
   1bb3f:	mov    %r8d,%ecx
   1bb42:	shl    $0x8,%ecx
   1bb45:	or     %edx,%ecx
   1bb47:	lock cmpxchg %ecx,0x4(%r14)
   1bb4d:	sete   %al
   1bb50:	movzbl 0x1a04c5(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb57:	cmp    %cl,%r8b
   1bb5a:	sete   %dl
   1bb5d:	test   %dl,%al
   1bb5f:	je     1bb2f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x79f>
   1bb61:	jmp    1bba1 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x811>
   1bb63:	movzbl 0x1a04b2(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb6a:	mov    0x18(%rsp),%rsi
   1bb6f:	mov    0x4(%r14),%eax
   1bb73:	mov    %eax,%edx
   1bb75:	and    $0xffff00fb,%edx
   1bb7b:	movzbl %cl,%r8d
   1bb7f:	mov    %r8d,%ecx
   1bb82:	shl    $0x8,%ecx
   1bb85:	or     %edx,%ecx
   1bb87:	lock cmpxchg %ecx,0x4(%r14)
   1bb8d:	sete   %al
   1bb90:	movzbl 0x1a0485(%rip),%ecx        # 1bc01c <Gcry::BlockHeader::mark_gen>
   1bb97:	cmp    %cl,%r8b
   1bb9a:	sete   %dl
   1bb9d:	test   %dl,%al
   1bb9f:	je     1bb6f <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x7df>
   1bba1:	movq   $0x0,0x20(%rbx)
   1bba9:	cmpb   $0x1,0x1a0540(%rip)        # 1bc0f0 <Gcry::Invariant::enabled>
   1bbb0:	jne    1bbbc <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x82c>
   1bbb2:	call   2ccc0 <*Gcry::Invariant::check_live_objects<Gcry::Heap>:Nil>
   1bbb7:	mov    0x18(%rsp),%rsi
   1bbbc:	cmpb   $0x1,0x1a04ee(%rip)        # 1bc0b1 <Gcry::Trace::enabled>
   1bbc3:	jne    1b4c4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x134>
   1bbc9:	mov    %r14,%rdi
   1bbcc:	mov    $0x1,%edx
   1bbd1:	call   30050 <*Gcry::Trace::after_malloc_enabled<Pointer(Void), UInt64, Bool>:Nil>
   1bbd6:	jmp    1b4c4 <*GC::malloc_atomic<UInt64>:Pointer(Void)+0x134>
   1bbdb:	call   1a950 <__crystal_raise_overflow>
   1bbe0:	call   1bc10 <*GC::fork_poison_exit:NoReturn>
   1bbe5:	lea    0x14fc44(%rip),%rdi        # 16b830 <$Slice:7+0x1ab0>
   1bbec:	call   1dea0 <*Gcry::OutOfMemoryError@Exception::new<String>:Gcry::OutOfMemoryError>
   1bbf1:	mov    %rax,%rdi
   1bbf4:	call   1eb80 <*raise<Gcry::OutOfMemoryError>:NoReturn>
   1bbf9:	call   1f220 <*IndexError::new:IndexError>
   1bbfe:	mov    %rax,%rdi
   1bc01:	call   1f270 <*raise<IndexError>:NoReturn>
   1bc06:	cs nopw 0x0(%rax,%rax,1)
