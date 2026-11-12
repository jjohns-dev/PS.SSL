@{
    # Pester tags to exclude from the gating build. String array; default none.
    # Tests tagged Network call a live third-party endpoint (badssl.com) and flaked CI (#50).
    PesterExcludeTag = 'Network'
}
