// How BC proves itself to the Azure Function. Switchable at runtime from the
// setup page so moving from a function key to Entra ID needs no code change
// and no redeploy - which is the whole point of keeping this configurable.
enum 50123 "PN Dispatch Auth Mode"
{
    Extensible = true;
    Caption = 'PN Dispatch Auth Mode';

    // x-functions-key header only. Fine for a sandbox, weak for production:
    // the key is a bearer secret with no expiry and no audience binding.
    value(0; "Function Key") { Caption = 'Function Key'; }

    // OAuth 2.0 client credentials against Entra ID. Token is cached and
    // refreshed ahead of expiry. This is the production recommendation.
    value(1; "OAuth2 Client Credentials") { Caption = 'OAuth 2.0 (Entra ID)'; }

    // Both headers sent. Useful during migration from one to the other.
    value(2; Both) { Caption = 'Function Key + OAuth 2.0'; }
}
