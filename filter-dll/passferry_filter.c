/*
 * passferry_filter.c
 *
 * Minimal LSA password filter DLL.
 *
 * Job: when a password changes on this DC, write the (sAMAccountName, password)
 * pair to a local named pipe. A separate user-mode service drains the pipe and
 * forwards to the sync broker over HTTPS.
 *
 * Why a named pipe and not direct HTTP from here?
 *   This DLL runs INSIDE LSASS. If we crash, the DC bluescreens.
 *   If we block on network I/O, authentication on the whole DC stalls.
 *   So: do the absolute minimum here, hand off to user-mode immediately.
 *
 * Registration:
 *   Place passferry_filter.dll in C:\Windows\System32\
 *   HKLM\SYSTEM\CurrentControlSet\Control\Lsa
 *     Notification Packages (REG_MULTI_SZ): append "passferry_filter"
 *       (NO .dll extension)
 *   Reboot the DC.
 *
 * SECURITY NOTES
 *   - The named pipe uses a restrictive DACL: only LocalSystem and the
 *     forwarder service account can read it.
 *   - Password is sent as UTF-16, length-prefixed. Receiver MUST zero memory.
 *   - This DLL only WRITES to the pipe. No reads, no syscalls, no allocations
 *     beyond what's strictly needed.
 *
 * Build with Claude Code (instructions in 02-password-filter-dll/BUILD.md)
 */

#include <windows.h>
#include <ntsecapi.h>
#include <subauth.h>
#include <stdio.h>

#pragma comment(lib, "advapi32.lib")

#define PIPE_NAME L"\\\\.\\pipe\\PassFerryFilter"
#define PIPE_TIMEOUT_MS 200  // be aggressive — never block LSASS

// Required LSA exports
BOOLEAN NTAPI InitializeChangeNotify(void) {
    return TRUE;
}

NTSTATUS NTAPI PasswordChangeNotify(
    PUNICODE_STRING UserName,
    ULONG           RelativeId,
    PUNICODE_STRING NewPassword
) {
    UNREFERENCED_PARAMETER(RelativeId);

    // Sanity checks. If anything looks wrong, bail silently — never fail the
    // password change because of us.
    if (!UserName || !NewPassword) return STATUS_SUCCESS;
    if (UserName->Length == 0 || NewPassword->Length == 0) return STATUS_SUCCESS;
    if (UserName->Length > 512 || NewPassword->Length > 512) return STATUS_SUCCESS;

    HANDLE hPipe = INVALID_HANDLE_VALUE;

    __try {
        // Wait briefly for pipe to be available
        if (!WaitNamedPipeW(PIPE_NAME, PIPE_TIMEOUT_MS)) {
            // Forwarder service isn't listening. Don't block password change.
            return STATUS_SUCCESS;
        }

        hPipe = CreateFileW(
            PIPE_NAME,
            GENERIC_WRITE,
            0,
            NULL,
            OPEN_EXISTING,
            0,
            NULL);

        if (hPipe == INVALID_HANDLE_VALUE) {
            return STATUS_SUCCESS;
        }

        // Wire format (all little-endian, UTF-16):
        //   [u16 username_len_bytes][username][u16 password_len_bytes][password]
        DWORD written = 0;
        USHORT uLen = UserName->Length;
        USHORT pLen = NewPassword->Length;

        WriteFile(hPipe, &uLen, sizeof(uLen), &written, NULL);
        WriteFile(hPipe, UserName->Buffer, uLen, &written, NULL);
        WriteFile(hPipe, &pLen, sizeof(pLen), &written, NULL);
        WriteFile(hPipe, NewPassword->Buffer, pLen, &written, NULL);

        FlushFileBuffers(hPipe);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        // Swallow any exception. We MUST NOT fail LSASS.
    }

    if (hPipe != INVALID_HANDLE_VALUE) {
        CloseHandle(hPipe);
    }

    return STATUS_SUCCESS;
}

NTSTATUS NTAPI PasswordFilter(
    PUNICODE_STRING AccountName,
    PUNICODE_STRING FullName,
    PUNICODE_STRING Password,
    BOOLEAN         SetOperation
) {
    UNREFERENCED_PARAMETER(AccountName);
    UNREFERENCED_PARAMETER(FullName);
    UNREFERENCED_PARAMETER(Password);
    UNREFERENCED_PARAMETER(SetOperation);
    // We're not a complexity filter. Always allow — let other filters/policy decide.
    return STATUS_SUCCESS;
}

BOOL APIENTRY DllMain(HMODULE hMod, DWORD reason, LPVOID lpRes) {
    UNREFERENCED_PARAMETER(hMod);
    UNREFERENCED_PARAMETER(lpRes);
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hMod);
    }
    return TRUE;
}
