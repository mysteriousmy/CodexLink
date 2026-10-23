/* AotAnywhere 1.1.0's C cookie helper clobbers RAX. MSVC-generated /GS
 * epilogues expect it to preserve the return value and argument registers.
 * Keep the upstream glue and replace only that helper for x64 cross-links.
 * https://learn.microsoft.com/windows/arm/arm64ec-abi#security-check-cookie
 */
#define __security_check_cookie aotanywhere_c_security_check_cookie
#include "aotanywhere-upstream-glue.c"
#undef __security_check_cookie

__attribute__((naked)) void __security_check_cookie(uintptr_t cookie)
{
    __asm__(
        "cmpq __security_cookie(%rip), %rcx\n"
        "jne 1f\n"
        "retq\n"
        "1:\n"
        "movl $2, %ecx\n" /* FAST_FAIL_STACK_COOKIE_CHECK_FAILURE */
        "int $0x29\n");
}
