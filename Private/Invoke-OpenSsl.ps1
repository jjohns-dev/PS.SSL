function Invoke-OpenSsl {
    <#
    .SYNOPSIS
        Invoke the openssl command-line tool and capture its output.
    .DESCRIPTION
        Centralized wrapper for openssl. Builds a System.Diagnostics.Process with
        stdout/stderr redirected so callers receive the result in any PowerShell
        host (including ISE, VSCode terminal, remoting sessions, and CI). On a
        non-zero exit code the function emits a terminating error unless
        -IgnoreExitCode is supplied (used by probing callers such as Test-Cipher
        and Test-Protocol where a non-zero exit is an expected outcome).
    .PARAMETER ArgumentList
        Arguments to pass to openssl. Each element is a discrete argv entry; do
        not pre-join into a single string and do not wrap values containing
        spaces in quotes. Quoting is handled by ProcessStartInfo.ArgumentList.
    .PARAMETER IgnoreExitCode
        Return the result object even when openssl exits non-zero. Callers must
        inspect the ExitCode property themselves.
    .PARAMETER EnvironmentVariable
        Dictionary of environment variables to set on the openssl child process
        only. Use this to hand sensitive values (e.g. PFX passwords) to openssl
        via -passin env:VAR / -passout env:VAR instead of pass:..., which would
        place the secret on the command line where it is visible to process
        listings, EDR telemetry, and audit logs. SecureString values are
        unwrapped just-in-time inside the helper. The variables are NOT
        propagated to the parent PowerShell session.
    .INPUTS
        None.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with ExitCode, StdOut, StdErr.
    .EXAMPLE
        PS C:\> Invoke-OpenSsl -ArgumentList 'version'
        Runs 'openssl version' and returns a result object.
    .EXAMPLE
        PS C:\> $r = Invoke-OpenSsl -ArgumentList @('s_client', '-cipher', $c, '-connect', "$h`:443") -IgnoreExitCode
        PS C:\> if ($r.ExitCode -eq 0) { 'supported' } else { 'not supported' }
        Use -IgnoreExitCode for probing scenarios where a non-zero exit is meaningful, not fatal.
    .NOTES
        Status: Stable
        - Internal helper. Not exported from the module.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    Param(
        [Parameter(Mandatory, Position = 0, HelpMessage = 'Arguments to pass to openssl (argv-style array)')]
        [ValidateNotNullOrEmpty()]
        [System.String[]] $ArgumentList,

        [Parameter(HelpMessage = 'Return non-zero exits as data instead of a terminating error')]
        [System.Management.Automation.SwitchParameter] $IgnoreExitCode,

        [Parameter(HelpMessage = 'Environment variables to set on the openssl child process only')]
        [System.Collections.IDictionary] $EnvironmentVariable
    )
    Begin {
        Write-Verbose -Message "Starting $($MyInvocation.MyCommand)"

        # FAIL FAST IF OPENSSL IS NOT ON PATH. THIS IS A TERMINATING ERROR
        # SO CALLERS DON'T NEED TO RE-CHECK; SURFACES A CLEAR DIAGNOSTIC
        # INSTEAD OF A CRYPTIC "FILE NOT FOUND" FROM Process.Start().
        if (-not (Get-Command -Name 'openssl' -CommandType Application -ErrorAction SilentlyContinue)) {
            Write-Error -Message "'openssl' was not found on PATH." -Category ObjectNotFound -ErrorAction Stop
        }
    }
    Process {
        # BUILD THE PROCESS START INFO. UseShellExecute=$false IS REQUIRED
        # IN ORDER TO REDIRECT STDOUT/STDERR; CreateNoWindow=$true SUPPRESSES
        # THE TRANSIENT CONSOLE WINDOW THAT OTHERWISE FLASHES ON WINDOWS.
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName               = 'openssl'
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError  = $true
        $startInfo.RedirectStandardInput  = $true
        $startInfo.UseShellExecute        = $false
        $startInfo.CreateNoWindow         = $true

        # POPULATE ArgumentList ONE ENTRY AT A TIME. PowerShell 7+ uses the
        # collection form (not the legacy Arguments string), which lets the
        # runtime handle argv quoting per-OS. Pre-joining or quoting the
        # caller-supplied values would re-introduce the very injection and
        # space-fragmentation bugs this helper exists to eliminate.
        foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }

        # APPLY PER-INVOCATION ENVIRONMENT VARIABLES. ProcessStartInfo.Environment
        # is seeded from the parent's environment when first accessed; mutating
        # it here affects ONLY the child openssl process and never the
        # PowerShell session. This is how -passin env:VAR / -passout env:VAR
        # receive secrets without exposing them on argv (which is readable by
        # peer processes via Get-Process / ETW / EDR telemetry). On modern
        # Windows a process environment is not readable by non-admin peer
        # users, so env: is strictly better than pass: for credential handoff.
        #
        # SecureString values are unwrapped via SecureStringToBSTR. The BSTR
        # is tracked in $unwrappedSecureStrings and zeroed+freed in the outer
        # finally{} so the plaintext is wiped from unmanaged memory as soon
        # as openssl has consumed it. The managed string stored on the
        # ProcessStartInfo.Environment dictionary is the only remaining copy
        # at that point; it lives until the next GC cycle.
        $unwrappedSecureStrings = [System.Collections.Generic.List[System.IntPtr]]::new()
        $process = $null
        try {
            if ($PSBoundParameters.ContainsKey('EnvironmentVariable')) {
                foreach ($entry in $EnvironmentVariable.GetEnumerator()) {
                    $name  = [System.String] $entry.Key
                    $value = $entry.Value
                    if ($value -is [System.Security.SecureString]) {
                        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
                        $unwrappedSecureStrings.Add($bstr)
                        $startInfo.Environment[$name] = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    }
                    else {
                        $startInfo.Environment[$name] = [System.String] $value
                    }
                }
            }

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo

            [System.Void] $process.Start()

            # CLOSE STDIN IMMEDIATELY SO COMMANDS THAT WOULD OTHERWISE BLOCK
            # WAITING FOR INPUT EXIT CLEANLY. Two cases this addresses:
            #   1. `openssl s_client` after a successful handshake reads from
            #      stdin and stays open until EOF; without this close the
            #      Test-Protocol / Test-Cipher Supported=true path would hang.
            #   2. `openssl req -new` with a -config file that omits
            #      `prompt = no` would otherwise prompt for DN fields on the
            #      console - turning an unattended call into an interactive
            #      hang. With stdin closed it fails fast with a clear stderr
            #      ("No value provided for Subject Attribute CN") which the
            #      helper surfaces in the terminating error message.
            # No current module call site feeds stdin, so unconditional close
            # is safe. If a future caller needs to pipe data in, add an opt-out
            # switch rather than removing this line.
            $process.StandardInput.Close()

            # READ STDERR ASYNCHRONOUSLY WHILE READING STDOUT. A sequential
            # ReadToEnd() of one stream then the other deadlocks when openssl
            # fills the unread pipe first: openssl blocks on that write while
            # we block on the other stream. The Windows pipe buffer is about
            # 4KB, and RSA-4096 key generation can exceed it on stderr (#82).
            # Both pipes are drained before WaitForExit() for the same reason.
            $stdErrTask     = $process.StandardError.ReadToEndAsync()
            $standardOutput = $process.StandardOutput.ReadToEnd()
            $standardError  = $stdErrTask.GetAwaiter().GetResult()
            $process.WaitForExit()

            # ALWAYS BUILD THE RESULT OBJECT - EVEN ON FAILURE - SO THE
            # -IgnoreExitCode PATH HAS SOMETHING TO RETURN AND THE ERROR
            # MESSAGE BELOW CAN INCLUDE THE STDERR TEXT.
            $result = [PSCustomObject] @{
                ExitCode = $process.ExitCode
                StdOut   = $standardOutput
                StdErr   = $standardError
            }

            # DEFAULT BEHAVIOR: NON-ZERO EXIT IS TERMINATING. Including the
            # trimmed stderr in the message preserves diagnostics that were
            # previously lost by Start-Process -NoNewWindow (which silently
            # dropped the openssl error text).
            if ($process.ExitCode -ne 0 -and -not $IgnoreExitCode) {
                Write-Error -Message ("openssl exited with code {0}: {1}" -f $process.ExitCode, $standardError.Trim()) -Category InvalidResult -ErrorAction Stop
            }

            $result
        }
        finally {
            # ZERO AND FREE EVERY UNWRAPPED BSTR. ZeroFreeBSTR overwrites the
            # unmanaged buffer with zeros before releasing it so the plaintext
            # password cannot be recovered from a process dump after this
            # invocation returns. Done unconditionally - including on error
            # paths - to guarantee no leak across exception boundaries.
            foreach ($bstr in $unwrappedSecureStrings) {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }

            # ALWAYS DISPOSE - Process HOLDS UNMANAGED HANDLES (pipes, the
            # win32 process handle) THAT WILL LEAK UNTIL THE GC FINALIZER
            # RUNS IF NOT EXPLICITLY RELEASED.
            if ($null -ne $process) { $process.Dispose() }
        }
    }
}
