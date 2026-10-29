function Get-CSRTemplate {
    <#
    .SYNOPSIS
        Return the canonical openssl req configuration template used by the module.
    .DESCRIPTION
        Emits the openssl `req` config template that the module's New-CertificateSigningRequest
        and New-SelfSignedCertificate functions render internally when generating a CSR or
        self-signed certificate from scratch (i.e. when the caller does not supply their own
        -ConfigFile).

        Use this when you want to seed a custom .conf file - write the template to disk, edit
        the placeholders by hand, then feed the resulting file back into New-CertificateSigningRequest
        or New-SelfSignedCertificate via -ConfigFile.

        The template uses `#TOKEN#` placeholders (e.g. `#CN#`, `#C#`) that the internal
        Build-CsrConfig helper substitutes from parameter values. When editing by hand,
        replace the placeholders with literal values.
    .INPUTS
        None.
    .OUTPUTS
        System.String[]. One element per line of the template, suitable for piping to Set-Content.
    .EXAMPLE
        PS C:\> Get-CSRTemplate | Set-Content -Path .\template.conf
        Write the canonical template to disk for hand-editing.
    .EXAMPLE
        PS C:\> Get-CSRTemplate | Set-Content -Path .\template.conf
        PS C:\> New-CertificateSigningRequest -OutputDirectory . -ConfigFile .\template.conf
        Seed, edit, and use a custom config file.
    .NOTES
        Status: Stable
        - Replaces the previously exported read-only `$CSR_Template` module variable.
          The variable form caused a benign but noisy `Remove-Module` warning because
          read-only variables cannot be torn down on module unload without -Force.
    #>
    [CmdletBinding()]
    [OutputType([System.String[]])]
    Param()
    Begin {
        Write-Verbose -Message "Starting $($MyInvocation.Mycommand)"
    }
    Process {
        @(
            '[req]'
            'distinguished_name = req_distinguished_name'
            'req_extensions = v3_req'
            'default_bits = 4096'
            'default_md = sha256'
            'encrypt_key = no'
            'prompt = no'
            '[req_distinguished_name]'
            'C = #C#'
            'ST = #ST#'
            'L = #L#'
            'O = #O#'
            'OU = #OU#'
            'emailAddress = "#E#"'
            'CN = #CN#'
            '[v3_req]'
            'keyUsage = keyEncipherment, dataEncipherment'
            'extendedKeyUsage = serverAuth'
            'subjectAltName = @alt_names'
            '[alt_names]'
        )
    }
}
